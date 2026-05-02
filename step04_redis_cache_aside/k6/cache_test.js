import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend, Gauge } from 'k6/metrics';

// カスタムメトリクス
const cacheHitCount = new Counter('cache_hits');
const cacheMissCount = new Counter('cache_misses');
const cacheHitRate = new Rate('cache_hit_rate');
const readLatency = new Trend('read_latency', true);
const writeLatency = new Trend('write_latency', true);
const errorRate = new Rate('error_rate');

// テスト設定
export const options = {
  scenarios: {
    // フェーズ 1: キャッシュウォームアップ（1,000 ユニーク ID を一通りアクセス）
    warmup: {
      executor: 'per-vu-iterations',
      vus: 10,
      iterations: 100,   // 10 VU × 100 = 1,000 リクエスト（各 ID を 1 回）
      maxDuration: '60s',
      tags: { phase: 'warmup' },
      exec: 'warmupScenario',
    },

    // フェーズ 2: 定常負荷テスト（ウォームアップ後のヒット率を計測）
    steady: {
      executor: 'constant-vus',
      vus: 50,
      duration: '60s',
      startTime: '65s',  // ウォームアップ完了後に開始
      tags: { phase: 'steady' },
      exec: 'steadyScenario',
    },
  },
  thresholds: {
    // ウォームアップ後はヒット率 80% 以上を期待
    cache_hit_rate: ['rate>0.8'],
    // 全体の p95 が 50ms 以内（キャッシュあり）
    http_req_duration: ['p(95)<50'],
    // 読み込みの p95 が 20ms 以内
    read_latency: ['p(95)<20'],
    error_rate: ['rate<0.01'],
  },
};

const BASE_URL = `http://${__ENV.API_HOST || '127.0.0.1'}:${__ENV.API_PORT || '8080'}`;

// ウォームアップで使用する 1,000 ユーザー ID のリスト
const USER_IDS = Array.from({ length: 1000 }, (_, i) => i + 1);

const TENANT_IDS = [
  'tenant-001',
  'tenant-002',
  'tenant-003',
  'tenant-004',
  'tenant-005',
];

function randomTenantId() {
  return TENANT_IDS[Math.floor(Math.random() * TENANT_IDS.length)];
}

// -------------------------------------------------------
// フェーズ 1: キャッシュウォームアップ
// -------------------------------------------------------
// 各 VU が異なる ID を担当し、1,000 ユニーク ID を一通りアクセスする。
// これにより Redis にキャッシュが生成される。

export function warmupScenario() {
  // VU ID (1〜10) と iteration (0〜99) から一意のユーザー ID を計算
  const userId = ((__VU - 1) * 100 + __ITER + 1);
  if (userId > 1000) return;

  const url = `${BASE_URL}/users/${userId}`;
  const res = http.get(url, {
    tags: { phase: 'warmup', query_type: 'user_by_id' },
  });

  const xCache = res.headers['X-Cache'] || res.headers['x-cache'] || '';

  if (xCache === 'HIT') {
    cacheHitCount.add(1);
    cacheHitRate.add(1);
  } else {
    cacheMissCount.add(1);
    cacheHitRate.add(0);
  }

  check(res, {
    'warmup: status 200 or 404': (r) => r.status === 200 || r.status === 404,
  });

  sleep(0.01);
}

// -------------------------------------------------------
// フェーズ 2: 定常負荷テスト
// -------------------------------------------------------
// ウォームアップ後に同じ ID に繰り返しアクセスし、ヒット率を計測する。

export function steadyScenario() {
  const roll = Math.random();

  if (roll < 0.70) {
    // パターン R1 (70%): ランダムな ID でユーザー取得（キャッシュヒット率を計測）
    const userId = Math.floor(Math.random() * 1000) + 1;
    performCachedRead(userId);

  } else if (roll < 0.85) {
    // パターン R2 (15%): テナント別ユーザー一覧
    const tenantId = randomTenantId();
    performTenantRead(tenantId);

  } else if (roll < 0.95) {
    // パターン R3 (10%): 存在しない ID（キャッシュミス + 404 のパターン）
    const nonExistentId = Math.floor(Math.random() * 90000) + 10001;
    performCachedRead(nonExistentId);

  } else {
    // パターン W1 (5%): 書き込み（キャッシュ無効化が発生する）
    performWrite();
  }

  sleep(Math.random() * 0.02);
}

/**
 * キャッシュ付きユーザー取得
 * X-Cache ヘッダーでヒット/ミスを記録する
 */
function performCachedRead(userId) {
  const url = `${BASE_URL}/users/${userId}`;
  const res = http.get(url, {
    tags: { phase: 'steady', query_type: 'user_by_id' },
  });

  readLatency.add(res.timings.duration);

  const xCache = res.headers['X-Cache'] || res.headers['x-cache'] || '';

  if (xCache === 'HIT') {
    cacheHitCount.add(1);
    cacheHitRate.add(1);
  } else {
    cacheMissCount.add(1);
    cacheHitRate.add(0);
  }

  const ok = check(res, {
    'read: status 2xx or 404': (r) => r.status === 200 || r.status === 404,
    'read: latency < 100ms': (r) => r.timings.duration < 100,
  });

  errorRate.add(!ok ? 1 : 0);
}

/**
 * テナント別ユーザー一覧取得（キャッシュ付き）
 */
function performTenantRead(tenantId) {
  const url = `${BASE_URL}/users?tenant_id=${tenantId}`;
  const res = http.get(url, {
    tags: { phase: 'steady', query_type: 'tenant_list' },
  });

  readLatency.add(res.timings.duration);

  const xCache = res.headers['X-Cache'] || res.headers['x-cache'] || '';
  if (xCache === 'HIT') {
    cacheHitCount.add(1);
    cacheHitRate.add(1);
  } else {
    cacheMissCount.add(1);
    cacheHitRate.add(0);
  }

  const ok = check(res, {
    'tenant list: status 200': (r) => r.status === 200,
    'tenant list: latency < 200ms': (r) => r.timings.duration < 200,
  });

  errorRate.add(!ok ? 1 : 0);
}

/**
 * ユーザー作成（キャッシュ無効化が発生する）
 */
function performWrite() {
  const ts = Date.now();
  const rand = Math.floor(Math.random() * 100000);
  const email = `k6_${__VU}_${ts}_${rand}@cachetest.example.com`;

  const payload = JSON.stringify({
    tenant_id: randomTenantId(),
    name: `Cache Test User ${__VU}`,
    email: email,
  });

  const res = http.post(`${BASE_URL}/users`, payload, {
    headers: { 'Content-Type': 'application/json' },
    tags: { phase: 'steady', query_type: 'create_user' },
  });

  writeLatency.add(res.timings.duration);

  const ok = check(res, {
    'write: status 201': (r) => r.status === 201,
    'write: latency < 300ms': (r) => r.timings.duration < 300,
  });

  errorRate.add(!ok ? 1 : 0);
}

// -------------------------------------------------------
// デフォルトシナリオ（--vus / --duration 指定時のフォールバック）
// -------------------------------------------------------
export default function () {
  steadyScenario();
}

/**
 * テスト終了サマリ
 */
export function handleSummary(data) {
  const allDur = data.metrics.http_req_duration;
  const readDur = data.metrics.read_latency;
  const hits = data.metrics.cache_hits ? data.metrics.cache_hits.values.count : 0;
  const misses = data.metrics.cache_misses ? data.metrics.cache_misses.values.count : 0;
  const total = hits + misses;
  const hitRateVal = total > 0 ? (hits / total * 100).toFixed(1) : '0.0';
  const rps = data.metrics.http_reqs ? data.metrics.http_reqs.values.rate : 0;
  const errRate = data.metrics.error_rate;

  const fmt = (v) => (v !== undefined ? v.toFixed(2) : 'N/A');

  console.log('');
  console.log('================================================================');
  console.log('  STEP 04: Cache-Aside Test Summary');
  console.log('================================================================');
  console.log('  [ Cache Statistics ]');
  console.log(`    Hits       : ${hits}`);
  console.log(`    Misses     : ${misses}`);
  console.log(`    Hit Rate   : ${hitRateVal} %  (target: > 80%)`);
  console.log('');
  console.log('  [ Performance ]');
  console.log(`    p50 latency : ${allDur ? fmt(allDur.values['p(50)']) : 'N/A'} ms`);
  console.log(`    p95 latency : ${allDur ? fmt(allDur.values['p(95)']) : 'N/A'} ms`);
  console.log(`    p99 latency : ${allDur ? fmt(allDur.values['p(99)']) : 'N/A'} ms`);
  console.log(`    RPS         : ${fmt(rps)} req/s`);
  console.log(`    Error Rate  : ${errRate ? fmt(errRate.values.rate * 100) : '0.00'} %`);
  console.log('');
  console.log('  [ Read Latency (cache-aware) ]');
  console.log(`    p50 : ${readDur ? fmt(readDur.values['p(50)']) : 'N/A'} ms`);
  console.log(`    p95 : ${readDur ? fmt(readDur.values['p(95)']) : 'N/A'} ms`);
  console.log(`    p99 : ${readDur ? fmt(readDur.values['p(99)']) : 'N/A'} ms`);
  console.log('');
  console.log('  Expected: Hit Rate > 80%, p95 < 20ms (cache warm)');
  console.log('');
  console.log('  To test fallback:');
  console.log('    docker compose stop redis');
  console.log('    k6 run k6/cache_test.js  # エラーレートが 0% を維持すること');
  console.log('================================================================');

  return {
    stdout: JSON.stringify(data, null, 2),
  };
}
