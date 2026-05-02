#!/usr/bin/env bash
# lower_ttl.sh
# Route53レコードのTTLを変更するスクリプト
# Blue/Green切り替えの15〜30分前にTTLを30秒に短縮することで、
# 切り戻し時のDNS伝播時間を最小化する。
#
# 使用方法:
#   # TTLを30秒に短縮（切り替え前）
#   bash scripts/lower_ttl.sh --zone-id Z1234567890 --record-name app.example.com --ttl 30
#
#   # TTLを300秒に戻す（切り替え完了後）
#   bash scripts/lower_ttl.sh --zone-id Z1234567890 --record-name app.example.com --ttl 300
#
# 注意: AliasレコードはTTLをRoute53側で管理するため、このスクリプトはCNAME/Aレコード向け。
#       Aliasレコードの場合はEvaluateTargetHealthで制御する。

set -euo pipefail

# ─── Default values ───────────────────────────────────────────────────────────
ZONE_ID=""
RECORD_NAME=""
NEW_TTL=""
RECORD_TYPE="A"
REGION="${AWS_REGION:-ap-northeast-1}"

# ─── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --zone-id)     ZONE_ID="$2";     shift 2 ;;
    --record-name) RECORD_NAME="$2"; shift 2 ;;
    --ttl)         NEW_TTL="$2";     shift 2 ;;
    --type)        RECORD_TYPE="$2"; shift 2 ;;
    --region)      REGION="$2";      shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 --zone-id <id> --record-name <name> --ttl <seconds>" >&2
      exit 1
      ;;
  esac
done

# ─── Validate ─────────────────────────────────────────────────────────────────
missing=()
[[ -z "$ZONE_ID" ]]     && missing+=("--zone-id")
[[ -z "$RECORD_NAME" ]] && missing+=("--record-name")
[[ -z "$NEW_TTL" ]]     && missing+=("--ttl")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Error: Missing required arguments: ${missing[*]}" >&2
  exit 1
fi

if ! [[ "$NEW_TTL" =~ ^[0-9]+$ ]]; then
  echo "Error: --ttl must be a positive integer (got: $NEW_TTL)" >&2
  exit 1
fi

# Ensure record name ends with dot
if [[ "$RECORD_NAME" != *. ]]; then
  RECORD_NAME_FQDN="${RECORD_NAME}."
else
  RECORD_NAME_FQDN="$RECORD_NAME"
fi

divider() { echo "=============================================================="; }
ts()      { date '+%Y-%m-%d %H:%M:%S'; }

# ─── Step 1: Get current record ───────────────────────────────────────────────
divider
echo "Route53 TTL Changer"
divider
echo ""
echo "Zone ID     : $ZONE_ID"
echo "Record      : $RECORD_NAME_FQDN"
echo "Record Type : $RECORD_TYPE"
echo "New TTL     : ${NEW_TTL}s"
echo ""

echo "[$(ts)] Fetching current record..."
CURRENT_RECORDS=$(aws route53 list-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME_FQDN}' && Type=='${RECORD_TYPE}']" \
  --output json 2>/dev/null || echo "[]")

if [[ "$CURRENT_RECORDS" == "[]" || -z "$CURRENT_RECORDS" ]]; then
  echo "Error: No ${RECORD_TYPE} record found for '${RECORD_NAME_FQDN}' in zone '${ZONE_ID}'" >&2
  echo ""
  echo "Available records:"
  aws route53 list-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[*].{Name:Name,Type:Type,TTL:TTL}" \
    --output table 2>/dev/null || echo "  (could not list records)"
  exit 1
fi

echo "Current record:"
echo "$CURRENT_RECORDS" | python3 -m json.tool 2>/dev/null || echo "$CURRENT_RECORDS"

# Extract current TTL
CURRENT_TTL=$(echo "$CURRENT_RECORDS" | python3 -c "
import sys, json
records = json.load(sys.stdin)
if records:
    print(records[0].get('TTL', 'N/A'))
else:
    print('N/A')
" 2>/dev/null || echo "N/A")

echo ""
echo "Current TTL : ${CURRENT_TTL}s"
echo "New TTL     : ${NEW_TTL}s"

if [[ "$CURRENT_TTL" == "$NEW_TTL" ]]; then
  echo ""
  echo "TTL is already set to ${NEW_TTL}s. No change needed."
  exit 0
fi

# ─── Step 2: Build change batch ───────────────────────────────────────────────
echo ""
echo "[$(ts)] Building change batch..."

# Extract ResourceRecords from current record
RESOURCE_RECORDS=$(echo "$CURRENT_RECORDS" | python3 -c "
import sys, json
records = json.load(sys.stdin)
if records and 'ResourceRecords' in records[0]:
    rr = records[0]['ResourceRecords']
    print(json.dumps(rr))
else:
    print('[]')
" 2>/dev/null || echo "[]")

# Build the change batch JSON with new TTL
CHANGE_BATCH=$(python3 -c "
import json, sys

zone_id = '$ZONE_ID'
record_name = '$RECORD_NAME_FQDN'
record_type = '$RECORD_TYPE'
new_ttl = int('$NEW_TTL')
resource_records = json.loads('''$RESOURCE_RECORDS''')

change = {
    'Comment': f'TTL change to {new_ttl}s',
    'Changes': [
        {
            'Action': 'UPSERT',
            'ResourceRecordSet': {
                'Name': record_name,
                'Type': record_type,
                'TTL': new_ttl,
                'ResourceRecords': resource_records
            }
        }
    ]
}
print(json.dumps(change, indent=2))
" 2>/dev/null)

if [[ -z "$CHANGE_BATCH" ]]; then
  echo "Error: Failed to build change batch. The record may be an Alias record (TTL is managed by AWS)." >&2
  echo ""
  echo "For Alias records, TTL is managed automatically by Route53 and cannot be changed directly."
  echo "Use EvaluateTargetHealth to control failover behavior instead."
  exit 1
fi

echo "Change batch:"
echo "$CHANGE_BATCH"

# ─── Step 3: Confirm and apply ────────────────────────────────────────────────
echo ""
echo "[$(ts)] Applying TTL change: ${CURRENT_TTL}s -> ${NEW_TTL}s"

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

echo ""
echo "Change submitted successfully!"
echo "  Change ID : $CHANGE_ID"
echo "  Status    : $CHANGE_STATUS"

# ─── Step 4: Wait for INSYNC ──────────────────────────────────────────────────
if [[ -n "$CHANGE_ID" ]]; then
  echo ""
  echo "[$(ts)] Waiting for change to reach INSYNC status..."
  max_wait=60
  elapsed=0
  while (( elapsed < max_wait )); do
    status=$(aws route53 get-change \
      --id "$CHANGE_ID" \
      --query "ChangeInfo.Status" \
      --output text 2>/dev/null || echo "UNKNOWN")
    echo "  [$(ts)] Status: $status (${elapsed}s)"
    if [[ "$status" == "INSYNC" ]]; then
      echo "  -> INSYNC: TTL change is now live"
      break
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
  done
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
divider
echo "TTL Change Complete"
echo ""
echo "  Record  : $RECORD_NAME_FQDN"
echo "  Old TTL : ${CURRENT_TTL}s"
echo "  New TTL : ${NEW_TTL}s"
echo ""

if (( NEW_TTL <= 60 )); then
  echo "注意事項:"
  echo "  - TTL ${NEW_TTL}秒は本番環境では低すぎる可能性があります"
  echo "  - Blue/Green切り替え完了後は必ずTTLを元に戻してください:"
  echo "    bash scripts/lower_ttl.sh --zone-id $ZONE_ID --record-name ${RECORD_NAME_FQDN%%.} --ttl 300"
  echo ""
  echo "次のアクション:"
  echo "  - 現在のTTL（${CURRENT_TTL}s）が期限切れになるまで待機: ${CURRENT_TTL}秒"
  echo "  - その後 blue_green_switch.sh を実行してください"
fi
divider
