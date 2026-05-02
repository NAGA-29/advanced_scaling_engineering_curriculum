import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// カスタムメトリクス
const errorRate = new Rate('error_rate');
const tenantQueryLatency = new Trend('tenant_query_latency', true);
const emailQueryLatency = new Trend('email_query_latency', true);
const userByIdLatency = new Trend('user_by_id_latency', true);

// テスト設定
export const options = {
  stages: [
    { duration: '10s', target: 10 },  // ランプアップ
    { duration: '40s', target: 50 },  // 定常負荷
    { duration: '10s', target: 0 },   // ランプダウン
  ],
  thresholds: {
    // p95 が 500ms 以内（インデックスなし環境でも一応通るよう緩め）
    http_req_duration: ['p(95)<500', 'p(99)<2000'],
    error_rate: ['rate<0.05'],
    // テナントクエリの p95
    tenant_query_latency: ['p(95)<500'],
    // ユーザー ID 検索の p95（Primary Key は常に速いはず）
    user_by_id_latency: ['p(95)<50'],
  },
};

const TENANT_IDS = [
  'tenant-001',
  'tenant-002',
  'tenant-003',
  'tenant-004',
  'tenant-005',
  'tenant-006',
  'tenant-007',
  'tenant-008',
  'tenant-009',
  'tenant-010',
];

const MAX_USER_ID = 100000;

function randomInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function randomTenantId() {
  return TENANT_IDS[Math.floor(Math.random() * TENANT_IDS.length)];
}

export default function () {
  const baseUrl = `http://${__ENV.EC2_IP}:8080`;
  const roll = Math.random();

  if (roll < 0.40) {
    // ── パターン A (40%): テナント別ユーザー一覧 ──
    // インデックスが効いているかどうかで大きく差が出るクエリ
    const tenantId = randomTenantId();
    const url = `${baseUrl}/users?tenant_id=${tenantId}`;

    const res = http.get(url, {
      tags: { query_type: 'tenant_list' },
    });

    tenantQueryLatency.add(res.timings.duration);

    const ok = check(res, {
      'tenant list: status 200': (r) => r.status === 200,
      'tenant list: latency < 500ms': (r) => r.timings.duration < 500,
      'tenant list: returns array': (r) => {
        try {
          return Array.isArray(JSON.parse(r.body));
        } catch (e) {
          return false;
        }
      },
    });

    errorRate.add(!ok ? 1 : 0);

  } else if (roll < 0.70) {
    // ── パターン B (30%): Primary Key でユーザー取得 ──
    // Primary Key なのでインデックスの有無に関わらず常に速い
    // これとパターン A を比較することで、インデックスの重要性が明確になる
    const userId = randomInt(1, MAX_USER_ID);
    const url = `${baseUrl}/users/${userId}`;

    const res = http.get(url, {
      tags: { query_type: 'user_by_id' },
    });

    userByIdLatency.add(res.timings.duration);

    const ok = check(res, {
      'user by id: status 200 or 404': (r) => r.status === 200 || r.status === 404,
      'user by id: latency < 50ms': (r) => r.timings.duration < 50,
    });

    errorRate.add(!ok ? 1 : 0);

  } else if (roll < 0.90) {
    // ── パターン C (20%): email 検索 ──
    // uq_users_email（Unique Index）を使う検索
    const userId = randomInt(1, MAX_USER_ID);
    const email = `user${userId}@example.com`;
    const url = `${baseUrl}/users/email/${email}`;

    const res = http.get(url, {
      tags: { query_type: 'user_by_email' },
    });

    emailQueryLatency.add(res.timings.duration);

    const ok = check(res, {
      'email search: status 200, 404, or 501': (r) =>
        r.status === 200 || r.status === 404 || r.status === 501,
      'email search: latency < 100ms': (r) => r.timings.duration < 100,
    });

    errorRate.add(!ok ? 1 : 0);

  } else {
    // ── パターン D (10%): ヘルスチェック ──
    const url = `${baseUrl}/health`;

    const res = http.get(url, {
      tags: { query_type: 'health' },
    });

    const ok = check(res, {
      'health: status 200': (r) => r.status === 200,
    });

    errorRate.add(!ok ? 1 : 0);
  }

  sleep(Math.random() * 0.05);
}

/**
 * テスト終了時のサマリ出力
 * インデックスあり/なしの比較結果を見やすく表示
 */
export function handleSummary(data) {
  const dur = data.metrics.http_req_duration;
  const tenantDur = data.metrics.tenant_query_latency;
  const emailDur = data.metrics.email_query_latency;
  const idDur = data.metrics.user_by_id_latency;
  const rps = data.metrics.http_reqs ? data.metrics.http_reqs.values.rate : 0;
  const errRate = data.metrics.error_rate;

  const fmt = (v) => (v !== undefined ? v.toFixed(2) : 'N/A');

  console.log('');
  console.log('================================================================');
  console.log('  STEP 02: Query Comparison Test Summary');
  console.log('================================================================');
  console.log('  [ Overall ]');
  console.log(`    p50  : ${dur ? fmt(dur.values['p(50)']) : 'N/A'} ms`);
  console.log(`    p95  : ${dur ? fmt(dur.values['p(95)']) : 'N/A'} ms`);
  console.log(`    p99  : ${dur ? fmt(dur.values['p(99)']) : 'N/A'} ms`);
  console.log(`    RPS  : ${rps ? fmt(rps) : 'N/A'} req/s`);
  console.log(`    Err  : ${errRate ? fmt(errRate.values.rate * 100) : '0.00'} %`);
  console.log('');
  console.log('  [ Pattern A: GET /users?tenant_id=... (should differ with/without index) ]');
  console.log(`    p50  : ${tenantDur ? fmt(tenantDur.values['p(50)']) : 'N/A'} ms`);
  console.log(`    p95  : ${tenantDur ? fmt(tenantDur.values['p(95)']) : 'N/A'} ms`);
  console.log(`    p99  : ${tenantDur ? fmt(tenantDur.values['p(99)']) : 'N/A'} ms`);
  console.log('');
  console.log('  [ Pattern B: GET /users/:id (Primary Key - always fast) ]');
  console.log(`    p50  : ${idDur ? fmt(idDur.values['p(50)']) : 'N/A'} ms`);
  console.log(`    p95  : ${idDur ? fmt(idDur.values['p(95)']) : 'N/A'} ms`);
  console.log(`    p99  : ${idDur ? fmt(idDur.values['p(99)']) : 'N/A'} ms`);
  console.log('');
  console.log('  Expected comparison (tenant_query_latency p95):');
  console.log('    Index あり: < 20ms');
  console.log('    Index なし: > 500ms');
  console.log('================================================================');

  return {
    stdout: JSON.stringify(data, null, 2),
  };
}
