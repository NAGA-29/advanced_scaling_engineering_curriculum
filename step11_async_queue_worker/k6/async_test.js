/**
 * STEP 11: 非同期 API 負荷テスト
 *
 * POST /events に負荷をかけて、202 Accepted が高速に返ることを確認する。
 * 同期 DB 書き込みの場合と比較して、p99 が大幅に改善されることを検証。
 *
 * 実行方法:
 *   k6 run k6/async_test.js
 *
 * 環境変数:
 *   API_URL     (default: http://localhost:8080)
 *   VU_COUNT    (default: 100)
 */

import http from "k6/http";
import { check, sleep, group } from "k6";
import { Trend, Rate, Counter, Gauge } from "k6/metrics";

// ── カスタムメトリクス ────────────────────────────────────────────────────────
const eventAcceptLatency = new Trend("event_accept_latency", true); // 202 Accepted までの時間
const eventErrorRate = new Rate("event_error_rate");
const acceptedEvents = new Counter("accepted_events"); // 202 を受けたイベント数
const rejectedEvents = new Counter("rejected_events"); // 4xx/5xx を受けた数

// ── テスト設定 ───────────────────────────────────────────────────────────────
export const options = {
  stages: [
    { duration: "30s", target: 20 }, // ウォームアップ
    { duration: "60s", target: 100 }, // 通常負荷
    { duration: "60s", target: 200 }, // 高負荷 (Worker が追いつかなくてもAPIは速い)
    { duration: "30s", target: 50 }, // クールダウン
    { duration: "10s", target: 0 },
  ],
  thresholds: {
    // 非同期なので非常に速いはず
    event_accept_latency: ["p(50)<5", "p(95)<20", "p(99)<50"],
    event_error_rate: ["rate<0.01"], // 1% 未満のエラー率
    http_req_failed: ["rate<0.01"],
  },
};

const API_URL = __ENV.API_URL || "http://localhost:8080";

// テスト用デバイス ID リスト
const DEVICE_IDS = Array.from(
  { length: 100 },
  (_, i) => `device-${String(i + 1).padStart(3, "0")}`
);
const EVENT_TYPES = [
  "heartbeat",
  "alert",
  "telemetry",
  "status_update",
  "error_report",
];

// ── メイン実行関数 ────────────────────────────────────────────────────────────
export default function () {
  const deviceID = DEVICE_IDS[Math.floor(Math.random() * DEVICE_IDS.length)];
  const eventType =
    EVENT_TYPES[Math.floor(Math.random() * EVENT_TYPES.length)];
  const idempotencyKey = `k6-${__VU}-${__ITER}-${Date.now()}`;

  const payload = JSON.stringify({
    device_id: deviceID,
    event_type: eventType,
    payload: JSON.stringify({
      battery: Math.floor(Math.random() * 100),
      signal: Math.floor(Math.random() * 100),
      temperature: (20 + Math.random() * 20).toFixed(1),
    }),
  });

  group("POST /events (async)", function () {
    const res = http.post(`${API_URL}/events`, payload, {
      headers: {
        "Content-Type": "application/json",
        "X-Idempotency-Key": idempotencyKey,
        "X-Request-ID": `k6-vu${__VU}-iter${__ITER}`,
      },
      timeout: "5s",
    });

    const ok = check(res, {
      "status is 202 Accepted": (r) => r.status === 202,
      "response has accepted=true": (r) => {
        try {
          return JSON.parse(r.body).accepted === true;
        } catch {
          return false;
        }
      },
      "response has event_id": (r) => {
        try {
          return !!JSON.parse(r.body).event_id;
        } catch {
          return false;
        }
      },
      "response time < 50ms": (r) => r.timings.duration < 50,
      "X-Request-ID propagated": (r) => !!r.headers["X-Request-ID"],
    });

    eventAcceptLatency.add(res.timings.duration);
    eventErrorRate.add(!ok);

    if (res.status === 202) {
      acceptedEvents.add(1);
    } else {
      rejectedEvents.add(1);
    }
  });

  // デバイスは約 60ms ごとに heartbeat (実際は 60秒だが、テスト用に短縮)
  sleep(0.06);
}

// ── ヘルスチェック ────────────────────────────────────────────────────────────
export function setup() {
  const res = http.get(`${API_URL}/health`);
  if (res.status !== 200) {
    throw new Error(
      `API health check failed: ${res.status} — is the API running at ${API_URL}?`
    );
  }
  console.log(`API is healthy: ${res.body}`);
}

// ── サマリ ────────────────────────────────────────────────────────────────────
export function handleSummary(data) {
  const p50 = data.metrics.event_accept_latency?.values?.["p(50)"]?.toFixed(2) ?? "N/A";
  const p95 = data.metrics.event_accept_latency?.values?.["p(95)"]?.toFixed(2) ?? "N/A";
  const p99 = data.metrics.event_accept_latency?.values?.["p(99)"]?.toFixed(2) ?? "N/A";
  const accepted = data.metrics.accepted_events?.values?.count ?? 0;
  const rejected = data.metrics.rejected_events?.values?.count ?? 0;
  const errorRate = data.metrics.event_error_rate?.values?.rate ?? 0;

  const summary = `
========================================
  非同期 API 負荷テスト結果
========================================
  Accepted Events:  ${accepted}
  Rejected Events:  ${rejected}
  Error Rate:       ${(errorRate * 100).toFixed(2)}%

  Latency (event_accept_latency):
    p50:  ${p50} ms
    p95:  ${p95} ms
    p99:  ${p99} ms

  目標: p99 < 50ms (非同期化の効果)
========================================
`;

  console.log(summary);
  return { stdout: summary };
}
