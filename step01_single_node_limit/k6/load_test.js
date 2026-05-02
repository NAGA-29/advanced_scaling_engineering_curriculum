import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// カスタムメトリクス
const errorCount = new Counter('error_count');
const errorRate = new Rate('error_rate');
const getUserLatency = new Trend('get_user_latency', true);
const listUsersLatency = new Trend('list_users_latency', true);

// テスト設定
export const options = {
  vus: 50,
  duration: '60s',
  thresholds: {
    // 全リクエストの p95 が 200ms 以内であること
    http_req_duration: ['p(95)<200', 'p(99)<500'],
    // エラー率が 1% 未満であること
    error_rate: ['rate<0.01'],
    // GET /users/:id の p95 が 100ms 以内
    get_user_latency: ['p(95)<100'],
  },
};

// テナント ID のリスト（setup.sql で投入した値に合わせる）
const TENANT_IDS = [
  'tenant-001',
  'tenant-002',
  'tenant-003',
  'tenant-004',
  'tenant-005',
];

// 最大ユーザー ID（setup.sql で投入した件数）
const MAX_USER_ID = 100000;

/**
 * ランダムな整数を返す（min 以上 max 以下）
 */
function randomInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

/**
 * ランダムなテナント ID を返す
 */
function randomTenantId() {
  return TENANT_IDS[Math.floor(Math.random() * TENANT_IDS.length)];
}

export default function () {
  const baseUrl = `http://${__ENV.EC2_IP}:8080`;

  // 70% の確率で GET /users/:id、30% の確率で GET /users?tenant_id=...
  const roll = Math.random();

  if (roll < 0.70) {
    // ── パターン A: ユーザー ID で直接取得 ──
    const userId = randomInt(1, MAX_USER_ID);
    const url = `${baseUrl}/users/${userId}`;

    const res = http.get(url, {
      tags: { endpoint: 'get_user_by_id' },
    });

    getUserLatency.add(res.timings.duration);

    const ok = check(res, {
      'GET /users/:id status is 200 or 404': (r) => r.status === 200 || r.status === 404,
      'GET /users/:id duration < 200ms': (r) => r.timings.duration < 200,
    });

    if (!ok || (res.status !== 200 && res.status !== 404)) {
      errorCount.add(1);
      errorRate.add(1);
      console.error(`GET /users/${userId} failed: status=${res.status}, body=${res.body}`);
    } else {
      errorRate.add(0);
    }

  } else {
    // ── パターン B: テナント別ユーザー一覧取得 ──
    const tenantId = randomTenantId();
    const url = `${baseUrl}/users?tenant_id=${tenantId}`;

    const res = http.get(url, {
      tags: { endpoint: 'list_users_by_tenant' },
    });

    listUsersLatency.add(res.timings.duration);

    const ok = check(res, {
      'GET /users?tenant_id status is 200': (r) => r.status === 200,
      'GET /users?tenant_id duration < 500ms': (r) => r.timings.duration < 500,
      'response is JSON array': (r) => {
        try {
          const body = JSON.parse(r.body);
          return Array.isArray(body);
        } catch (e) {
          return false;
        }
      },
    });

    if (!ok) {
      errorCount.add(1);
      errorRate.add(1);
      console.error(`GET /users?tenant_id=${tenantId} failed: status=${res.status}`);
    } else {
      errorRate.add(0);
    }
  }

  // 仮想ユーザーごとに 0〜100ms のランダムな待機（実際のユーザー行動を模倣）
  sleep(Math.random() * 0.1);
}

/**
 * テスト終了時のサマリ出力
 */
export function handleSummary(data) {
  const dur = data.metrics.http_req_duration;
  const rps = data.metrics.http_reqs ? data.metrics.http_reqs.values.rate : 0;

  console.log('');
  console.log('========================================');
  console.log('  STEP 01 Load Test Summary');
  console.log('========================================');
  console.log(`  p50  latency : ${dur ? dur.values['p(50)'].toFixed(2) : 'N/A'} ms`);
  console.log(`  p95  latency : ${dur ? dur.values['p(95)'].toFixed(2) : 'N/A'} ms`);
  console.log(`  p99  latency : ${dur ? dur.values['p(99)'].toFixed(2) : 'N/A'} ms`);
  console.log(`  RPS          : ${rps ? rps.toFixed(1) : 'N/A'} req/s`);
  const errRate = data.metrics.error_rate;
  console.log(`  Error Rate   : ${errRate ? (errRate.values.rate * 100).toFixed(2) : '0.00'} %`);
  console.log('========================================');

  return {
    stdout: JSON.stringify(data, null, 2),
  };
}
