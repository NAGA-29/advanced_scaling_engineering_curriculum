import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// カスタムメトリクス
const readLatency = new Trend('read_latency', true);
const writeLatency = new Trend('write_latency', true);
const errorRate = new Rate('error_rate');
const writeErrorRate = new Rate('write_error_rate');
const readErrorRate = new Rate('read_error_rate');
const writesTotal = new Counter('writes_total');
const readsTotal = new Counter('reads_total');

// テスト設定: 読み重視（80% read, 20% write）
export const options = {
  stages: [
    { duration: '10s', target: 20 },   // ランプアップ
    { duration: '50s', target: 100 },  // 定常負荷（高め）
    { duration: '10s', target: 0 },    // ランプダウン
  ],
  thresholds: {
    // 全体の p95 が 100ms 以内
    http_req_duration: ['p(95)<100', 'p(99)<300'],
    // 読み込みの p95 が 50ms 以内
    read_latency: ['p(95)<50'],
    // 書き込みの p95 が 200ms 以内
    write_latency: ['p(95)<200'],
    // エラーレートが 2% 未満
    error_rate: ['rate<0.02'],
    write_error_rate: ['rate<0.05'],
  },
};

const BASE_URL = `http://${__ENV.API_HOST || '127.0.0.1'}:${__ENV.API_PORT || '8080'}`;

const TENANT_IDS = [
  'tenant-001',
  'tenant-002',
  'tenant-003',
  'tenant-004',
  'tenant-005',
];

const MAX_USER_ID = 1000;

let writeCounter = 0;

function randomInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function randomTenantId() {
  return TENANT_IDS[Math.floor(Math.random() * TENANT_IDS.length)];
}

function uniqueEmail() {
  // VU ID + タイムスタンプ + ランダム値でユニークなメールアドレスを生成
  const ts = Date.now();
  const rand = Math.floor(Math.random() * 100000);
  return `k6_${__VU}_${ts}_${rand}@loadtest.example.com`;
}

export default function () {
  const roll = Math.random();

  if (roll < 0.80) {
    // ── 読み込みリクエスト (80%) ──
    // Replica が受け持つ読み込み負荷を高め、Primary の余裕を作る
    performRead();
  } else {
    // ── 書き込みリクエスト (20%) ──
    // Primary だけが処理するため、高負荷時に詰まる可能性がある
    performWrite();
  }

  sleep(Math.random() * 0.05);
}

/**
 * 読み込みリクエスト
 * Replica が健全なら Replica が処理し、停止中なら Primary へ Fallback する
 */
function performRead() {
  const readRoll = Math.random();

  let res;

  if (readRoll < 0.60) {
    // パターン R1 (60%): Primary Key でユーザー取得
    const userId = randomInt(1, MAX_USER_ID);
    res = http.get(`${BASE_URL}/users/${userId}`, {
      tags: { operation: 'read', pattern: 'get_by_id' },
    });

  } else if (readRoll < 0.90) {
    // パターン R2 (30%): テナント別ユーザー一覧
    const tenantId = randomTenantId();
    res = http.get(`${BASE_URL}/users?tenant_id=${tenantId}`, {
      tags: { operation: 'read', pattern: 'list_by_tenant' },
    });

  } else {
    // パターン R3 (10%): ヘルスチェック（Replica 状態も含む）
    res = http.get(`${BASE_URL}/health`, {
      tags: { operation: 'read', pattern: 'health' },
    });
  }

  readsTotal.add(1);
  readLatency.add(res.timings.duration);

  const ok = check(res, {
    'read: status 2xx or 404': (r) => r.status >= 200 && r.status < 500,
    'read: latency < 200ms': (r) => r.timings.duration < 200,
  });

  errorRate.add(!ok ? 1 : 0);
  readErrorRate.add(!ok ? 1 : 0);
}

/**
 * 書き込みリクエスト
 * 常に Primary が処理する
 */
function performWrite() {
  const tenantId = randomTenantId();
  const email = uniqueEmail();

  const payload = `tenant_id=${encodeURIComponent(tenantId)}&name=${encodeURIComponent(`LoadTest User ${__VU}`)}&email=${encodeURIComponent(email)}`;

  const res = http.post(`${BASE_URL}/users`, payload, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    tags: { operation: 'write', pattern: 'create_user' },
  });

  writesTotal.add(1);
  writeLatency.add(res.timings.duration);

  const ok = check(res, {
    'write: status 201': (r) => r.status === 201,
    'write: latency < 500ms': (r) => r.timings.duration < 500,
  });

  errorRate.add(!ok ? 1 : 0);
  writeErrorRate.add(!ok ? 1 : 0);

  if (!ok) {
    console.warn(`Write failed: status=${res.status}, body=${res.body.substring(0, 200)}`);
  }
}

/**
 * テスト終了サマリ
 */
export function handleSummary(data) {
  const readDur = data.metrics.read_latency;
  const writeDur = data.metrics.write_latency;
  const allDur = data.metrics.http_req_duration;
  const rps = data.metrics.http_reqs ? data.metrics.http_reqs.values.rate : 0;
  const errRate = data.metrics.error_rate;
  const reads = data.metrics.reads_total ? data.metrics.reads_total.values.count : 0;
  const writes = data.metrics.writes_total ? data.metrics.writes_total.values.count : 0;

  const fmt = (v) => (v !== undefined ? v.toFixed(2) : 'N/A');

  console.log('');
  console.log('================================================================');
  console.log('  STEP 03: Read Replica Load Test Summary');
  console.log('  Target: 80% reads (Replica) / 20% writes (Primary)');
  console.log('================================================================');
  console.log('  [ Overall ]');
  console.log(`    p50  latency : ${allDur ? fmt(allDur.values['p(50)']) : 'N/A'} ms`);
  console.log(`    p95  latency : ${allDur ? fmt(allDur.values['p(95)']) : 'N/A'} ms`);
  console.log(`    p99  latency : ${allDur ? fmt(allDur.values['p(99)']) : 'N/A'} ms`);
  console.log(`    RPS          : ${fmt(rps)} req/s`);
  console.log(`    Error Rate   : ${errRate ? fmt(errRate.values.rate * 100) : '0.00'} %`);
  console.log('');
  console.log(`  [ Reads (total: ${reads}) ]`);
  console.log(`    p50  : ${readDur ? fmt(readDur.values['p(50)']) : 'N/A'} ms`);
  console.log(`    p95  : ${readDur ? fmt(readDur.values['p(95)']) : 'N/A'} ms`);
  console.log(`    p99  : ${readDur ? fmt(readDur.values['p(99)']) : 'N/A'} ms`);
  console.log('');
  console.log(`  [ Writes (total: ${writes}) ]`);
  console.log(`    p50  : ${writeDur ? fmt(writeDur.values['p(50)']) : 'N/A'} ms`);
  console.log(`    p95  : ${writeDur ? fmt(writeDur.values['p(95)']) : 'N/A'} ms`);
  console.log(`    p99  : ${writeDur ? fmt(writeDur.values['p(99)']) : 'N/A'} ms`);
  console.log('');
  console.log('  Observation points:');
  console.log('  1. Check Primary CPU vs Replica CPU (Primary should be lower with Replica)');
  console.log('  2. Run with Replica stopped to see fallback behavior');
  console.log('  3. Check SHOW REPLICA STATUS for Seconds_Behind_Source');
  console.log('================================================================');

  return {
    stdout: JSON.stringify(data, null, 2),
  };
}
