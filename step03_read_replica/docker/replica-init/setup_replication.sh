#!/bin/bash
# =============================================================
# レプリケーション初期化スクリプト
# docker-compose の mysql-replica-init コンテナで実行される
# Primary と Replica 両方が起動してから 1 回だけ実行する
# =============================================================

set -euo pipefail

PRIMARY_HOST="${PRIMARY_HOST:-mysql-primary}"
PRIMARY_PORT="${PRIMARY_PORT:-3306}"
REPLICA_HOST="${REPLICA_HOST:-mysql-replica}"
REPLICA_PORT="${REPLICA_PORT:-3306}"
ROOT_PASS="${MYSQL_ROOT_PASSWORD:-rootpassword}"
REPL_USER="${REPL_USER:-replicator}"
REPL_PASS="${REPL_PASS:-replicator_pass}"

echo "=== Replication Setup Script ==="
echo "Primary: ${PRIMARY_HOST}:${PRIMARY_PORT}"
echo "Replica: ${REPLICA_HOST}:${REPLICA_PORT}"

# -------------------------------------------------------
# 1. Primary が応答するまで待機
# -------------------------------------------------------
echo "Waiting for primary to accept connections..."
for i in $(seq 1 60); do
  if mysql -h"${PRIMARY_HOST}" -P"${PRIMARY_PORT}" -uroot -p"${ROOT_PASS}" \
     -e "SELECT 1" &>/dev/null 2>&1; then
    echo "Primary is ready (attempt ${i})"
    break
  fi
  if [ "${i}" -eq 60 ]; then
    echo "ERROR: Primary did not become ready within 60 attempts"
    exit 1
  fi
  sleep 2
done

# -------------------------------------------------------
# 2. Replica が応答するまで待機
# -------------------------------------------------------
echo "Waiting for replica to accept connections..."
for i in $(seq 1 60); do
  if mysql -h"${REPLICA_HOST}" -P"${REPLICA_PORT}" -uroot -p"${ROOT_PASS}" \
     -e "SELECT 1" &>/dev/null 2>&1; then
    echo "Replica is ready (attempt ${i})"
    break
  fi
  if [ "${i}" -eq 60 ]; then
    echo "ERROR: Replica did not become ready within 60 attempts"
    exit 1
  fi
  sleep 2
done

# -------------------------------------------------------
# 3. すでにレプリケーションが設定されているか確認
# -------------------------------------------------------
REPLICA_STATUS=$(mysql -h"${REPLICA_HOST}" -P"${REPLICA_PORT}" -uroot -p"${ROOT_PASS}" \
  -e "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Replica_IO_Running" | awk '{print $2}' || echo "")

if [ "${REPLICA_STATUS}" = "Yes" ]; then
  echo "Replication already configured and running. Skipping setup."
  mysql -h"${REPLICA_HOST}" -P"${REPLICA_PORT}" -uroot -p"${ROOT_PASS}" \
    -e "SHOW REPLICA STATUS\G" | grep -E "Running|Seconds_Behind|Error"
  exit 0
fi

# -------------------------------------------------------
# 4. Primary のバイナリログ位置を取得
# -------------------------------------------------------
echo "Getting primary binary log position..."
BINLOG_INFO=$(mysql -h"${PRIMARY_HOST}" -P"${PRIMARY_PORT}" -uroot -p"${ROOT_PASS}" \
  -e "SHOW MASTER STATUS\G" 2>/dev/null)

BINLOG_FILE=$(echo "${BINLOG_INFO}" | grep "File:" | awk '{print $2}')
BINLOG_POS=$(echo "${BINLOG_INFO}" | grep "Position:" | awk '{print $2}')

echo "Primary status: file=${BINLOG_FILE}, position=${BINLOG_POS}"

if [ -z "${BINLOG_FILE}" ] || [ -z "${BINLOG_POS}" ]; then
  echo "ERROR: Could not get primary binary log position"
  echo "Primary status output:"
  echo "${BINLOG_INFO}"
  exit 1
fi

# -------------------------------------------------------
# 5. Replica のレプリケーション設定
# -------------------------------------------------------
echo "Configuring replication on replica..."

mysql -h"${REPLICA_HOST}" -P"${REPLICA_PORT}" -uroot -p"${ROOT_PASS}" << SQL
STOP REPLICA;

CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${PRIMARY_HOST}',
  SOURCE_PORT=${PRIMARY_PORT},
  SOURCE_USER='${REPL_USER}',
  SOURCE_PASSWORD='${REPL_PASS}',
  SOURCE_LOG_FILE='${BINLOG_FILE}',
  SOURCE_LOG_POS=${BINLOG_POS},
  GET_SOURCE_PUBLIC_KEY=1;

START REPLICA;
SQL

echo "Replication started. Checking status..."

# -------------------------------------------------------
# 6. レプリケーション状態の確認
# -------------------------------------------------------
sleep 3

mysql -h"${REPLICA_HOST}" -P"${REPLICA_PORT}" -uroot -p"${ROOT_PASS}" \
  -e "SHOW REPLICA STATUS\G" | grep -E "Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_Error"

# IO Thread と SQL Thread が両方 Yes であることを確認
IO_RUNNING=$(mysql -h"${REPLICA_HOST}" -P"${REPLICA_PORT}" -uroot -p"${ROOT_PASS}" \
  -e "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Replica_IO_Running" | awk '{print $2}')
SQL_RUNNING=$(mysql -h"${REPLICA_HOST}" -P"${REPLICA_PORT}" -uroot -p"${ROOT_PASS}" \
  -e "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Replica_SQL_Running:" | awk '{print $2}')

if [ "${IO_RUNNING}" = "Yes" ] && [ "${SQL_RUNNING}" = "Yes" ]; then
  echo "=== Replication setup SUCCESSFUL ==="
  echo "IO Thread: ${IO_RUNNING}"
  echo "SQL Thread: ${SQL_RUNNING}"
else
  echo "=== WARNING: Replication may not be running correctly ==="
  echo "IO Thread: ${IO_RUNNING}"
  echo "SQL Thread: ${SQL_RUNNING}"
  exit 1
fi

# -------------------------------------------------------
# 7. データ同期確認
# -------------------------------------------------------
echo "Verifying data sync..."
sleep 2

PRIMARY_COUNT=$(mysql -h"${PRIMARY_HOST}" -P"${PRIMARY_PORT}" -uroot -p"${ROOT_PASS}" \
  appdb -e "SELECT COUNT(*) AS cnt FROM users;" 2>/dev/null | grep -v cnt || echo "0")
REPLICA_COUNT=$(mysql -h"${REPLICA_HOST}" -P"${REPLICA_PORT}" -uroot -p"${ROOT_PASS}" \
  appdb -e "SELECT COUNT(*) AS cnt FROM users;" 2>/dev/null | grep -v cnt || echo "0")

echo "Primary users count: ${PRIMARY_COUNT}"
echo "Replica  users count: ${REPLICA_COUNT}"

echo "=== Setup complete ==="
