#!/usr/bin/env bash
# verify_routing.sh — Strangler Fig ルーティング検証スクリプト
#
# 各パスへリクエストを送り、X-Handled-By ヘッダを確認して
# 正しいバックエンドが処理したことを検証する。
#
# 使い方:
#   bash scripts/verify_routing.sh
#   bash scripts/verify_routing.sh --base-url http://your-server
#
# 終了コード:
#   0 = 全テスト合格
#   1 = いずれかのテストが失敗

set -euo pipefail

# ── 設定 ─────────────────────────────────────────────────────────────────────
BASE_URL="${BASE_URL:-http://localhost}"
LARAVEL_URL="${LARAVEL_URL:-http://localhost:8000}"
ECHO_URL="${ECHO_URL:-http://localhost:8080}"
TIMEOUT=5

# 色付き出力
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PASS=0
FAIL=0

# ── ヘルパー関数 ──────────────────────────────────────────────────────────────

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# check_routing: パスにリクエストして X-Handled-By が期待値と一致するか確認
# 引数: <path> <expected_handled_by> <description>
check_routing() {
  local path="$1"
  local expected="$2"
  local desc="$3"
  local url="${BASE_URL}${path}"

  # リクエスト送信 (ヘッダのみ取得)
  local response
  response=$(curl -s -o /dev/null -D - \
    --max-time "${TIMEOUT}" \
    -H "X-Request-ID: verify-routing-$$" \
    "${url}" 2>/dev/null || echo "CURL_ERROR")

  if [[ "${response}" == "CURL_ERROR" ]]; then
    log_fail "${desc}: curl failed (${url})"
    return
  fi

  # X-Handled-By ヘッダを抽出 (大文字小文字を無視)
  local handled_by
  handled_by=$(echo "${response}" | grep -i "x-handled-by:" | awk '{print $2}' | tr -d '\r' || echo "")

  if [[ "${handled_by}" == "${expected}" ]]; then
    log_pass "${desc}: X-Handled-By=${handled_by} (${url})"
  else
    log_fail "${desc}: expected='${expected}' got='${handled_by}' (${url})"
  fi
}

# check_request_id_propagation: X-Request-ID が正しく伝播されるか確認
check_request_id_propagation() {
  local path="$1"
  local test_id="test-reqid-$$-${RANDOM}"

  local response
  response=$(curl -s -o /dev/null -D - \
    --max-time "${TIMEOUT}" \
    -H "X-Request-ID: ${test_id}" \
    "${BASE_URL}${path}" 2>/dev/null || echo "")

  local returned_id
  returned_id=$(echo "${response}" | grep -i "x-request-id:" | awk '{print $2}' | tr -d '\r' || echo "")

  if [[ "${returned_id}" == "${test_id}" ]]; then
    log_pass "X-Request-ID propagation for ${path}: ${returned_id}"
  else
    log_fail "X-Request-ID propagation for ${path}: expected='${test_id}' got='${returned_id}'"
  fi
}

# check_http_status: HTTP ステータスコードを確認
check_http_status() {
  local url="$1"
  local expected_status="$2"
  local desc="$3"

  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "${TIMEOUT}" \
    "${url}" 2>/dev/null || echo "000")

  if [[ "${status}" == "${expected_status}" ]]; then
    log_pass "${desc}: HTTP ${status} (${url})"
  else
    log_fail "${desc}: expected HTTP ${expected_status} got ${status} (${url})"
  fi
}

# ── メイン処理 ────────────────────────────────────────────────────────────────

echo ""
echo "========================================================"
echo "  Strangler Fig ルーティング検証"
echo "  BASE_URL: ${BASE_URL}"
echo "========================================================"
echo ""

# ── 1. バックエンドの死活確認 ─────────────────────────────────────────────────
log_info "=== バックエンド疎通確認 ==="

if curl -s --max-time "${TIMEOUT}" "${ECHO_URL}/health" > /dev/null 2>&1; then
  log_pass "Echo backend is up (${ECHO_URL})"
else
  log_warn "Echo backend may be down (${ECHO_URL}) — routing tests may fail"
fi

if curl -s --max-time "${TIMEOUT}" "${LARAVEL_URL}/" > /dev/null 2>&1; then
  log_pass "Laravel backend is up (${LARAVEL_URL})"
else
  log_warn "Laravel backend may be down (${LARAVEL_URL}) — routing tests may fail"
fi

echo ""

# ── 2. ルーティング確認 ───────────────────────────────────────────────────────
log_info "=== パスベースルーティング確認 ==="

# Echo に流れるべきパス
check_routing "/heartbeat"  "echo"    "GET /heartbeat -> Echo"
check_routing "/events"     "echo"    "POST /events -> Echo (GET でも確認)"
check_routing "/health"     "echo"    "GET /health -> Echo"
check_routing "/api/v2/"    "echo"    "GET /api/v2/ -> Echo"

# Laravel に流れるべきパス
check_routing "/api/legacy/" "laravel" "GET /api/legacy/ -> Laravel"
check_routing "/"            "laravel" "GET / -> Laravel (デフォルト)"
check_routing "/api/users"   "laravel" "GET /api/users -> Laravel"

echo ""

# ── 3. X-Request-ID 伝播確認 ─────────────────────────────────────────────────
log_info "=== X-Request-ID 伝播確認 ==="

check_request_id_propagation "/heartbeat"
check_request_id_propagation "/health"
check_request_id_propagation "/"

echo ""

# ── 4. Echo 直接確認 ──────────────────────────────────────────────────────────
log_info "=== Echo 直接アクセス確認 (Nginx バイパス) ==="

check_http_status "${ECHO_URL}/health" "200" "Echo /health"

echo ""

# ── 5. 結果サマリ ─────────────────────────────────────────────────────────────
echo "========================================================"
echo "  テスト結果: PASS=${PASS} FAIL=${FAIL}"
echo "========================================================"

if [[ "${FAIL}" -gt 0 ]]; then
  echo ""
  log_fail "一部テストが失敗しました。Nginx 設定を確認してください:"
  echo "  sudo nginx -t"
  echo "  sudo systemctl status nginx"
  echo "  sudo tail -f /var/log/nginx/error.log"
  exit 1
else
  echo ""
  log_pass "全テスト合格! ルーティングは正常に機能しています。"
  exit 0
fi
