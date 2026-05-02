#!/usr/bin/env bash
# verify_sharding.sh
# シャーディングの正確性を検証するスクリプト
#
# 確認内容:
#   1. 各シャードのレコード数
#   2. tenant_id % 2 のルーティングが正しいか（shard0=偶数, shard1=奇数）
#   3. 全件バックフィル完了を確認（source件数 = shard0 + shard1）
#   4. クロスシャード汚染チェック（間違ったシャードにデータが入っていないか）
#
# 使用方法:
#   bash scripts/verify_sharding.sh
#   bash scripts/verify_sharding.sh --source-port 3306 --shard0-port 3307 --shard1-port 3308

set -euo pipefail

# ─── Default configuration ────────────────────────────────────────────────────
SOURCE_HOST="${MYSQL_SOURCE_HOST:-127.0.0.1}"
SOURCE_PORT="${MYSQL_SOURCE_PORT:-3306}"
SHARD0_HOST="${MYSQL_SHARD0_HOST:-127.0.0.1}"
SHARD0_PORT="${MYSQL_SHARD0_PORT:-3307}"
SHARD1_HOST="${MYSQL_SHARD1_HOST:-127.0.0.1}"
SHARD1_PORT="${MYSQL_SHARD1_PORT:-3308}"
DB_NAME="${MYSQL_DB:-appdb}"
DB_USER="${MYSQL_USER:-root}"
DB_PASS="${MYSQL_PASS:-root}"

# ─── Parse CLI args ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-port) SOURCE_PORT="$2"; shift 2 ;;
    --shard0-port) SHARD0_PORT="$2"; shift 2 ;;
    --shard1-port) SHARD1_PORT="$2"; shift 2 ;;
    --db)          DB_NAME="$2";     shift 2 ;;
    --user)        DB_USER="$2";     shift 2 ;;
    --pass)        DB_PASS="$2";     shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────
divider() { echo "=============================================================="; }

mysql_query() {
  local host="$1"
  local port="$2"
  local query="$3"
  mysql -h "$host" -P "$port" -u "$DB_USER" -p"$DB_PASS" \
    --silent --skip-column-names "$DB_NAME" \
    -e "$query" 2>/dev/null || echo "ERROR"
}

mysql_table() {
  local host="$1"
  local port="$2"
  local query="$3"
  mysql -h "$host" -P "$port" -u "$DB_USER" -p"$DB_PASS" \
    "$DB_NAME" -e "$query" 2>/dev/null || echo "ERROR"
}

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo "  [WARN] $1"; }

FAILURES=0

# ─── Section 1: Connection checks ─────────────────────────────────────────────
divider
echo "1. Connection Checks"
divider

for label in "source:$SOURCE_HOST:$SOURCE_PORT" "shard0:$SHARD0_HOST:$SHARD0_PORT" "shard1:$SHARD1_HOST:$SHARD1_PORT"; do
  IFS=: read -r name host port <<< "$label"
  result=$(mysql_query "$host" "$port" "SELECT 'OK'" 2>/dev/null || echo "FAIL")
  if [[ "$result" == "OK" ]]; then
    pass "$name ($host:$port) connection OK"
  else
    fail "$name ($host:$port) connection FAILED"
  fi
done

# ─── Section 2: Row counts ────────────────────────────────────────────────────
divider
echo "2. Row Counts"
divider

SOURCE_COUNT=$(mysql_query "$SOURCE_HOST" "$SOURCE_PORT" "SELECT COUNT(*) FROM users")
SHARD0_COUNT=$(mysql_query "$SHARD0_HOST" "$SHARD0_PORT" "SELECT COUNT(*) FROM users")
SHARD1_COUNT=$(mysql_query "$SHARD1_HOST" "$SHARD1_PORT" "SELECT COUNT(*) FROM users")

echo "  Source DB   : $SOURCE_COUNT rows"
echo "  Shard 0     : $SHARD0_COUNT rows (tenant_id % 2 = 0)"
echo "  Shard 1     : $SHARD1_COUNT rows (tenant_id % 2 = 1)"

if [[ "$SOURCE_COUNT" != "ERROR" && "$SHARD0_COUNT" != "ERROR" && "$SHARD1_COUNT" != "ERROR" ]]; then
  SHARD_TOTAL=$((SHARD0_COUNT + SHARD1_COUNT))
  echo "  Shard total : $SHARD_TOTAL rows"

  if [[ "$SHARD_TOTAL" -eq "$SOURCE_COUNT" ]]; then
    pass "Total rows match: source($SOURCE_COUNT) = shard0($SHARD0_COUNT) + shard1($SHARD1_COUNT)"
  elif [[ "$SHARD_TOTAL" -gt "$SOURCE_COUNT" ]]; then
    fail "Shard total ($SHARD_TOTAL) > source ($SOURCE_COUNT): possible duplicate rows!"
  else
    warn "Backfill incomplete: $SHARD_TOTAL / $SOURCE_COUNT rows migrated ($(( SHARD_TOTAL * 100 / SOURCE_COUNT ))%)"
  fi
fi

# ─── Section 3: Routing correctness ──────────────────────────────────────────
divider
echo "3. Routing Correctness (tenant_id % 2)"
divider

# Shard 0 should contain ONLY even tenant_ids
SHARD0_ODD=$(mysql_query "$SHARD0_HOST" "$SHARD0_PORT" \
  "SELECT COUNT(*) FROM users WHERE tenant_id % 2 != 0")
if [[ "$SHARD0_ODD" == "0" ]]; then
  pass "Shard 0: all rows have even tenant_id (no contamination)"
else
  fail "Shard 0: $SHARD0_ODD rows with odd tenant_id (should be on shard 1!)"
fi

# Shard 1 should contain ONLY odd tenant_ids
SHARD1_EVEN=$(mysql_query "$SHARD1_HOST" "$SHARD1_PORT" \
  "SELECT COUNT(*) FROM users WHERE tenant_id % 2 != 1")
if [[ "$SHARD1_EVEN" == "0" ]]; then
  pass "Shard 1: all rows have odd tenant_id (no contamination)"
else
  fail "Shard 1: $SHARD1_EVEN rows with even tenant_id (should be on shard 0!)"
fi

# ─── Section 4: Specific tenant routing verification ─────────────────────────
divider
echo "4. Per-Tenant Routing Spot Check"
divider

echo "  Checking first 10 tenant_ids..."
mysql_table "$SOURCE_HOST" "$SOURCE_PORT" "
  SELECT tenant_id,
         COUNT(*) as user_count,
         IF(tenant_id % 2 = 0, 'shard0', 'shard1') AS expected_shard
  FROM users
  GROUP BY tenant_id
  ORDER BY tenant_id
  LIMIT 10
"

# Verify tenant_id=1 (odd -> shard1 only)
T1_S0=$(mysql_query "$SHARD0_HOST" "$SHARD0_PORT" "SELECT COUNT(*) FROM users WHERE tenant_id=1")
T1_S1=$(mysql_query "$SHARD1_HOST" "$SHARD1_PORT" "SELECT COUNT(*) FROM users WHERE tenant_id=1")
echo ""
echo "  tenant_id=1 (odd): shard0=$T1_S0 rows (expected 0), shard1=$T1_S1 rows (expected >0)"
if [[ "$T1_S0" == "0" && "$T1_S1" -gt 0 ]]; then
  pass "tenant_id=1 correctly routed to shard1 only"
else
  fail "tenant_id=1 routing incorrect: shard0=$T1_S0, shard1=$T1_S1"
fi

# Verify tenant_id=2 (even -> shard0 only)
T2_S0=$(mysql_query "$SHARD0_HOST" "$SHARD0_PORT" "SELECT COUNT(*) FROM users WHERE tenant_id=2")
T2_S1=$(mysql_query "$SHARD1_HOST" "$SHARD1_PORT" "SELECT COUNT(*) FROM users WHERE tenant_id=2")
echo "  tenant_id=2 (even): shard0=$T2_S0 rows (expected >0), shard1=$T2_S1 rows (expected 0)"
if [[ "$T2_S0" -gt 0 && "$T2_S1" == "0" ]]; then
  pass "tenant_id=2 correctly routed to shard0 only"
else
  fail "tenant_id=2 routing incorrect: shard0=$T2_S0, shard1=$T2_S1"
fi

# ─── Section 5: Distribution balance ─────────────────────────────────────────
divider
echo "5. Distribution Balance"
divider

if [[ "$SHARD0_COUNT" != "ERROR" && "$SHARD1_COUNT" != "ERROR" && "$SHARD0_COUNT" -gt 0 && "$SHARD1_COUNT" -gt 0 ]]; then
  SHARD_TOTAL=$((SHARD0_COUNT + SHARD1_COUNT))
  S0_PCT=$(awk "BEGIN { printf \"%.1f\", ($SHARD0_COUNT / $SHARD_TOTAL) * 100 }")
  S1_PCT=$(awk "BEGIN { printf \"%.1f\", ($SHARD1_COUNT / $SHARD_TOTAL) * 100 }")
  echo "  Shard 0: $SHARD0_COUNT rows ($S0_PCT%)"
  echo "  Shard 1: $SHARD1_COUNT rows ($S1_PCT%)"

  # Warn if distribution is more than 20% off from 50/50
  DIFF=$(awk "BEGIN { diff = $SHARD0_COUNT - $SHARD1_COUNT; if(diff<0)diff=-diff; print diff }")
  DIFF_PCT=$(awk "BEGIN { printf \"%.1f\", ($DIFF / $SHARD_TOTAL) * 100 }")
  if awk "BEGIN { exit ($DIFF / $SHARD_TOTAL > 0.20) }"; then
    pass "Distribution balanced: shard0=$S0_PCT% shard1=$S1_PCT%"
  else
    warn "Distribution skewed: shard0=$S0_PCT% shard1=$S1_PCT% (${DIFF_PCT}% difference)"
    echo "    This is expected if tenant_ids are not uniformly distributed."
  fi
fi

# ─── Section 6: Migration progress ───────────────────────────────────────────
divider
echo "6. Migration Progress"
divider

for label in "shard0:$SHARD0_HOST:$SHARD0_PORT" "shard1:$SHARD1_HOST:$SHARD1_PORT"; do
  IFS=: read -r name host port <<< "$label"
  echo "  $name migration_progress:"
  mysql_table "$host" "$port" "SELECT * FROM migration_progress LIMIT 5" 2>/dev/null \
    || echo "    (migration_progress table not found)"
  echo ""
done

# ─── Summary ──────────────────────────────────────────────────────────────────
divider
echo "Verification Summary"
divider
echo ""
echo "  Source DB : $SOURCE_COUNT rows"
echo "  Shard 0   : $SHARD0_COUNT rows"
echo "  Shard 1   : $SHARD1_COUNT rows"
echo ""

if [[ "$FAILURES" -eq 0 ]]; then
  echo "  RESULT: ALL CHECKS PASSED"
else
  echo "  RESULT: $FAILURES CHECK(S) FAILED"
  exit 1
fi
divider
