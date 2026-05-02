#!/usr/bin/env bash
# monitor_queue.sh — Redis Stream キュー深さ・Consumer Lag 監視スクリプト
#
# 使い方:
#   bash scripts/monitor_queue.sh
#   bash scripts/monitor_queue.sh --stream events --group workers --interval 5
#
# 環境変数:
#   REDIS_HOST    (default: localhost)
#   REDIS_PORT    (default: 6379)
#   REDIS_PASSWORD (default: なし)

set -euo pipefail

# ── デフォルト設定 ────────────────────────────────────────────────────────────
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
STREAM="${STREAM:-events}"
GROUP="${GROUP:-workers}"
INTERVAL="${INTERVAL:-10}"

# 引数解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stream)     STREAM="$2";    shift 2 ;;
    --group)      GROUP="$2";     shift 2 ;;
    --interval)   INTERVAL="$2";  shift 2 ;;
    --host)       REDIS_HOST="$2"; shift 2 ;;
    --port)       REDIS_PORT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── redis-cli コマンド構築 ────────────────────────────────────────────────────
REDIS_CLI_ARGS="-h ${REDIS_HOST} -p ${REDIS_PORT}"
if [[ -n "${REDIS_PASSWORD}" ]]; then
  REDIS_CLI_ARGS="${REDIS_CLI_ARGS} -a ${REDIS_PASSWORD}"
fi

redis_cmd() {
  redis-cli ${REDIS_CLI_ARGS} "$@" 2>/dev/null
}

# ── 色付き出力 ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── 接続確認 ──────────────────────────────────────────────────────────────────
if ! redis_cmd PING > /dev/null 2>&1; then
  echo -e "${RED}ERROR: Cannot connect to Redis at ${REDIS_HOST}:${REDIS_PORT}${NC}"
  echo "       redis-cli PING failed"
  exit 1
fi

echo -e "${GREEN}Connected to Redis at ${REDIS_HOST}:${REDIS_PORT}${NC}"
echo -e "${CYAN}Monitoring stream='${STREAM}' group='${GROUP}' (every ${INTERVAL}s)${NC}"
echo "Press Ctrl+C to stop"
echo ""

# ── ヘッダ表示 ────────────────────────────────────────────────────────────────
print_header() {
  echo -e "${BLUE}$(date '+%Y-%m-%d %H:%M:%S') ────────────────────────────────────────${NC}"
}

# ── メトリクス収集・表示 ──────────────────────────────────────────────────────
collect_and_display() {
  print_header

  # 1. ストリーム全体の長さ (XLEN)
  local stream_len
  stream_len=$(redis_cmd XLEN "${STREAM}" || echo "N/A")
  echo -e "  Stream Length (XLEN):    ${YELLOW}${stream_len}${NC} messages"

  # 2. Consumer Group 情報 (XINFO GROUPS)
  echo ""
  echo -e "  ${CYAN}Consumer Group: ${GROUP}${NC}"

  local group_info
  group_info=$(redis_cmd XINFO GROUPS "${STREAM}" 2>/dev/null || echo "")

  if [[ -n "${group_info}" ]]; then
    # pending-count を抽出
    local pending_count
    pending_count=$(echo "${group_info}" | grep -A1 "pending" | tail -1 | tr -d ' ' || echo "N/A")
    local last_delivered
    last_delivered=$(echo "${group_info}" | grep -A1 "last-delivered-id" | tail -1 | tr -d ' ' || echo "N/A")

    echo -e "    Pending (未ACK):       ${RED}${pending_count}${NC} messages"
    echo -e "    Last Delivered ID:     ${last_delivered}"
  else
    echo "    (group not found — run: redis-cli XGROUP CREATE ${STREAM} ${GROUP} \$ MKSTREAM)"
  fi

  # 3. Pending メッセージ詳細 (XPENDING)
  echo ""
  echo -e "  ${CYAN}Pending Messages (最新10件):${NC}"
  local pending_detail
  pending_detail=$(redis_cmd XPENDING "${STREAM}" "${GROUP}" - + 10 2>/dev/null || echo "")

  if [[ -n "${pending_detail}" && "${pending_detail}" != "(empty list or set)" ]]; then
    echo "${pending_detail}" | while IFS= read -r line; do
      echo "    ${line}"
    done
  else
    echo -e "    ${GREEN}(none — all messages acknowledged)${NC}"
  fi

  # 4. アクティブなコンシューマー (XINFO CONSUMERS)
  echo ""
  echo -e "  ${CYAN}Active Consumers:${NC}"
  local consumers
  consumers=$(redis_cmd XINFO CONSUMERS "${STREAM}" "${GROUP}" 2>/dev/null || echo "")

  if [[ -n "${consumers}" && "${consumers}" != "(empty list or set)" ]]; then
    echo "${consumers}" | grep -E "name|pending|idle" | while IFS= read -r line; do
      echo "    ${line}"
    done
  else
    echo "    (no active consumers)"
  fi

  # 5. Redis メモリ情報
  echo ""
  echo -e "  ${CYAN}Redis Memory:${NC}"
  local used_memory
  used_memory=$(redis_cmd INFO memory | grep "used_memory_human:" | cut -d: -f2 | tr -d '\r' | tr -d ' ' || echo "N/A")
  local maxmemory
  maxmemory=$(redis_cmd CONFIG GET maxmemory | tail -1 | tr -d ' ' || echo "N/A")
  echo -e "    Used:     ${used_memory}"
  echo -e "    Max:      ${maxmemory} bytes"

  echo ""
}

# ── メインループ ──────────────────────────────────────────────────────────────
while true; do
  collect_and_display
  sleep "${INTERVAL}"
done
