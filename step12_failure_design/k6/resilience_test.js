/**
 * STEP 12: レジリエンス負荷テスト
 *
 * カオス実行中に負荷をかけ、以下を計測する:
 * - 障害注入前後の error rate 変化
 * - レイテンシスパイク
 * - Circuit Breaker が OPEN になるまでの時間
 * - fallback (degraded=true) レスポンスの比率
 * - 障害終了後の回復時間
 *
 * 実行方法:
 *   # ターミナル1: 負荷テスト実行
 *   k6 run k6/resilience_test.js
 *
 *   # ターミナル2: カオス注入 (別ターミナルで実行)
 *   bash scripts/chaos.sh db-stop   # 30秒後
 *   bash scripts/chaos.sh db-start  # さらに30秒後
 */

import http from "k6/http";
import { check, sleep, group } from "k6";
import { Trend, Rate, Counter } from "k6/metrics";

// ── カスタムメトリクス ────────────────────────────────────────────────────────
const requestLatency = new Trend("request_latency", true);
const errorRate = new Rate("error_rate");
const degradedRate = new Rate("degraded_rate");    // degraded=true のレスポンス比率
const circuitOpenCount = new Counter("circuit_open_count"); // CB OPEN によるエラー数
const fallbackCount = new Counter("fallback_count");        // fallback 使用回数
const successCount = new Counter("success_count");

// ── テスト設定 ───────────────────────────────────────────────────────────────
export const options = {
  stages: [
    { duration: "30s", target: 20 },  // フェーズ1: 正常負荷 (カオス前)
    { duration: "60s", target: 50 },  // フェーズ2: 負荷増加 (ここでカオスを注入)
    { duration: "60s", target: 50 },  // フェーズ3: 障害継続中
    { duration: "60s", target: 50 },  // フェーズ4: 回復フェーズ
    { duration: "30s", target: 0 },   // フェーズ5: クールダウン
  ],
  thresholds: {
    // 障害中でも完全なエラーは 10% 未満に抑える (Circuit Breaker + fallback が機能)
    error_rate: ["rate<0.10"],
    // p95 は障害中でも 1秒以内 (Circuit Breaker が速く失敗させる)
    request_latency: ["p(95)<1000"],
  },
};

const API_URL = __ENV.API_URL || "http://localhost:8080";

// テスト用ユーザー ID
const USER_IDS = ["1", "2", "3"];

// ── メイン実行関数 ────────────────────────────────────────────────────────────
export default function () {
  const userID = USER_IDS[Math.floor(Math.random() * USER_IDS.length)];

  group("GET /users/:id (resilience)", function () {
    const res = http.get(`${API_URL}/users/${userID}`, {
      headers: {
        "X-Request-ID": `k6-vu${__VU}-iter${__ITER}`,
      },
      timeout: "10s", // k6 側は長めに設定 (API 側の CB タイムアウトを観測)
    });

    const isDegraded =
      res.headers["X-Degraded"] === "true" ||
      (res.status === 200 &&
        (() => {
          try {
            return JSON.parse(res.body).degraded === true;
          } catch {
            return false;
          }
        })());

    const isCircuitOpen =
      res.status === 503 &&
      (() => {
        try {
          return (
            JSON.parse(res.body).error === "circuit_breaker_open" ||
            res.body.includes("circuit")
          );
        } catch {
          return false;
        }
      })();

    const ok = check(res, {
      "status is 200 or 503": (r) => r.status === 200 || r.status === 503,
      "response is valid JSON": (r) => {
        try {
          JSON.parse(r.body);
          return true;
        } catch {
          return false;
        }
      },
    });

    requestLatency.add(res.timings.duration);
    errorRate.add(res.status >= 500 && !isDegraded);

    if (isDegraded) {
      degradedRate.add(1);
      fallbackCount.add(1);
    } else {
      degradedRate.add(0);
    }

    if (isCircuitOpen) {
      circuitOpenCount.add(1);
    }

    if (res.status === 200 && !isDegraded) {
      successCount.add(1);
    }
  });

  // Circuit Breaker 状態を定期的に確認 (VU 1 だけ)
  if (__VU === 1 && __ITER % 10 === 0) {
    group("GET /circuit-breaker/status (monitoring)", function () {
      const cbRes = http.get(`${API_URL}/circuit-breaker/status`, {
        timeout: "3s",
      });
      if (cbRes.status === 200) {
        try {
          const cbState = JSON.parse(cbRes.body);
          console.log(
            `[CB Status] state=${cbState.state} failures=${cbState.failures}/${cbState.max_failures} time_until_retry=${cbState.time_until_retry || "N/A"}`
          );
        } catch {}
      }
    });
  }

  sleep(0.2);
}

// ── セットアップ ──────────────────────────────────────────────────────────────
export function setup() {
  const res = http.get(`${API_URL}/health`);
  if (res.status !== 200 && res.status !== 503) {
    throw new Error(
      `API not reachable at ${API_URL}/health (status: ${res.status})`
    );
  }

  console.log("=== Resilience Test Started ===");
  console.log("Inject chaos with:");
  console.log("  bash scripts/chaos.sh db-stop   # DB を停止");
  console.log("  bash scripts/chaos.sh db-start  # DB を復旧");
  console.log("================================");
}

// ── サマリ ────────────────────────────────────────────────────────────────────
export function handleSummary(data) {
  const p50 = data.metrics.request_latency?.values?.["p(50)"]?.toFixed(2) ?? "N/A";
  const p95 = data.metrics.request_latency?.values?.["p(95)"]?.toFixed(2) ?? "N/A";
  const p99 = data.metrics.request_latency?.values?.["p(99)"]?.toFixed(2) ?? "N/A";
  const errRate = ((data.metrics.error_rate?.values?.rate ?? 0) * 100).toFixed(2);
  const degRate = ((data.metrics.degraded_rate?.values?.rate ?? 0) * 100).toFixed(2);
  const cbOpen = data.metrics.circuit_open_count?.values?.count ?? 0;
  const fallbacks = data.metrics.fallback_count?.values?.count ?? 0;
  const successes = data.metrics.success_count?.values?.count ?? 0;

  const summary = `
========================================
  レジリエンステスト結果
========================================
  成功 (200 non-degraded):  ${successes}
  Fallback (degraded):      ${fallbacks}
  Circuit Open errors:      ${cbOpen}
  Error Rate:               ${errRate}%
  Degraded Response Rate:   ${degRate}%

  Latency (request_latency):
    p50:  ${p50} ms
    p95:  ${p95} ms
    p99:  ${p99} ms

  評価:
    - error_rate < 10%:     ${parseFloat(errRate) < 10 ? "PASS" : "FAIL"}
    - p95 < 1000ms:         ${parseFloat(p95) < 1000 ? "PASS" : "FAIL"}
========================================
`;

  console.log(summary);
  return { stdout: summary };
}
