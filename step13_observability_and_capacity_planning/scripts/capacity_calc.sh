#!/usr/bin/env bash
# capacity_calc.sh — キャパシティプランニング計算スクリプト
#
# デバイス台数・ハートビート間隔・ピーク倍率からリソース必要量を計算する。
#
# 使い方:
#   bash scripts/capacity_calc.sh
#   bash scripts/capacity_calc.sh --devices 10000 --interval-sec 30 --peak-multiplier 5
#
# 引数:
#   --devices          デバイス台数 (default: 5000)
#   --interval-sec     heartbeat 間隔秒 (default: 60)
#   --peak-multiplier  ピーク倍率 (default: 3)
#   --cache-hit-rate   キャッシュヒット率 0-100 (default: 80)
#   --db-query-ms      DBクエリ平均時間ms (default: 10)
#   --api-servers      APIサーバー台数 (default: 1)

set -euo pipefail

# ── デフォルト値 ──────────────────────────────────────────────────────────────
DEVICES=5000
INTERVAL_SEC=60
PEAK_MULTIPLIER=3
CACHE_HIT_RATE=80       # %
DB_QUERY_MS=10          # ミリ秒
API_SERVERS=1

# ── 引数解析 ──────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --devices)          DEVICES="$2";          shift 2 ;;
    --interval-sec)     INTERVAL_SEC="$2";     shift 2 ;;
    --peak-multiplier)  PEAK_MULTIPLIER="$2";  shift 2 ;;
    --cache-hit-rate)   CACHE_HIT_RATE="$2";   shift 2 ;;
    --db-query-ms)      DB_QUERY_MS="$2";      shift 2 ;;
    --api-servers)      API_SERVERS="$2";      shift 2 ;;
    *) shift ;;
  esac
done

# ── 計算 (bc または awk を使用) ───────────────────────────────────────────────

# awk で浮動小数点計算
calc() {
  awk "BEGIN { printf \"%.2f\", $1 }"
}

calc_int() {
  awk "BEGIN { printf \"%d\", int($1 + 0.999) }"
}

# 定常 req/s
STEADY_RPS=$(calc "${DEVICES} / ${INTERVAL_SEC}")

# ピーク req/s
PEAK_RPS=$(calc "${STEADY_RPS} * ${PEAK_MULTIPLIER}")

# キャッシュミス率
CACHE_MISS_RATE=$(calc "(100 - ${CACHE_HIT_RATE}) / 100")

# DB へのリクエスト数 (ヒット率を差し引く)
DB_STEADY_RPS=$(calc "${STEADY_RPS} * ${CACHE_MISS_RATE}")
DB_PEAK_RPS=$(calc "${PEAK_RPS} * ${CACHE_MISS_RATE}")

# 同時 DB 接続数 = req/s × DBクエリ時間(s) (リトルの法則)
DB_QUERY_SEC=$(calc "${DB_QUERY_MS} / 1000")
DB_CONCURRENT_STEADY=$(calc "${DB_STEADY_RPS} * ${DB_QUERY_SEC}")
DB_CONCURRENT_PEAK=$(calc "${DB_PEAK_RPS} * ${DB_QUERY_SEC}")

# DB 接続プール推奨サイズ (ピーク × 安全マージン 10 倍)
DB_POOL_SIZE=$(calc_int "${DB_CONCURRENT_PEAK} * 10")
if [[ "${DB_POOL_SIZE}" -lt 10 ]]; then
  DB_POOL_SIZE=10  # 最低 10
fi

# API サーバー 1台あたりの req/s
RPS_PER_SERVER=$(calc "${PEAK_RPS} / ${API_SERVERS}")

# CPU 見積もり (1コアで ~500 req/s の軽い処理として)
CORES_NEEDED=$(calc_int "${PEAK_RPS} / 500")
if [[ "${CORES_NEEDED}" -lt 1 ]]; then
  CORES_NEEDED=1
fi

# Redis メモリ見積もり (1エントリ 100 bytes として)
# キャッシュするデバイス数 × TTL内の一意デバイス数 (全デバイスが TTL 期間内にアクセス)
REDIS_ENTRIES="${DEVICES}"
REDIS_MEMORY_MB=$(calc_int "${REDIS_ENTRIES} * 100 / 1024 / 1024 + 1")

# ── 出力 ──────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║             キャパシティプランニング計算結果                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "【入力パラメータ】"
printf "  %-25s : %s 台\n"        "デバイス台数"         "${DEVICES}"
printf "  %-25s : %s 秒\n"        "heartbeat 間隔"       "${INTERVAL_SEC}"
printf "  %-25s : %s 倍\n"        "ピーク倍率"           "${PEAK_MULTIPLIER}"
printf "  %-25s : %s %%\n"        "キャッシュヒット率"    "${CACHE_HIT_RATE}"
printf "  %-25s : %s ms\n"        "DB クエリ時間"        "${DB_QUERY_MS}"
printf "  %-25s : %s 台\n"        "API サーバー台数"     "${API_SERVERS}"
echo ""
echo "【リクエスト数の計算】"
echo "┌──────────────────────────────────────────────────────────────┐"
printf "│  %-30s : %10s req/s │\n" "定常 req/s"                       "${STEADY_RPS}"
printf "│  %-30s : %10s req/s │\n" "ピーク req/s (×${PEAK_MULTIPLIER})" "${PEAK_RPS}"
printf "│  %-30s : %10s req/s │\n" "DB req/s (定常, ヒット率考慮)"    "${DB_STEADY_RPS}"
printf "│  %-30s : %10s req/s │\n" "DB req/s (ピーク, ヒット率考慮)"  "${DB_PEAK_RPS}"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""
echo "【必要リソース見積もり】"
echo "┌──────────────────────────────────────────────────────────────┐"
printf "│  %-35s : %7s 接続  │\n" "DB 同時接続 (定常)"                 "${DB_CONCURRENT_STEADY}"
printf "│  %-35s : %7s 接続  │\n" "DB 同時接続 (ピーク)"               "${DB_CONCURRENT_PEAK}"
printf "│  %-35s : %7s        │\n" "推奨 DB 接続プールサイズ"           "${DB_POOL_SIZE}"
printf "│  %-35s : %7s req/s  │\n" "API 1台あたりの req/s (ピーク)"    "${RPS_PER_SERVER}"
printf "│  %-35s : %7s コア   │\n" "API に必要な CPU コア数 (概算)"     "${CORES_NEEDED}"
printf "│  %-35s : %7s MB     │\n" "Redis 必要メモリ (概算)"            "${REDIS_MEMORY_MB}"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""
echo "【スケーリング判断の目安】"

# ピーク req/s に基づく推奨 API サーバー台数
RECOMMENDED_SERVERS=$(calc_int "${PEAK_RPS} / 500")
if [[ "${RECOMMENDED_SERVERS}" -lt 1 ]]; then
  RECOMMENDED_SERVERS=1
fi

printf "  %-40s : %s 台\n" "推奨 API サーバー台数 (500 req/s/台)"  "${RECOMMENDED_SERVERS}"

echo ""
echo "【計算式の説明】"
echo "  定常 req/s     = ${DEVICES} デバイス ÷ ${INTERVAL_SEC} 秒 = ${STEADY_RPS} req/s"
echo "  ピーク req/s   = ${STEADY_RPS} × ${PEAK_MULTIPLIER} (起動集中) = ${PEAK_RPS} req/s"
echo "  DB req/s       = ピーク × (1 - ヒット率) = ${PEAK_RPS} × ${CACHE_MISS_RATE} = ${DB_PEAK_RPS}"
echo "  DB 同時接続    = DB req/s × クエリ時間[s] (リトルの法則)"
echo "                 = ${DB_PEAK_RPS} × ${DB_QUERY_SEC} = ${DB_CONCURRENT_PEAK}"
echo "  DB プールサイズ = 同時接続 × 10 (安全マージン) = ${DB_POOL_SIZE}"
echo ""
