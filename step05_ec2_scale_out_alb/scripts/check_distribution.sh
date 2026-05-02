#!/usr/bin/env bash
# check_distribution.sh
# ALB配下のEC2インスタンスへのリクエスト分散を確認するスクリプト
# 使用方法: bash check_distribution.sh <ALB_DNS>
# 例:       bash check_distribution.sh my-alb-1234567890.ap-northeast-1.elb.amazonaws.com

set -euo pipefail

ALB_DNS="${1:-}"
REQUESTS="${2:-20}"

if [[ -z "$ALB_DNS" ]]; then
  echo "Error: ALB DNS name is required." >&2
  echo "Usage: $0 <ALB_DNS> [num_requests]" >&2
  exit 1
fi

echo "=========================================="
echo "ALB Distribution Check"
echo "Target : http://${ALB_DNS}/health"
echo "Requests: ${REQUESTS}"
echo "=========================================="
echo ""

declare -A counts
total=0
errors=0

for i in $(seq 1 "$REQUESTS"); do
  response=$(curl -s --max-time 5 "http://${ALB_DNS}/health" 2>/dev/null || echo "")

  if [[ -z "$response" ]]; then
    echo "  Request $i: ERROR (no response)"
    ((errors++)) || true
    ((total++)) || true
    continue
  fi

  hostname=$(echo "$response" | jq -r '.hostname // "unknown"' 2>/dev/null || echo "unknown")
  status=$(echo "$response" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

  counts["$hostname"]=$((${counts["$hostname"]:-0} + 1))
  ((total++)) || true

  echo "  Request $i -> hostname: ${hostname}  status: ${status}"
done

echo ""
echo "=========================================="
echo "Distribution Summary"
echo "=========================================="
echo "Total requests: $total"
echo "Errors        : $errors"
echo ""

if [[ ${#counts[@]} -eq 0 ]]; then
  echo "No successful responses recorded."
  exit 1
fi

# Sort hostnames for consistent output
sorted_hosts=$(echo "${!counts[@]}" | tr ' ' '\n' | sort)

max_count=0
for host in $sorted_hosts; do
  cnt=${counts[$host]}
  if (( cnt > max_count )); then
    max_count=$cnt
  fi
done

for host in $sorted_hosts; do
  cnt=${counts[$host]}
  if (( total > 0 )); then
    pct=$(awk "BEGIN { printf \"%.1f\", ($cnt / $total) * 100 }")
  else
    pct="0.0"
  fi

  # ASCII bar chart (max 30 chars wide)
  bar_width=30
  filled=$(awk "BEGIN { printf \"%d\", ($cnt / $max_count) * $bar_width }")
  bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
  empty=$(printf '%*s' "$((bar_width - filled))" '' | tr ' ' '.')

  printf "  %-20s : %3d (%5s%%)  [%s%s]\n" "$host" "$cnt" "$pct" "$bar" "$empty"
done

echo ""

# Check for even distribution (warn if skew > 30%)
if (( ${#counts[@]} > 1 && total > 0 )); then
  expected=$(awk "BEGIN { printf \"%d\", $total / ${#counts[@]} }")
  skewed=0
  for host in $sorted_hosts; do
    cnt=${counts[$host]}
    diff=$(awk "BEGIN { diff = $cnt - $expected; if (diff < 0) diff = -diff; print diff }")
    pct_diff=$(awk "BEGIN { printf \"%.1f\", ($diff / $expected) * 100 }")
    if awk "BEGIN { exit ($diff / $expected < 0.3) }"; then
      echo "WARNING: $host has ${pct_diff}% deviation from expected distribution (${expected} requests)"
      skewed=1
    fi
  done
  if (( skewed == 0 )); then
    echo "OK: Distribution is balanced (within 30% deviation from expected)"
  fi
fi

echo "=========================================="
