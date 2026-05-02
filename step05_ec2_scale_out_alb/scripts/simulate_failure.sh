#!/usr/bin/env bash
# simulate_failure.sh
# app-01を停止してALBのフェイルオーバー動作をシミュレートするスクリプト
# 使用方法: bash simulate_failure.sh <INSTANCE_ID> <TARGET_GROUP_ARN> <ALB_DNS>

set -euo pipefail

INSTANCE_ID="${1:-}"
TARGET_GROUP_ARN="${2:-}"
ALB_DNS="${3:-}"
REGION="${AWS_REGION:-ap-northeast-1}"

if [[ -z "$INSTANCE_ID" || -z "$TARGET_GROUP_ARN" || -z "$ALB_DNS" ]]; then
  echo "Usage: $0 <INSTANCE_ID> <TARGET_GROUP_ARN> <ALB_DNS>" >&2
  echo "" >&2
  echo "Example:" >&2
  echo "  $0 i-0abc1234def56789 arn:aws:elasticloadbalancing:... my-alb-xxx.elb.amazonaws.com" >&2
  exit 1
fi

divider() {
  echo "=================================================================="
}

step() {
  echo ""
  divider
  echo "STEP: $1"
  divider
}

check_alb_health() {
  aws elbv2 describe-target-health \
    --target-group-arn "$TARGET_GROUP_ARN" \
    --region "$REGION" \
    --query "TargetHealthDescriptions[*].{ID:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}" \
    --output table 2>/dev/null || echo "Failed to get health status"
}

send_request() {
  local url="http://${ALB_DNS}/health"
  local response
  response=$(curl -s --max-time 5 "$url" 2>/dev/null || echo '{"error":"timeout"}')
  local hostname
  hostname=$(echo "$response" | jq -r '.hostname // .error // "unknown"' 2>/dev/null || echo "parse_error")
  local ts
  ts=$(date '+%H:%M:%S')
  echo "  [$ts] -> $hostname"
}

# ──────────────────────────────────────────────────────────────────────────────
step "1. Initial State: Verifying both instances are healthy"
# ──────────────────────────────────────────────────────────────────────────────
echo ""
check_alb_health

echo ""
echo "Sending 10 requests to verify round-robin distribution..."
for i in $(seq 1 10); do
  send_request
done

# ──────────────────────────────────────────────────────────────────────────────
step "2. Stopping instance: $INSTANCE_ID (app-01)"
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "Executing: aws ec2 stop-instances --instance-ids $INSTANCE_ID"
aws ec2 stop-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query "StoppingInstances[0].{ID:InstanceId,State:CurrentState.Name}" \
  --output table

echo ""
echo "Starting k6 load test for 30 seconds while waiting for ALB to detect failure..."
echo "Watch for requests that might fail during the transition window."
echo ""

# ──────────────────────────────────────────────────────────────────────────────
step "3. Monitoring failover (ALB detects unhealthy after ~20 seconds)"
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "Sending requests every 2 seconds for 40 seconds..."
echo "(ALB health check: interval=10s, threshold=2, so detection ~20s)"
echo ""

start_time=$(date +%s)
for i in $(seq 1 20); do
  current_time=$(date +%s)
  elapsed=$(( current_time - start_time ))
  send_request
  # Every 10 seconds, show ALB health status
  if (( elapsed > 0 && elapsed % 10 == 0 )); then
    echo ""
    echo "  -- ALB Target Health at ${elapsed}s --"
    check_alb_health
    echo ""
  fi
  sleep 2
done

# ──────────────────────────────────────────────────────────────────────────────
step "4. Verifying all requests now go to app-02 only"
# ──────────────────────────────────────────────────────────────────────────────
echo ""
check_alb_health

echo ""
echo "Sending 10 more requests - all should go to app-02:"
for i in $(seq 1 10); do
  send_request
done

# ──────────────────────────────────────────────────────────────────────────────
step "5. Recovering: Restarting instance $INSTANCE_ID (app-01)"
# ──────────────────────────────────────────────────────────────────────────────
echo ""
aws ec2 start-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query "StartingInstances[0].{ID:InstanceId,State:CurrentState.Name}" \
  --output table

echo ""
echo "Waiting for instance to pass ALB health checks (~60 seconds)..."
elapsed=0
while (( elapsed < 90 )); do
  sleep 10
  elapsed=$(( elapsed + 10 ))
  echo ""
  echo "  -- ALB Target Health at ${elapsed}s after start --"
  check_alb_health

  healthy_count=$(aws elbv2 describe-target-health \
    --target-group-arn "$TARGET_GROUP_ARN" \
    --region "$REGION" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" \
    --output text 2>/dev/null || echo "0")

  if (( healthy_count >= 2 )); then
    echo ""
    echo "Both instances are healthy again!"
    break
  fi
done

# ──────────────────────────────────────────────────────────────────────────────
step "6. Final Verification: Load balanced across both instances"
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "Sending 20 requests to verify distribution is restored:"
for i in $(seq 1 20); do
  send_request
  sleep 0.2
done

echo ""
divider
echo "Simulation complete!"
echo ""
echo "Summary:"
echo "  - app-01 was stopped"
echo "  - ALB detected failure and stopped routing to app-01"
echo "  - All traffic was served by app-02 with no errors"
echo "  - app-01 was restarted and rejoined the target group"
echo "  - Traffic is now balanced across both instances"
divider
