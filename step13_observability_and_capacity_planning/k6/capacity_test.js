/**
 * STEP 13: キャパシティテスト — 5000台デバイスの heartbeat シミュレーション
 *
 * 5000台のデバイスが 60秒に1回 heartbeat を送るパターンをシミュレートする。
 * 定常状態: 5000 / 60 = 83.3 req/s
 *
 * さらに日次パターン (夜間低負荷・ビジネスアワーピーク) もシミュレートする:
 *   - 夜間 (0:00-6:00):  デバイスの 10% がアクティブ → 8.3 req/s
 *   - 朝の起動ピーク:    デバイスの 300% が集中 → 250 req/s (起動集中)
 *   - ビジネスアワー:    デバイスの 100% → 83.3 req/s
 *   - 夕方:              デバイスの 50% → 41.7 req/s
 *
 * 実行方法:
 *   k6 run k6/capacity_test.js
 *
 * 環境変数:
 *   API_URL     (default: http://localhost:8080)
 *   DEVICES     (default: 5000)
 *   INTERVAL    (default: 60)
 */

import http from "k6/http";
import { check, sleep, group } from "k6";
import { Trend, Rate, Counter, Gauge } from "k6/metrics";

// ── カスタムメトリクス ────────────────────────────────────────────────────────
const heartbeatLatency = new Trend("heartbeat_latency", true);
const cacheHitRate = new Gauge("cache_hit_rate_gauge"); // X-Cache: HIT の割合
const errorRate = new Rate("heartbeat_error_rate");
const heartbeatCount = new Counter("heartbeat_total");
const cacheHits = new Counter("cache_hit_total");
const cacheMisses = new Counter("cache_miss_total");

// ── テスト設定 ───────────────────────────────────────────────────────────────
// 5000台 / 60秒 = 83.3 req/s
// k6 の VU 数で近似する
// - 1 VU = sleep(0.06) = 約 16.7 req/s
// - 83.3 / 16.7 ≈ 5 VU で 83.3 req/s を近似
// - ただし実際の heartbeat は分散するので ramping で調整

const DEVICES = parseInt(__ENV.DEVICES || "5000");
const INTERVAL_SEC = parseInt(__ENV.INTERVAL || "60");
const STEADY_RPS = DEVICES / INTERVAL_SEC; // 83.3

// k6 の VU 数でスループットを制御
// VU あたりのスリープ時間を調整
// sleep = VU / target_rps

export const options = {
  scenarios: {
    // シナリオ1: 定常状態 (ビジネスアワー模倣)
    steady_state: {
      executor: "ramping-vus",
      stages: [
        // 夜間: 10% のデバイスがアクティブ
        { duration: "30s", target: Math.ceil(STEADY_RPS * 0.1) },
        // 朝の起動ピーク: 一時的に 3x
        { duration: "30s", target: Math.ceil(STEADY_RPS * 3) },
        // ビジネスアワー: 定常
        { duration: "60s", target: Math.ceil(STEADY_RPS) },
        // 夕方: 半減
        { duration: "30s", target: Math.ceil(STEADY_RPS * 0.5) },
        // クールダウン
        { duration: "10s", target: 0 },
      ],
      gracefulRampDown: "10s",
    },
  },
  thresholds: {
    // 定常状態でのレイテンシ目標
    heartbeat_latency: [
      "p(50)<20",   // p50 < 20ms
      "p(95)<50",   // p95 < 50ms
      "p(99)<100",  // p99 < 100ms
    ],
    heartbeat_error_rate: ["rate<0.001"], // 0.1% 未満
  },
};

const API_URL = __ENV.API_URL || "http://localhost:8080";

// デバイス ID のセット (実際の5000台を模倣)
// VU 番号からデバイス ID を生成
function getDeviceID(vu) {
  return `device-${String(vu % DEVICES + 1).padStart(5, "0")}`;
}

// ── メイン実行関数 ────────────────────────────────────────────────────────────
export default function () {
  const deviceID = getDeviceID(__VU);

  group("heartbeat", function () {
    const res = http.get(
      `${API_URL}/heartbeat?device_id=${deviceID}`,
      {
        headers: {
          "X-Request-ID": `k6-vu${__VU}-iter${__ITER}`,
          "X-Device-ID": deviceID,
        },
        timeout: "5s",
      }
    );

    const isHit = res.headers["X-Cache"] === "HIT";
    const ok = check(res, {
      "status 200": (r) => r.status === 200,
      "has status field": (r) => {
        try {
          return JSON.parse(r.body).status === "ok";
        } catch {
          return false;
        }
      },
    });

    heartbeatLatency.add(res.timings.duration);
    errorRate.add(!ok);
    heartbeatCount.add(1);

    if (isHit) {
      cacheHits.add(1);
    } else {
      cacheMisses.add(1);
    }

    // キャッシュヒット率をゲージで追跡 (直近の状態)
    const totalSoFar =
      (cacheHits.values?.count ?? 0) + (cacheMisses.values?.count ?? 0);
    if (totalSoFar > 0) {
      cacheHitRate.add(((cacheHits.values?.count ?? 0) / totalSoFar) * 100);
    }
  });

  // 各デバイスは 60秒に1回 heartbeat を送る
  // k6 の VU は継続的にループするため、sleep で間隔を再現
  // sleep(60) では k6 のテスト時間が短すぎるので、スケールダウン
  // テスト用に 60ms sleep (実際の 60秒を 1000 倍速でシミュレート)
  sleep(0.06);
}

// ── セットアップ ──────────────────────────────────────────────────────────────
export function setup() {
  const res = http.get(`${API_URL}/health`);
  if (res.status !== 200) {
    throw new Error(`API health check failed: status ${res.status}`);
  }

  console.log("=== Capacity Test Configuration ===");
  console.log(`  Devices:     ${DEVICES}`);
  console.log(`  Interval:    ${INTERVAL_SEC}s`);
  console.log(`  Steady RPS:  ${STEADY_RPS.toFixed(1)} req/s`);
  console.log(`  Peak RPS:    ${(STEADY_RPS * 3).toFixed(1)} req/s (3x)`);
  console.log("===================================");
}

// ── サマリ ────────────────────────────────────────────────────────────────────
export function handleSummary(data) {
  const p50 = data.metrics.heartbeat_latency?.values?.["p(50)"]?.toFixed(2) ?? "N/A";
  const p95 = data.metrics.heartbeat_latency?.values?.["p(95)"]?.toFixed(2) ?? "N/A";
  const p99 = data.metrics.heartbeat_latency?.values?.["p(99)"]?.toFixed(2) ?? "N/A";
  const total = data.metrics.heartbeat_total?.values?.count ?? 0;
  const errRate = ((data.metrics.heartbeat_error_rate?.values?.rate ?? 0) * 100).toFixed(3);
  const rps = data.metrics.http_reqs?.values?.rate?.toFixed(1) ?? "N/A";

  const summary = `
========================================
  キャパシティテスト結果
  (${DEVICES}台デバイス, ${INTERVAL_SEC}s間隔)
========================================
  Total Heartbeats:    ${total}
  Actual RPS:          ${rps} req/s
  Target Steady RPS:   ${STEADY_RPS.toFixed(1)} req/s
  Error Rate:          ${errRate}%

  Latency (heartbeat_latency):
    p50:  ${p50} ms   (目標: < 20ms)
    p95:  ${p95} ms   (目標: < 50ms)
    p99:  ${p99} ms   (目標: < 100ms)

  Pass/Fail:
    p50 < 20ms:   ${parseFloat(p50) < 20 ? "PASS" : "FAIL"}
    p95 < 50ms:   ${parseFloat(p95) < 50 ? "PASS" : "FAIL"}
    p99 < 100ms:  ${parseFloat(p99) < 100 ? "PASS" : "FAIL"}
    err < 0.1%:   ${parseFloat(errRate) < 0.1 ? "PASS" : "FAIL"}
========================================
`;

  console.log(summary);
  return { stdout: summary };
}
