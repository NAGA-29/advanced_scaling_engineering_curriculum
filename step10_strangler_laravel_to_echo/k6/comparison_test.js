/**
 * STEP 10: Laravel vs Echo レイテンシ比較テスト
 *
 * 同一エンドポイント (/heartbeat) を Laravel (port 8000) と Echo (port 8080) の
 * 両方に対して並列でリクエストし、レイテンシを比較する。
 *
 * 実行方法:
 *   k6 run k6/comparison_test.js
 *
 * 環境変数:
 *   LARAVEL_URL  (default: http://localhost:8000)
 *   ECHO_URL     (default: http://localhost:8080)
 *   JWT_TOKEN    (default: テスト用トークン)
 */

import http from "k6/http";
import { check, sleep, group } from "k6";
import { Trend, Rate, Counter } from "k6/metrics";

// ── カスタムメトリクス ────────────────────────────────────────────────────────
const laravelLatency = new Trend("laravel_latency", true); // ms
const echoLatency = new Trend("echo_latency", true); // ms
const laravelErrors = new Rate("laravel_error_rate");
const echoErrors = new Rate("echo_error_rate");
const laravelRequests = new Counter("laravel_total_requests");
const echoRequests = new Counter("echo_total_requests");

// ── テスト設定 ───────────────────────────────────────────────────────────────
export const options = {
  stages: [
    { duration: "30s", target: 10 }, // ウォームアップ
    { duration: "60s", target: 50 }, // 負荷増加
    { duration: "60s", target: 100 }, // ピーク
    { duration: "30s", target: 0 }, // クールダウン
  ],
  thresholds: {
    // Echo は Laravel より速いはず
    echo_latency: ["p(95)<30", "p(99)<50"],
    laravel_latency: ["p(95)<150", "p(99)<300"],
    echo_error_rate: ["rate<0.01"],
    laravel_error_rate: ["rate<0.01"],
  },
};

// ── 設定値 ───────────────────────────────────────────────────────────────────
const LARAVEL_URL = __ENV.LARAVEL_URL || "http://localhost:8000";
const ECHO_URL = __ENV.ECHO_URL || "http://localhost:8080";

// テスト用 JWT トークン (HS256, secret: "dev-secret-change-in-production")
// payload: { "device_id": "test-device-001", "exp": 9999999999 }
const JWT_TOKEN =
  __ENV.JWT_TOKEN ||
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." +
    "eyJkZXZpY2VfaWQiOiJ0ZXN0LWRldmljZS0wMDEiLCJleHAiOjk5OTk5OTk5OTl9." +
    "placeholder-signature-replace-with-real-token";

const headers = {
  Authorization: `Bearer ${JWT_TOKEN}`,
  "Content-Type": "application/json",
  "X-Request-ID": `k6-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
};

// ── メイン実行関数 ────────────────────────────────────────────────────────────
export default function () {
  // VU ID で Laravel / Echo を交互にテスト (比較のため両方テスト)
  const requestId = `k6-vu${__VU}-iter${__ITER}`;

  group("Laravel /heartbeat", function () {
    const res = http.get(`${LARAVEL_URL}/heartbeat`, {
      headers: { ...headers, "X-Request-ID": requestId + "-laravel" },
      timeout: "5s",
    });

    const ok = check(res, {
      "Laravel: status 200": (r) => r.status === 200,
      "Laravel: has status field": (r) => {
        try {
          return JSON.parse(r.body).status === "ok";
        } catch {
          return false;
        }
      },
      "Laravel: has timestamp": (r) => {
        try {
          return !!JSON.parse(r.body).timestamp;
        } catch {
          return false;
        }
      },
    });

    laravelLatency.add(res.timings.duration);
    laravelErrors.add(!ok);
    laravelRequests.add(1);
  });

  group("Echo /heartbeat", function () {
    const res = http.get(`${ECHO_URL}/heartbeat`, {
      headers: { ...headers, "X-Request-ID": requestId + "-echo" },
      timeout: "5s",
    });

    const ok = check(res, {
      "Echo: status 200": (r) => r.status === 200,
      "Echo: has status field": (r) => {
        try {
          return JSON.parse(r.body).status === "ok";
        } catch {
          return false;
        }
      },
      "Echo: service is echo-api": (r) => {
        try {
          return JSON.parse(r.body).service === "echo-api";
        } catch {
          return false;
        }
      },
      "Echo: X-Handled-By header is echo": (r) =>
        r.headers["X-Handled-By"] === "echo",
      "Echo: X-Request-ID propagated": (r) => !!r.headers["X-Request-ID"],
    });

    echoLatency.add(res.timings.duration);
    echoErrors.add(!ok);
    echoRequests.add(1);
  });

  sleep(0.5);
}

// ── テスト完了サマリ ──────────────────────────────────────────────────────────
export function handleSummary(data) {
  const laravelP50 = data.metrics.laravel_latency?.values?.["p(50)"] ?? "N/A";
  const laravelP95 = data.metrics.laravel_latency?.values?.["p(95)"] ?? "N/A";
  const laravelP99 = data.metrics.laravel_latency?.values?.["p(99)"] ?? "N/A";
  const echoP50 = data.metrics.echo_latency?.values?.["p(50)"] ?? "N/A";
  const echoP95 = data.metrics.echo_latency?.values?.["p(95)"] ?? "N/A";
  const echoP99 = data.metrics.echo_latency?.values?.["p(99)"] ?? "N/A";

  const summary = `
========================================
  Laravel vs Echo 比較結果
========================================
指標        | Laravel      | Echo
----------- | ------------ | ------------
p50 (ms)    | ${String(laravelP50).padEnd(12)} | ${echoP50}
p95 (ms)    | ${String(laravelP95).padEnd(12)} | ${echoP95}
p99 (ms)    | ${String(laravelP99).padEnd(12)} | ${echoP99}
========================================
`;

  console.log(summary);

  return {
    stdout: summary,
  };
}
