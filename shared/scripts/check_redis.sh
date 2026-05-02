#!/usr/bin/env bash
# check_redis.sh
# Verifies Redis connectivity and prints memory and server info.
#
# Usage:
#   ./check_redis.sh
#   REDIS_HOST=10.0.0.6 REDIS_PORT=6379 ./check_redis.sh
#
# Environment variables (all optional, sensible defaults provided):
#   REDIS_HOST  – hostname or IP (default: 127.0.0.1)
#   REDIS_PORT  – TCP port       (default: 6379)
#   REDIS_PASS  – password / AUTH string (default: empty = no auth)
#   REDIS_DB    – database index to select (default: 0)

set -euo pipefail

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASS="${REDIS_PASS:-}"
REDIS_DB="${REDIS_DB:-0}"

# Build a reusable redis-cli invocation.
redis_cli_args=(-h "$REDIS_HOST" -p "$REDIS_PORT" -n "$REDIS_DB")
if [[ -n "$REDIS_PASS" ]]; then
    redis_cli_args+=(-a "$REDIS_PASS")
fi

redis_cmd() {
    redis-cli "${redis_cli_args[@]}" "$@" 2>/dev/null
}

# Suppress the "Warning: Using a password with '-a' is insecure" message that
# some versions of redis-cli print to stderr.
export REDISCLI_AUTH="$REDIS_PASS"

echo "============================================================"
echo " Redis Connectivity Check"
echo " Host : ${REDIS_HOST}:${REDIS_PORT}"
echo " DB   : ${REDIS_DB}"
echo "============================================================"

# ── 1. Ping ──────────────────────────────────────────────────────────────────
echo ""
echo "[1/5] Testing connection (PING)..."
PONG=$(redis_cmd PING 2>&1 || true)
if [[ "$PONG" == "PONG" ]]; then
    echo "      OK – Redis responded with PONG."
else
    echo "      FAILED – unexpected response: '${PONG}'"
    echo "      Check REDIS_HOST, REDIS_PORT, and REDIS_PASS."
    exit 1
fi

# ── 2. Server version ────────────────────────────────────────────────────────
echo ""
echo "[2/5] Redis server version:"
redis_cmd INFO server | grep "^redis_version" | \
    awk -F: '{print "      redis_version: " $2}' | tr -d '\r'

# ── 3. Memory info ───────────────────────────────────────────────────────────
echo ""
echo "[3/5] Memory usage:"
MEM_FIELDS=(
    "used_memory_human"
    "used_memory_peak_human"
    "used_memory_rss_human"
    "mem_fragmentation_ratio"
    "maxmemory_human"
    "maxmemory_policy"
)

for FIELD in "${MEM_FIELDS[@]}"; do
    VALUE=$(redis_cmd INFO memory | grep "^${FIELD}:" | awk -F: '{print $2}' | tr -d '\r' || echo "N/A")
    printf "      %-30s %s\n" "${FIELD}:" "${VALUE}"
done

# ── 4. Key count in selected DB ──────────────────────────────────────────────
echo ""
echo "[4/5] Key count in DB ${REDIS_DB}:"
DBSIZE=$(redis_cmd DBSIZE 2>/dev/null || echo "N/A")
printf "      %-30s %s\n" "DBSIZE:" "${DBSIZE}"

# Also list all databases and their key counts from the keyspace section.
echo ""
echo "      Keyspace (all databases):"
KEYSPACE=$(redis_cmd INFO keyspace 2>/dev/null | grep -v "^#" | grep -v "^$" | tr -d '\r' || true)
if [[ -z "$KEYSPACE" ]]; then
    echo "      (empty – no keys in any database)"
else
    echo "$KEYSPACE" | while IFS= read -r line; do
        echo "        ${line}"
    done
fi

# ── 5. Connection and persistence stats ──────────────────────────────────────
echo ""
echo "[5/5] Connection & persistence stats:"
STAT_FIELDS=(
    "connected_clients"
    "blocked_clients"
    "uptime_in_seconds"
    "total_commands_processed"
    "total_connections_received"
    "rdb_last_bgsave_status"
    "aof_enabled"
)

for FIELD in "${STAT_FIELDS[@]}"; do
    # Fields may be in different INFO sections; search across all.
    VALUE=$(redis_cmd INFO all | grep "^${FIELD}:" | awk -F: '{print $2}' | tr -d '\r' || echo "N/A")
    printf "      %-35s %s\n" "${FIELD}:" "${VALUE}"
done

echo ""
echo "============================================================"
echo " All checks passed."
echo "============================================================"
