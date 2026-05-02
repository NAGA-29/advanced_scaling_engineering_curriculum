#!/usr/bin/env bash
# blue_green_switch.sh
# Route53のAliasレコードをBlue ALBからGreen ALB（またはその逆）に切り替えるスクリプト
#
# 使用方法:
#   bash scripts/blue_green_switch.sh \
#     --zone-id Z1234567890ABCDEF \
#     --record-name app.example.com \
#     --target-alb-dns new-alb-xxx.ap-northeast-1.elb.amazonaws.com \
#     --target-alb-zone-id Z14GRHDCWA56QT \
#     --direction blue-to-green
#
# 引数:
#   --zone-id          Route53 Hosted Zone ID
#   --record-name      切り替え対象のDNSレコード名 (例: app.example.com)
#   --target-alb-dns   新しい向き先のALBのDNS名
#   --target-alb-zone-id  ALBのHostedZoneId (東京: Z14GRHDCWA56QT)
#   --direction        blue-to-green または green-to-blue (ログ用)
#   --region           AWSリージョン (デフォルト: ap-northeast-1)

set -euo pipefail

# ─── Default values ───────────────────────────────────────────────────────────
ZONE_ID=""
RECORD_NAME=""
TARGET_ALB_DNS=""
TARGET_ALB_ZONE_ID=""
DIRECTION="blue-to-green"
REGION="${AWS_REGION:-ap-northeast-1}"
WAIT_SECONDS=35

# ─── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --zone-id)           ZONE_ID="$2";           shift 2 ;;
    --record-name)       RECORD_NAME="$2";       shift 2 ;;
    --target-alb-dns)    TARGET_ALB_DNS="$2";    shift 2 ;;
    --target-alb-zone-id) TARGET_ALB_ZONE_ID="$2"; shift 2 ;;
    --direction)         DIRECTION="$2";         shift 2 ;;
    --region)            REGION="$2";            shift 2 ;;
    --wait-seconds)      WAIT_SECONDS="$2";      shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 --zone-id <id> --record-name <name> --target-alb-dns <dns> --target-alb-zone-id <zone> --direction <blue-to-green|green-to-blue>" >&2
      exit 1
      ;;
  esac
done

# ─── Validate required arguments ──────────────────────────────────────────────
missing=()
[[ -z "$ZONE_ID" ]]           && missing+=("--zone-id")
[[ -z "$RECORD_NAME" ]]       && missing+=("--record-name")
[[ -z "$TARGET_ALB_DNS" ]]    && missing+=("--target-alb-dns")
[[ -z "$TARGET_ALB_ZONE_ID" ]] && missing+=("--target-alb-zone-id")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Error: Missing required arguments: ${missing[*]}" >&2
  exit 1
fi

# Ensure record name ends with a dot (Route53 requirement)
if [[ "$RECORD_NAME" != *. ]]; then
  RECORD_NAME="${RECORD_NAME}."
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────
divider() { echo "=============================================================="; }
step()    { echo ""; divider; echo "  $1"; divider; }
ts()      { date '+%Y-%m-%d %H:%M:%S'; }

# ─── Step 1: Show current state ───────────────────────────────────────────────
step "1. Current DNS Record State"
echo ""
echo "Zone ID      : $ZONE_ID"
echo "Record Name  : $RECORD_NAME"
echo "Direction    : $DIRECTION"
echo "New Target   : $TARGET_ALB_DNS"
echo ""

current_record=$(aws route53 list-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}' && Type=='A']" \
  --output json 2>/dev/null || echo "[]")

echo "Current record:"
echo "$current_record" | python3 -c "
import sys, json
records = json.load(sys.stdin)
if not records:
    print('  (no A record found for this name)')
else:
    for r in records:
        alias = r.get('AliasTarget', {})
        print(f\"  Name : {r.get('Name')}\")
        print(f\"  Type : {r.get('Type')}\")
        print(f\"  Alias: {alias.get('DNSName', 'N/A')}\")
" 2>/dev/null || echo "  $current_record"

# ─── Step 2: Build change batch ───────────────────────────────────────────────
step "2. Building Route53 Change Batch"
echo ""

# Normalize ALB DNS for Route53 (must have trailing dot and be lowercase)
NORMALIZED_ALB_DNS="${TARGET_ALB_DNS,,}"
if [[ "$NORMALIZED_ALB_DNS" != *. ]]; then
  NORMALIZED_ALB_DNS="${NORMALIZED_ALB_DNS}."
fi

CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "Blue/Green switch: ${DIRECTION} at $(ts)",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${RECORD_NAME}",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${TARGET_ALB_ZONE_ID}",
          "DNSName": "${NORMALIZED_ALB_DNS}",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
EOF
)

echo "Change batch:"
echo "$CHANGE_BATCH" | python3 -m json.tool 2>/dev/null || echo "$CHANGE_BATCH"

# ─── Step 3: Apply the change ─────────────────────────────────────────────────
step "3. Applying DNS Change"
echo ""
echo "[$(ts)] Submitting change to Route53..."

CHANGE_RESPONSE=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch "$CHANGE_BATCH" \
  --output json)

CHANGE_ID=$(echo "$CHANGE_RESPONSE" | python3 -c "
import sys, json
resp = json.load(sys.stdin)
print(resp['ChangeInfo']['Id'].split('/')[-1])
" 2>/dev/null || echo "")

CHANGE_STATUS=$(echo "$CHANGE_RESPONSE" | python3 -c "
import sys, json
resp = json.load(sys.stdin)
print(resp['ChangeInfo']['Status'])
" 2>/dev/null || echo "UNKNOWN")

echo "Change ID    : $CHANGE_ID"
echo "Status       : $CHANGE_STATUS"

# ─── Step 4: Wait for propagation ────────────────────────────────────────────
step "4. Waiting for DNS Propagation (${WAIT_SECONDS}s)"
echo ""
echo "TTLが30秒に設定されている場合、最大${WAIT_SECONDS}秒で反映される。"
echo "TTLが300秒の場合は lower_ttl.sh で短縮してから実行することを推奨。"
echo ""

# Wait for Route53 change to be INSYNC
if [[ -n "$CHANGE_ID" ]]; then
  echo "[$(ts)] Waiting for Route53 change to reach INSYNC status..."
  max_wait=60
  elapsed=0
  while (( elapsed < max_wait )); do
    status=$(aws route53 get-change \
      --id "$CHANGE_ID" \
      --query "ChangeInfo.Status" \
      --output text 2>/dev/null || echo "UNKNOWN")
    echo "  [$(ts)] Change status: $status (${elapsed}s elapsed)"
    if [[ "$status" == "INSYNC" ]]; then
      echo "  -> Route53 change is INSYNC"
      break
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
  done
fi

echo ""
echo "[$(ts)] Waiting ${WAIT_SECONDS}s for DNS TTL propagation..."
sleep "$WAIT_SECONDS"

# ─── Step 5: Verify new target ────────────────────────────────────────────────
step "5. Verifying New Target via /health"
echo ""

VERIFY_URL="http://${TARGET_ALB_DNS}/health"
echo "Direct ALB health check: $VERIFY_URL"
echo ""

success_count=0
fail_count=0
for i in $(seq 1 5); do
  response=$(curl -s --max-time 10 "$VERIFY_URL" 2>/dev/null || echo "")
  if [[ -z "$response" ]]; then
    echo "  Request $i -> ERROR (no response)"
    (( fail_count++ )) || true
    continue
  fi

  hostname=$(echo "$response" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('hostname', 'unknown'))
except:
    print('parse_error')
" 2>/dev/null || echo "parse_error")

  status_code=$(echo "$response" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('status', 'unknown'))
except:
    print('parse_error')
" 2>/dev/null || echo "parse_error")

  echo "  Request $i -> hostname: $hostname  status: $status_code"
  (( success_count++ )) || true
  sleep 1
done

echo ""
echo "Health check results: $success_count/5 succeeded"

# ─── Step 6: DNS resolution check ────────────────────────────────────────────
step "6. DNS Resolution Check"
echo ""

echo "dig +short ${RECORD_NAME}:"
dig_result=$(dig +short "${RECORD_NAME%%.}" 2>/dev/null || echo "(dig not available or DNS not configured)")
echo "  $dig_result"

echo ""
echo "Current Route53 record after change:"
aws route53 list-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}' && Type=='A']" \
  --output json 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  (could not retrieve record)"

# ─── Summary ──────────────────────────────────────────────────────────────────
divider
echo ""
echo "Blue/Green Switch Complete"
echo ""
echo "  Direction    : $DIRECTION"
echo "  New Target   : $TARGET_ALB_DNS"
echo "  Change ID    : $CHANGE_ID"
echo "  Healthy resp : ${success_count}/5"
echo ""
echo "次のアクション:"
if [[ "$DIRECTION" == "blue-to-green" ]]; then
  echo "  - k6でGreen環境のトラフィックを確認: k6 run k6/canary_test.js"
  echo "  - 問題なければ旧Blue環境を削除: terraform workspace select blue && terraform destroy"
  echo "  - 問題があればロールバック: bash scripts/blue_green_switch.sh --direction green-to-blue ..."
else
  echo "  - Blueへの切り戻し完了"
  echo "  - Green環境の問題を調査・修正してから再度切り替えを試みる"
fi
divider
