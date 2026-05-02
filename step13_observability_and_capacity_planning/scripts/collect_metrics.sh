#!/usr/bin/env bash
# collect_metrics.sh — API メトリクス収集スクリプト
#
# /metrics エンドポイントを定期的にポーリングして CSV に書き込む。
# MySQL のスロークエリ数と Redis メモリも合わせて記録する。
#
# 使い方:
#   bash scripts/collect_metrics.sh
#   bash scripts/collect_metrics.sh --interval 5 --output /tmp/metrics.csv
#
# Ctrl+C で停止する。

set -euo pipefail

# ── 設定 ─────────────────────────────────────────────────────────────────────
API_URL="${API_URL:-http://localhost:8080}"
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"
MYSQL_HOST="${MYSQL_HOST:-localhost}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-password}"
INTERVAL="${INTERVAL:-10}"
OUTPUT_FILE="${OUTPUT_FILE:-/tmp/metrics_$(date +%Y%m%d).csv}"

# 引数解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)  INTERVAL="$2";     shift 2 ;;
    --output)    OUTPUT_FILE="$2";  shift 2 ;;
    --api-url)   API_URL="$2";      shift 2 ;;
    *) shift ;;
  esac
done

# ── CSV ヘッダ書き込み (初回のみ) ─────────────────────────────────────────────
if [[ ! -f "${OUTPUT_FILE}" ]]; then
  echo "timestamp,uptime,total_requests,cache_hits,cache_misses,cache_hit_rate,goroutines,redis_used_memory_bytes,mysql_slow_queries" \
    > "${OUTPUT_FILE}"
  echo "CSV file created: ${OUTPUT_FILE}"
fi

# ── jq チェック ───────────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo "WARNING: 'jq' not found. Install: sudo apt-get install -y jq"
  echo "         Falling back to grep-based parsing."
  USE_JQ=false
else
  USE_JQ=true
fi

# ── ヘルパー: JSON から値を取得 ───────────────────────────────────────────────
get_json_value() {
  local json="$1"
  local key="$2"
  local default="${3:-0}"

  if [[ "${USE_JQ}" == "true" ]]; then
    echo "${json}" | jq -r ".${key} // ${default}" 2>/dev/null || echo "${default}"
  else
    # jq なしの fallback (簡易 grep)
    echo "${json}" | grep -oP "\"${key}\":\s*\K[0-9.]+" 2>/dev/null | head -1 || echo "${default}"
  fi
}

# ── Redis メモリ取得 ──────────────────────────────────────────────────────────
get_redis_memory() {
  if command -v redis-cli &>/dev/null; then
    redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" INFO memory 2>/dev/null \
      | grep "^used_memory:" \
      | cut -d: -f2 \
      | tr -d '\r' \
      | tr -d ' ' \
      || echo "0"
  else
    echo "0"
  fi
}

# ── MySQL スロークエリ数取得 ──────────────────────────────────────────────────
get_mysql_slow_queries() {
  if command -v mysql &>/dev/null; then
    mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" \
          -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
          --silent --skip-column-names \
          -e "SHOW GLOBAL STATUS LIKE 'Slow_queries';" 2>/dev/null \
      | awk '{print $2}' \
      || echo "0"
  else
    echo "0"
  fi
}

# ── メイン収集ループ ──────────────────────────────────────────────────────────

echo "Starting metrics collection..."
echo "  API:    ${API_URL}/metrics"
echo "  Output: ${OUTPUT_FILE}"
echo "  Interval: ${INTERVAL}s"
echo "Press Ctrl+C to stop."
echo ""

COLLECT_COUNT=0

while true; do
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # /metrics を叩く
  METRICS_JSON=$(curl -s --max-time 5 "${API_URL}/metrics" 2>/dev/null || echo "{}")

  # 値を抽出
  UPTIME=$(get_json_value "${METRICS_JSON}" "uptime" "0s")
  TOTAL_REQ=$(get_json_value "${METRICS_JSON}" "total_requests" "0")
  CACHE_HITS=$(get_json_value "${METRICS_JSON}" "cache_hits" "0")
  CACHE_MISSES=$(get_json_value "${METRICS_JSON}" "cache_misses" "0")
  CACHE_HIT_RATE=$(get_json_value "${METRICS_JSON}" "cache_hit_rate" "0")
  GOROUTINES=$(get_json_value "${METRICS_JSON}" "goroutines" "0")

  # Redis / MySQL から取得
  REDIS_MEM=$(get_redis_memory)
  MYSQL_SLOW=$(get_mysql_slow_queries)

  # CSV に追記
  echo "${TIMESTAMP},${UPTIME},${TOTAL_REQ},${CACHE_HITS},${CACHE_MISSES},${CACHE_HIT_RATE},${GOROUTINES},${REDIS_MEM},${MYSQL_SLOW}" \
    >> "${OUTPUT_FILE}"

  # コンソール表示
  COLLECT_COUNT=$((COLLECT_COUNT + 1))
  printf "[%s] #%d | req=%s | cache_hit=%.1f%% | goroutines=%s | redis_mem=%sB | mysql_slow=%s\n" \
    "${TIMESTAMP}" "${COLLECT_COUNT}" "${TOTAL_REQ}" "${CACHE_HIT_RATE}" \
    "${GOROUTINES}" "${REDIS_MEM}" "${MYSQL_SLOW}"

  sleep "${INTERVAL}"
done
