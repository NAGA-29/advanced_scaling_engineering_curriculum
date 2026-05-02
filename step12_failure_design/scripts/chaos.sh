#!/usr/bin/env bash
# chaos.sh — カオスエンジニアリングスクリプト
#
# 各サブコマンドで障害を注入し、システムの耐障害性をテストする。
#
# 使い方:
#   bash scripts/chaos.sh <subcommand>
#
# サブコマンド:
#   redis-stop   Redis コンテナを停止
#   redis-start  Redis コンテナを起動
#   db-slow      MySQL に 500ms のネットワーク遅延を追加
#   db-stop      MySQL コンテナを停止
#   db-start     MySQL コンテナを起動
#   tc-clean     tc (Traffic Control) のルールをすべて削除
#   ec2-stop     AWS EC2 インスタンスを停止 (INSTANCE_ID 環境変数が必要)
#   status       現在のカオス状態を表示

set -euo pipefail

# ── 設定 ─────────────────────────────────────────────────────────────────────
MYSQL_CONTAINER="${MYSQL_CONTAINER:-step12-mysql}"
REDIS_CONTAINER="${REDIS_CONTAINER:-step12-redis}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
TARGET_NETWORK_IFACE="${TARGET_IFACE:-lo}" # ローカル開発では lo (loopback)
DELAY_MS="${DELAY_MS:-500}"
INSTANCE_ID="${INSTANCE_ID:-}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"

# 色付き出力
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_action() { echo -e "${YELLOW}[CHAOS]${NC} $*"; }
log_done()   { echo -e "${GREEN}[DONE]${NC}  $*"; }
log_error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_info()   { echo -e "${BLUE}[INFO]${NC}  $*"; }

# ── サブコマンド ──────────────────────────────────────────────────────────────

cmd_redis_stop() {
  log_action "Stopping Redis container: ${REDIS_CONTAINER}"
  if docker stop "${REDIS_CONTAINER}" 2>/dev/null; then
    log_done "Redis stopped. API should fallback to DB directly."
    echo "      → curl http://localhost:8080/users/1"
    echo "        X-Degraded ヘッダがない場合は DB から直接取得している"
  else
    log_error "Failed to stop Redis (is the container running?)"
    echo "       docker ps | grep redis"
    exit 1
  fi
}

cmd_redis_start() {
  log_action "Starting Redis container: ${REDIS_CONTAINER}"
  if docker start "${REDIS_CONTAINER}" 2>/dev/null; then
    log_done "Redis started."
  else
    log_error "Failed to start Redis"
    exit 1
  fi
}

cmd_db_slow() {
  log_action "Adding ${DELAY_MS}ms network delay to port ${MYSQL_PORT} on ${TARGET_NETWORK_IFACE}"

  # tc (Traffic Control) で MySQL ポートへのパケットに遅延を追加
  # 注意: これはカーネルの tc 機能を使うため root 権限が必要
  if ! command -v tc &>/dev/null; then
    log_error "'tc' command not found. Install: sudo apt-get install -y iproute2"
    exit 1
  fi

  # 既存のルールを削除してから追加
  tc qdisc del dev "${TARGET_NETWORK_IFACE}" root 2>/dev/null || true

  # netem (Network Emulator) で遅延を追加
  # すべてのトラフィックに遅延をかける (簡易版)
  sudo tc qdisc add dev "${TARGET_NETWORK_IFACE}" root netem delay "${DELAY_MS}ms" 20ms

  log_done "Network delay ${DELAY_MS}ms added on ${TARGET_NETWORK_IFACE}"
  echo "      → DB タイムアウトが発生するか確認:"
  echo "        curl -v http://localhost:8080/users/1"
  echo "        (DBTimeout=5秒なので 500ms では通るかもしれない)"
  echo ""
  echo "      → より大きな遅延を追加するには:"
  echo "        DELAY_MS=6000 bash scripts/chaos.sh db-slow"
  echo ""
  echo "      → 削除するには:"
  echo "        bash scripts/chaos.sh tc-clean"
}

cmd_db_stop() {
  log_action "Stopping MySQL container: ${MYSQL_CONTAINER}"
  if docker stop "${MYSQL_CONTAINER}" 2>/dev/null; then
    log_done "MySQL stopped."
    echo "      → Circuit Breaker の動作を確認:"
    echo "        for i in \$(seq 1 10); do"
    echo "          curl -s -o /dev/null -w '%{http_code}\\n' http://localhost:8080/users/1"
    echo "        done"
    echo "        最初の5回: エラー (Circuit CLOSED → OPEN へ)"
    echo "        その後:   fallback データ (Circuit OPEN)"
  else
    log_error "Failed to stop MySQL"
    exit 1
  fi
}

cmd_db_start() {
  log_action "Starting MySQL container: ${MYSQL_CONTAINER}"
  if docker start "${MYSQL_CONTAINER}" 2>/dev/null; then
    log_done "MySQL started. Circuit Breaker will HALF-OPEN after ${CBTimeout:-30}s."
    echo "      → 復旧確認:"
    echo "        curl http://localhost:8080/circuit-breaker/status"
    echo "        # state が HALF-OPEN → CLOSED になるまで待つ"
  else
    log_error "Failed to start MySQL"
    exit 1
  fi
}

cmd_tc_clean() {
  log_action "Removing all tc rules from ${TARGET_NETWORK_IFACE}"
  if sudo tc qdisc del dev "${TARGET_NETWORK_IFACE}" root 2>/dev/null; then
    log_done "tc rules removed. Network delay cleared."
  else
    log_info "No tc rules found (already clean)."
  fi
}

cmd_ec2_stop() {
  if [[ -z "${INSTANCE_ID}" ]]; then
    log_error "INSTANCE_ID environment variable is required"
    echo "Usage: INSTANCE_ID=i-xxxxxxxxxxxxxxxxx bash scripts/chaos.sh ec2-stop"
    exit 1
  fi

  if ! command -v aws &>/dev/null; then
    log_error "'aws' CLI not found. Install: https://aws.amazon.com/cli/"
    exit 1
  fi

  log_action "Stopping EC2 instance: ${INSTANCE_ID} (region: ${AWS_REGION})"
  aws ec2 stop-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${AWS_REGION}" \
    --output json

  log_done "Stop request sent. Instance will stop in ~30s."
  echo "      → ALB ヘルスチェックが失敗することを確認:"
  echo "        aws ec2 describe-instance-status --instance-ids ${INSTANCE_ID} --region ${AWS_REGION}"
  echo ""
  echo "      → 復旧:"
  echo "        aws ec2 start-instances --instance-ids ${INSTANCE_ID} --region ${AWS_REGION}"
}

cmd_status() {
  log_info "=== Chaos Status ==="
  echo ""

  # Docker コンテナ状態
  echo "Docker containers:"
  docker ps --format "  {{.Names}}: {{.Status}}" 2>/dev/null | \
    grep -E "${MYSQL_CONTAINER}|${REDIS_CONTAINER}" || echo "  (no matching containers)"

  echo ""

  # tc ルール
  echo "Network tc rules (${TARGET_NETWORK_IFACE}):"
  tc qdisc show dev "${TARGET_NETWORK_IFACE}" 2>/dev/null | grep -v "^qdisc noqueue" | \
    sed 's/^/  /' || echo "  (none)"

  echo ""

  # API ヘルスチェック
  echo "API health check:"
  if curl -s --max-time 3 http://localhost:8080/health 2>/dev/null; then
    echo ""
  else
    echo "  (API not responding)"
  fi

  echo ""

  # Circuit Breaker 状態
  echo "Circuit Breaker status:"
  if curl -s --max-time 3 http://localhost:8080/circuit-breaker/status 2>/dev/null; then
    echo ""
  else
    echo "  (API not responding)"
  fi
}

# ── メイン ─────────────────────────────────────────────────────────────────────

if [[ $# -eq 0 ]]; then
  echo "使い方: bash scripts/chaos.sh <subcommand>"
  echo ""
  echo "サブコマンド:"
  echo "  redis-stop   Redis を停止してキャッシュ障害を模擬"
  echo "  redis-start  Redis を起動"
  echo "  db-slow      MySQL に ${DELAY_MS}ms の遅延を追加 (tc netem)"
  echo "  db-stop      MySQL を停止して DB 障害を模擬"
  echo "  db-start     MySQL を起動"
  echo "  tc-clean     tc のネットワーク遅延ルールを削除"
  echo "  ec2-stop     EC2 インスタンスを停止 (INSTANCE_ID=i-xxxx が必要)"
  echo "  status       現在のカオス状態を表示"
  exit 0
fi

case "$1" in
  redis-stop)  cmd_redis_stop ;;
  redis-start) cmd_redis_start ;;
  db-slow)     cmd_db_slow ;;
  db-stop)     cmd_db_stop ;;
  db-start)    cmd_db_start ;;
  tc-clean)    cmd_tc_clean ;;
  ec2-stop)    cmd_ec2_stop ;;
  status)      cmd_status ;;
  *)
    log_error "Unknown subcommand: $1"
    echo "Run 'bash scripts/chaos.sh' for usage."
    exit 1
    ;;
esac
