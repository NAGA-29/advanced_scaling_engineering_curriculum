#!/usr/bin/env bash
# mission_checklist.sh — 最終移行演習 ミッションチェックリスト
#
# 11のミッションを対話的に確認し、各ミッションの合否を判定する。
#
# 使い方:
#   bash scripts/mission_checklist.sh          # 対話型チェックリスト
#   bash scripts/mission_checklist.sh --verify-all  # 全自動検証
#   bash scripts/mission_checklist.sh --mission 3   # ミッション3のみ検証

set -uo pipefail

# ── 設定 ─────────────────────────────────────────────────────────────────────
API_URL="${API_URL:-http://localhost:8080}"
LARAVEL_URL="${LARAVEL_URL:-http://localhost:8000}"
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"
MYSQL_HOST="${MYSQL_HOST:-localhost}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-password}"

VERIFY_ALL=false
SINGLE_MISSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-all)   VERIFY_ALL=true; shift ;;
    --mission)      SINGLE_MISSION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── 色付き出力 ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

log_pass()  { echo -e "${GREEN}[PASS]${NC} $*"; ((PASS_COUNT++)); }
log_fail()  { echo -e "${RED}[FAIL]${NC} $*"; ((FAIL_COUNT++)); }
log_skip()  { echo -e "${YELLOW}[SKIP]${NC} $*"; ((SKIP_COUNT++)); }
log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_check() { echo -e "${CYAN}[CHECK]${NC} $*"; }

# ── ヘルパー関数 ──────────────────────────────────────────────────────────────

# http_check: HTTP リクエストを送り、期待するステータスコードかを確認
http_check() {
  local desc="$1"
  local url="$2"
  local expected_status="${3:-200}"
  local method="${4:-GET}"
  local body="${5:-}"

  local status
  if [[ -n "${body}" ]]; then
    status=$(curl -s -o /dev/null -w "%{http_code}" \
      -X "${method}" \
      -H "Content-Type: application/json" \
      -d "${body}" \
      --max-time 5 \
      "${url}" 2>/dev/null || echo "000")
  else
    status=$(curl -s -o /dev/null -w "%{http_code}" \
      -X "${method}" \
      --max-time 5 \
      "${url}" 2>/dev/null || echo "000")
  fi

  if [[ "${status}" == "${expected_status}" ]]; then
    log_pass "${desc} (HTTP ${status})"
    return 0
  else
    log_fail "${desc}: expected HTTP ${expected_status}, got ${status} (${url})"
    return 1
  fi
}

# header_check: レスポンスヘッダを確認
header_check() {
  local desc="$1"
  local url="$2"
  local header_name="$3"
  local expected_value="$4"

  local header_value
  header_value=$(curl -s -o /dev/null -D - --max-time 5 "${url}" 2>/dev/null \
    | grep -i "^${header_name}:" \
    | awk '{print $2}' \
    | tr -d '\r' || echo "")

  if [[ "${header_value}" == "${expected_value}" ]]; then
    log_pass "${desc}: ${header_name}=${header_value}"
    return 0
  else
    log_fail "${desc}: expected ${header_name}=${expected_value}, got '${header_value}'"
    return 1
  fi
}

# ask_confirm: 対話型確認 (--verify-all の場合はスキップ)
ask_confirm() {
  local desc="$1"
  if [[ "${VERIFY_ALL}" == "true" ]]; then
    log_skip "${desc} (manual verification skipped in --verify-all mode)"
    return 0
  fi
  echo -e "${YELLOW}手動確認が必要です:${NC} ${desc}"
  echo -n "  完了しましたか? [y/N]: "
  read -r answer
  if [[ "${answer}" =~ ^[Yy]$ ]]; then
    log_pass "${desc} (手動確認済み)"
    return 0
  else
    log_fail "${desc} (未完了)"
    return 1
  fi
}

# ── ミッション定義 ────────────────────────────────────────────────────────────

mission_01() {
  echo ""
  echo -e "${BOLD}MISSION 01: 初期状態の確認と計測${NC}"
  echo "  Laravel 単体構成でベースライン計測を実施する"
  echo ""

  # Laravel が起動しているか
  log_check "Laravel API の疎通確認"
  http_check "Laravel /api health" "${LARAVEL_URL}/" 200 || true

  ask_confirm "k6 でベースライン計測を実施し、report.md に記録した (k6 run k6/final_test.js)"
}

mission_02() {
  echo ""
  echo -e "${BOLD}MISSION 02: Redis キャッシュ追加${NC}"
  echo "  Redis を起動してキャッシュヒット率 > 70% を確認する"
  echo ""

  # Redis 疎通確認
  log_check "Redis 接続確認"
  if redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" PING 2>/dev/null | grep -q "PONG"; then
    log_pass "Redis is up"
  else
    log_fail "Redis is not responding at ${REDIS_HOST}:${REDIS_PORT}"
  fi

  # API のキャッシュヘッダ確認
  log_check "2回目リクエストで X-Cache: HIT を確認"
  curl -s --max-time 5 "${API_URL}/heartbeat?device_id=test-001" > /dev/null 2>&1 || true
  header_check "Cache HIT on 2nd request" \
    "${API_URL}/heartbeat?device_id=test-001" \
    "X-Cache" "HIT" || true
}

mission_03() {
  echo ""
  echo -e "${BOLD}MISSION 03: Strangler Fig — Echo 追加${NC}"
  echo "  /heartbeat が Echo で処理されることを確認する"
  echo ""

  log_check "/heartbeat の X-Handled-By ヘッダを確認"
  header_check "/heartbeat -> Echo" \
    "${API_URL}/heartbeat" \
    "X-Handled-By" "echo" || true

  log_check "/api/legacy/* が Laravel で処理されることを確認"
  header_check "/api/legacy/ -> Laravel" \
    "${API_URL}/api/legacy/" \
    "X-Handled-By" "laravel" || true
}

mission_04() {
  echo ""
  echo -e "${BOLD}MISSION 04: 非同期キューワーカー追加${NC}"
  echo "  POST /events が 202 Accepted で即座に返ることを確認する"
  echo ""

  log_check "POST /events -> 202 Accepted"
  http_check "POST /events returns 202" \
    "${API_URL}/events" \
    "202" \
    "POST" \
    '{"device_id":"checklist-test","event_type":"heartbeat"}' || true

  log_check "Redis Stream にメッセージが入っているか確認"
  if redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" XLEN events 2>/dev/null | grep -qv "^0$"; then
    log_pass "Redis Stream 'events' has messages"
  else
    log_info "Redis Stream 'events' is empty or not available"
  fi
}

mission_05() {
  echo ""
  echo -e "${BOLD}MISSION 05: MySQL Read Replica 追加${NC}"
  echo "  SELECT クエリが Replica に流れることを確認する"
  echo ""

  ask_confirm "MySQL Read Replica を設定し、SELECT クエリが Replica に流れることを確認した"
}

mission_06() {
  echo ""
  echo -e "${BOLD}MISSION 06: DB Sharding${NC}"
  echo "  user_id の偶奇でシャードが切り替わることを確認する"
  echo ""

  ask_confirm "DB Sharding Resolver を実装し、user_id 偶数/奇数で別シャードに振り分けられることを確認した"
}

mission_07() {
  echo ""
  echo -e "${BOLD}MISSION 07: Circuit Breaker 有効化${NC}"
  echo "  DB 停止後に Circuit Breaker が OPEN になることを確認する"
  echo ""

  log_check "/circuit-breaker/status エンドポイントの疎通確認"
  if curl -s --max-time 5 "${API_URL}/circuit-breaker/status" 2>/dev/null | grep -q "state"; then
    local state
    state=$(curl -s --max-time 5 "${API_URL}/circuit-breaker/status" 2>/dev/null \
      | grep -oP '"state"\s*:\s*"\K[^"]+' || echo "unknown")
    log_pass "Circuit Breaker is available: state=${state}"
  else
    log_fail "/circuit-breaker/status not available"
  fi

  ask_confirm "DB を停止 (chaos.sh db-stop) して Circuit Breaker が OPEN になることを確認した"
}

mission_08() {
  echo ""
  echo -e "${BOLD}MISSION 08: Blue/Green デプロイ準備${NC}"
  echo "  Blue/Green の切り替えスクリプトが動作することを確認する"
  echo ""

  ask_confirm "Blue/Green 切り替えスクリプト (step06 参照) を実行し、ダウンタイムなし切り替えを確認した"
}

mission_09() {
  echo ""
  echo -e "${BOLD}MISSION 09: ゼロダウンタイムスキーママイグレーション${NC}"
  echo "  Expand → Migrate → Contract の 3フェーズ実施を確認する"
  echo ""

  ask_confirm "カラム追加マイグレーション中も API が応答し続けることを確認した (step09 参照)"
}

mission_10() {
  echo ""
  echo -e "${BOLD}MISSION 10: 観測とキャパシティ確認${NC}"
  echo "  capacity_calc.sh でリソース見積もりを実施する"
  echo ""

  log_check "capacity_calc.sh の実行確認"
  if command -v bash &>/dev/null; then
    log_pass "bash available for capacity_calc.sh"
  fi

  ask_confirm "capacity_calc.sh を実行し、結果を report.md に記録した"

  log_check "/metrics エンドポイントの疎通確認"
  http_check "GET /metrics" "${API_URL}/metrics" 200 || true
}

mission_11() {
  echo ""
  echo -e "${BOLD}MISSION 11: 最終 k6 テストと比較${NC}"
  echo "  最終構成で k6 を実行し、初期状態と比較する"
  echo ""

  log_check "全エンドポイントの疎通確認"
  http_check "GET /health"    "${API_URL}/health"    200 || true
  http_check "GET /heartbeat" "${API_URL}/heartbeat" 200 || true

  ask_confirm "k6 run k6/final_test.js を実行し、結果を report.md に記録した"
  ask_confirm "初期状態と最終構成の k6 結果を比較し、改善量を確認した"
}

# ── メイン実行 ────────────────────────────────────────────────────────────────

print_header() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║    STEP 14: 最終移行演習 ミッションチェックリスト         ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

print_footer() {
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo -e "  結果: ${GREEN}PASS=${PASS_COUNT}${NC}  ${RED}FAIL=${FAIL_COUNT}${NC}  ${YELLOW}SKIP=${SKIP_COUNT}${NC}"
  echo "════════════════════════════════════════════════════════════"

  if [[ "${FAIL_COUNT}" -eq 0 ]]; then
    echo -e "${GREEN}  おめでとうございます! 全ミッションをクリアしました!${NC}"
    echo ""
    echo "  次のステップ:"
    echo "  1. report.md を完成させてください"
    echo "  2. 全リソースを削除してください (README.md の削除手順参照)"
  else
    echo -e "${YELLOW}  ${FAIL_COUNT} 個のミッションが未完了です。${NC}"
    echo "  FAIL になったミッションを確認して再チャレンジしてください。"
  fi
  echo ""
}

print_header

if [[ -n "${SINGLE_MISSION}" ]]; then
  "mission_$(printf '%02d' "${SINGLE_MISSION}")" 2>/dev/null || {
    echo "Unknown mission: ${SINGLE_MISSION}"
    exit 1
  }
else
  mission_01
  mission_02
  mission_03
  mission_04
  mission_05
  mission_06
  mission_07
  mission_08
  mission_09
  mission_10
  mission_11
fi

print_footer

[[ "${FAIL_COUNT}" -eq 0 ]]
