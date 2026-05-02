/**
 * STEP 14: 最終統合テスト
 *
 * 全エンドポイントを網羅した総合負荷テスト。
 * 移行の各フェーズ後に実行して、改善量を定量化する。
 *
 * エンドポイント:
 *   GET  /health         ヘルスチェック
 *   GET  /users/:id      ユーザー取得 (キャッシュ有効)
 *   POST /users          ユーザー作成
 *   GET  /heartbeat      heartbeat (Strangler Fig で Echo へ)
 *   POST /events         非同期イベント (202 Accepted)
 *
 * 実行方法:
 *   k6 run k6/final_test.js
 *   k6 run --vus 10 --duration 60s k6/final_test.js  # ベースライン
 *
 * 環境変数:
 *   API_URL      (default: http://localhost:8080)
 *   PHASE        フェーズ名 (ログ記録用, e.g., "initial", "redis_added", "final")
 */

import http from "k6/http";
import { check, sleep, group } from "k6";
import { Trend, Rate, Counter } from "k6/metrics";

// ── カスタムメトリクス ────────────────────────────────────────────────────────
const healthLatency = new Trend("health_latency", true);
const getUserLatency = new Trend("get_user_latency", true);
const postUserLatency = new Trend("post_user_latency", true);
const heartbeatLatency = new Trend("heartbeat_latency", true);
const postEventsLatency = new Trend("post_events_latency", true);

const errorRate = new Rate("overall_error_rate");
const eventsAccepted = new Counter("events_accepted");
const cacheHitCounter = new Counter("cache_hit_total");
const cacheMissCounter = new Counter("cache_miss_total");

// ── テスト設定 ───────────────────────────────────────────────────────────────
export const options = {
  stages: [
    { duration: "30s", target: 5 },   // ウォームアップ
    { duration: "60s", target: 50 },  // 負荷増加
    { duration: "120s", target: 100 }, // ピーク (5分テストの中心)
    { duration: "60s", target: 50 },  // 負荷減少
    { duration: "30s", target: 5 },   // クールダウン
  ],
  thresholds: {
    // 各エンドポイントの SLA
    health_latency:        ["p(95)<10"],
    heartbeat_latency:     ["p(95)<30", "p(99)<100"],
    get_user_latency:      ["p(95)<50", "p(99)<200"],
    post_events_latency:   ["p(95)<20", "p(99)<50"],  // 非同期なので速いはず
    post_user_latency:     ["p(95)<200"],
    overall_error_rate:    ["rate<0.01"],
    http_req_failed:       ["rate<0.01"],
  },
};

const API_URL = __ENV.API_URL || "http://localhost:8080";
const PHASE = __ENV.PHASE || "unknown";

// テストデータ
const USER_IDS = Array.from({ length: 10 }, (_, i) => String(i + 1));
const EVENT_TYPES = ["heartbeat", "alert", "telemetry", "status_update"];
const DEVICE_IDS = Array.from(
  { length: 100 },
  (_, i) => `device-${String(i + 1).padStart(3, "0")}`
);

// ── リクエスト重み付け ──────────────────────��───────────────────────────���─────
// 実際のトラフィックパターンを模倣:
//   heartbeat:   50% (最多)
//   get_user:    25%
//   post_events: 15%
//   post_user:   5%
//   health:      5%
function getScenario() {
  const r = Math.random();
  if (r < 0.50) return "heartbeat";
  if (r < 0.75) return "get_user";
  if (r < 0.90) return "post_events";
  if (r < 0.95) return "post_user";
  return "health";
}

// ── メイン実行関数 ────────────────────────────────────────────────────────────
export default function () {
  const scenario = getScenario();
  const reqID = `k6-${PHASE}-vu${__VU}-iter${__ITER}`;

  switch (scenario) {
    case "health":
      runHealth(reqID);
      break;
    case "heartbeat":
      runHeartbeat(reqID);
      break;
    case "get_user":
      runGetUser(reqID);
      break;
    case "post_user":
      runPostUser(reqID);
      break;
    case "post_events":
      runPostEvents(reqID);
      break;
  }

  sleep(0.1);
}

// ── ヘルスチェック ────────────────────────────────────────────────────────────
function runHealth(reqID) {
  group("GET /health", function () {
    const res = http.get(`${API_URL}/health`, {
      headers: { "X-Request-ID": reqID },
      timeout: "3s",
    });

    const ok = check(res, {
      "health: status 200": (r) => r.status === 200,
      "health: has status field": (r) => {
        try {
          return !!JSON.parse(r.body).status;
        } catch {
          return false;
        }
      },
    });

    healthLatency.add(res.timings.duration);
    errorRate.add(!ok);
  });
}

// ── Heartbeat ──────────────────────────────��──────────────────────────────���───
function runHeartbeat(reqID) {
  const deviceID = DEVICE_IDS[Math.floor(Math.random() * DEVICE_IDS.length)];

  group("GET /heartbeat", function () {
    const res = http.get(`${API_URL}/heartbeat?device_id=${deviceID}`, {
      headers: {
        "X-Request-ID": reqID,
        "X-Device-ID": deviceID,
      },
      timeout: "5s",
    });

    const isHit = res.headers["X-Cache"] === "HIT";
    if (isHit) {
      cacheHitCounter.add(1);
    } else {
      cacheMissCounter.add(1);
    }

    const ok = check(res, {
      "heartbeat: status 200": (r) => r.status === 200,
      "heartbeat: has status ok": (r) => {
        try {
          return JSON.parse(r.body).status === "ok";
        } catch {
          return false;
        }
      },
      // Strangler Fig: Echo が処理している場合の確認
      // "heartbeat: handled by echo": (r) => r.headers["X-Handled-By"] === "echo",
    });

    heartbeatLatency.add(res.timings.duration);
    errorRate.add(!ok);
  });
}

// ── GET /users/:id ────────────────────────────────────────────────────────────
function runGetUser(reqID) {
  const userID = USER_IDS[Math.floor(Math.random() * USER_IDS.length)];

  group("GET /users/:id", function () {
    const res = http.get(`${API_URL}/users/${userID}`, {
      headers: { "X-Request-ID": reqID },
      timeout: "10s",
    });

    const ok = check(res, {
      "get_user: status 200 or 404": (r) => r.status === 200 || r.status === 404,
      "get_user: valid JSON": (r) => {
        try {
          JSON.parse(r.body);
          return true;
        } catch {
          return false;
        }
      },
    });

    getUserLatency.add(res.timings.duration);
    errorRate.add(res.status >= 500);
  });
}

// ── POST /users ───────────────────────────────────────────────────────────────
function runPostUser(reqID) {
  const userNum = Math.floor(Math.random() * 10000);
  const body = JSON.stringify({
    name: `LoadTest-User-${userNum}`,
    email: `loadtest-${userNum}@example.com`,
  });

  group("POST /users", function () {
    const res = http.post(`${API_URL}/users`, body, {
      headers: {
        "Content-Type": "application/json",
        "X-Request-ID": reqID,
        "X-Idempotency-Key": reqID,
      },
      timeout: "10s",
    });

    const ok = check(res, {
      "post_user: status 201 or 200 or 422": (r) =>
        r.status === 201 || r.status === 200 || r.status === 422 || r.status === 409,
    });

    postUserLatency.add(res.timings.duration);
    errorRate.add(res.status >= 500);
  });
}

// ── POST /events (async) ──────────────────────────────────────────────────────
function runPostEvents(reqID) {
  const deviceID = DEVICE_IDS[Math.floor(Math.random() * DEVICE_IDS.length)];
  const eventType = EVENT_TYPES[Math.floor(Math.random() * EVENT_TYPES.length)];
  const idempotencyKey = `${reqID}-${Date.now()}`;

  const body = JSON.stringify({
    device_id: deviceID,
    event_type: eventType,
    payload: JSON.stringify({ battery: Math.floor(Math.random() * 100) }),
  });

  group("POST /events", function () {
    const res = http.post(`${API_URL}/events`, body, {
      headers: {
        "Content-Type": "application/json",
        "X-Request-ID": reqID,
        "X-Idempotency-Key": idempotencyKey,
      },
      timeout: "5s",
    });

    const ok = check(res, {
      "post_events: status 202": (r) => r.status === 202,
      "post_events: accepted=true": (r) => {
        try {
          return JSON.parse(r.body).accepted === true;
        } catch {
          return false;
        }
      },
      "post_events: response time < 50ms": (r) => r.timings.duration < 50,
    });

    postEventsLatency.add(res.timings.duration);
    errorRate.add(!ok);

    if (res.status === 202) {
      eventsAccepted.add(1);
    }
  });
}

// ── セットアップ ────────────────────────────────��─────────────────────────────
export function setup() {
  const res = http.get(`${API_URL}/health`);
  if (res.status !== 200 && res.status !== 503) {
    throw new Error(`API not reachable: ${API_URL}/health returned ${res.status}`);
  }

  console.log(`=== Final Boss Test (phase: ${PHASE}) ===`);
  console.log(`  API URL: ${API_URL}`);
  console.log(`  Traffic mix: heartbeat=50% get_user=25% post_events=15% post_user=5% health=5%`);
  console.log("==========================================");
}

// ── サマリ ─────────────────────���──────────────────────────────────────────────
export function handleSummary(data) {
  const m = data.metrics;

  const fmt = (metric, pct) =>
    m[metric]?.values?.[pct]?.toFixed(2) ?? "N/A";

  const errRate = ((m.overall_error_rate?.values?.rate ?? 0) * 100).toFixed(3);
  const rps = m.http_reqs?.values?.rate?.toFixed(1) ?? "N/A";
  const accepted = m.events_accepted?.values?.count ?? 0;
  const cacheHits = m.cache_hit_total?.values?.count ?? 0;
  const cacheMisses = m.cache_miss_total?.values?.count ?? 0;
  const cacheTotal = cacheHits + cacheMisses;
  const cacheHitRate = cacheTotal > 0 ? ((cacheHits / cacheTotal) * 100).toFixed(1) : "N/A";

  const summary = `
============================================================
  最終統合テスト結果 (phase: ${PHASE})
============================================================
  Overall RPS:          ${rps} req/s
  Overall Error Rate:   ${errRate}%
  Events Accepted:      ${accepted}
  Cache Hit Rate:       ${cacheHitRate}% (${cacheHits}/${cacheTotal})

  Latency by Endpoint:
  ┌────────────────────┬──────────┬──────────┬──────────┐
  │ Endpoint           │  p50 ms  │  p95 ms  │  p99 ms  │
  ├────────────────────┼──────────┼──────────┼──────────┤
  │ GET /health        │ ${fmt("health_latency","p(50)").padEnd(8)} │ ${fmt("health_latency","p(95)").padEnd(8)} │ ${fmt("health_latency","p(99)").padEnd(8)} │
  │ GET /heartbeat     │ ${fmt("heartbeat_latency","p(50)").padEnd(8)} │ ${fmt("heartbeat_latency","p(95)").padEnd(8)} │ ${fmt("heartbeat_latency","p(99)").padEnd(8)} │
  │ GET /users/:id     │ ${fmt("get_user_latency","p(50)").padEnd(8)} │ ${fmt("get_user_latency","p(95)").padEnd(8)} │ ${fmt("get_user_latency","p(99)").padEnd(8)} │
  │ POST /users        │ ${fmt("post_user_latency","p(50)").padEnd(8)} │ ${fmt("post_user_latency","p(95)").padEnd(8)} │ ${fmt("post_user_latency","p(99)").padEnd(8)} │
  │ POST /events       │ ${fmt("post_events_latency","p(50)").padEnd(8)} │ ${fmt("post_events_latency","p(95)").padEnd(8)} │ ${fmt("post_events_latency","p(99)").padEnd(8)} │
  └────────────────────┴──────────┴──────────┴──────────┘

  → この結果を report.md の k6 結果比較表に記入してください
============================================================
`;

  console.log(summary);
  return { stdout: summary };
}
