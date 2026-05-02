#!/usr/bin/env bash
# check_mysql.sh
# Verifies MySQL connectivity and prints row counts for every table in the
# `scaling` database.
#
# Usage:
#   ./check_mysql.sh
#   MYSQL_HOST=10.0.0.5 MYSQL_USER=app MYSQL_PASS=secret ./check_mysql.sh
#
# Environment variables (all optional, sensible defaults provided):
#   MYSQL_HOST      – hostname or IP (default: 127.0.0.1)
#   MYSQL_PORT      – TCP port       (default: 3306)
#   MYSQL_USER      – username       (default: root)
#   MYSQL_PASS      – password       (default: secret)
#   MYSQL_DATABASE  – database name  (default: scaling)

set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASS="${MYSQL_PASS:-secret}"
MYSQL_DATABASE="${MYSQL_DATABASE:-scaling}"

# Build a reusable mysql invocation without exposing the password on the
# process list (use a temporary options file instead).
TMPFILE="$(mktemp /tmp/my_cnf.XXXXXX)"
trap 'rm -f "$TMPFILE"' EXIT

cat > "$TMPFILE" <<EOF
[client]
host     = ${MYSQL_HOST}
port     = ${MYSQL_PORT}
user     = ${MYSQL_USER}
password = ${MYSQL_PASS}
EOF

mysql_cmd() {
    mysql --defaults-extra-file="$TMPFILE" --batch --silent "$@"
}

echo "============================================================"
echo " MySQL Connectivity Check"
echo " Host     : ${MYSQL_HOST}:${MYSQL_PORT}"
echo " Database : ${MYSQL_DATABASE}"
echo "============================================================"

# ── 1. Ping ──────────────────────────────────────────────────────────────────
echo ""
echo "[1/4] Testing connection..."
if mysql_cmd -e "SELECT 1;" > /dev/null 2>&1; then
    echo "      OK – connected successfully."
else
    echo "      FAILED – could not connect to MySQL."
    echo "      Check MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASS."
    exit 1
fi

# ── 2. Server version ────────────────────────────────────────────────────────
echo ""
echo "[2/4] Server version:"
mysql_cmd -e "SELECT VERSION() AS version;" | awk '{print "      " $0}'

# ── 3. Database exists ───────────────────────────────────────────────────────
echo ""
echo "[3/4] Checking database '${MYSQL_DATABASE}'..."
DB_EXISTS=$(mysql_cmd -e \
    "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${MYSQL_DATABASE}';" 2>/dev/null || true)

if [[ -z "$DB_EXISTS" ]]; then
    echo "      WARNING – database '${MYSQL_DATABASE}' does not exist."
    echo "      Run: mysql < shared/sql/schema.sql"
    exit 1
else
    echo "      OK – database exists."
fi

# ── 4. Table row counts ──────────────────────────────────────────────────────
echo ""
echo "[4/4] Table row counts in '${MYSQL_DATABASE}':"
echo ""

TABLES=("users" "devices" "heartbeats" "migration_progress")
TOTAL_ROWS=0

printf "      %-25s %s\n" "TABLE" "ROW COUNT"
printf "      %-25s %s\n" "-------------------------" "---------"

for TABLE in "${TABLES[@]}"; do
    COUNT=$(mysql_cmd "${MYSQL_DATABASE}" \
        -e "SELECT COUNT(*) FROM \`${TABLE}\`;" 2>/dev/null || echo "N/A")
    printf "      %-25s %s\n" "${TABLE}" "${COUNT}"
    if [[ "$COUNT" =~ ^[0-9]+$ ]]; then
        TOTAL_ROWS=$(( TOTAL_ROWS + COUNT ))
    fi
done

echo ""
printf "      %-25s %s\n" "TOTAL" "${TOTAL_ROWS}"

# ── 5. Additional diagnostics ────────────────────────────────────────────────
echo ""
echo "------------------------------------------------------------"
echo " Server status"
echo "------------------------------------------------------------"
mysql_cmd -e "SHOW STATUS LIKE 'Threads_connected';" | \
    awk '{printf "  %-30s %s\n", $1, $2}'
mysql_cmd -e "SHOW STATUS LIKE 'Uptime';" | \
    awk '{printf "  %-30s %s seconds\n", $1, $2}'
mysql_cmd -e "SHOW STATUS LIKE 'Questions';" | \
    awk '{printf "  %-30s %s\n", $1, $2}'

echo ""
echo "============================================================"
echo " All checks passed."
echo "============================================================"
