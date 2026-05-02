/**
 * k6 sharding test for Step 07: Redis Sharding
 *
 * This test exercises the sharded cache layer by:
 *   1. Writing user data (simulating cache population)
 *   2. Reading user data (simulating cache hits)
 *   3. Verifying all shards are receiving traffic
 *
 * After the test, run:
 *   for port in 6379 6380 6381; do
 *     echo "Shard $((port-6379)) keyspace:"; redis-cli -p $port INFO keyspace; done
 *
 * Usage:
 *   k6 run -e APP_URL=http://localhost:8080 k6/sharding_test.js
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// ─── Custom Metrics ────────────────────────────────────────────────────────────
const cacheHits    = new Counter('cache_hits');
const cacheMisses  = new Counter('cache_misses');
const cacheErrors  = new Counter('cache_errors');
const errorRate    = new Rate('error_rate');
const readLatency  = new Trend('cache_read_latency_ms', true);
const writeLatency = new Trend('cache_write_latency_ms', true);

// ─── Test Options ──────────────────────────────────────────────────────────────
export const options = {
  scenarios: {
    // Warm-up: populate cache with user data
    warmup: {
      executor: 'constant-vus',
      vus: 10,
      duration: '10s',
      tags: { scenario: 'warmup' },
    },
    // Sustained read/write mix
    sustained: {
      executor: 'constant-vus',
      vus: 50,
      duration: '60s',
      startTime: '10s',
      tags: { scenario: 'sustained' },
    },
  },
  thresholds: {
    // Cache reads must be fast
    cache_read_latency_ms: ['p(99)<200'],
    // Low error rate
    error_rate: ['rate<0.05'],
    // Both reads and writes succeed
    http_req_duration: ['p(95)<500'],
  },
};

// ─── Configuration ─────────────────────────────────────────────────────────────
const APP_URL = __ENV.APP_URL || 'http://localhost:8080';

// Pool of user IDs distributed across shards
// With 3 shards and CRC32:
//   user:1    -> shard varies by CRC32
//   user:100  -> shard varies by CRC32
// We use a large range to hit all shards
const USER_ID_MIN = 1;
const USER_ID_MAX = 10000;

function randomUserId() {
  return Math.floor(Math.random() * (USER_ID_MAX - USER_ID_MIN + 1)) + USER_ID_MIN;
}

// ─── Default Function ─────────────────────────────────────────────────────────
export default function () {
  const userId = randomUserId();
  const scenario = __ENV.SCENARIO || 'sustained';

  // 70% reads, 30% writes to simulate realistic cache usage
  const isRead = Math.random() < 0.7;

  if (isRead) {
    // ── Cache Read ──────────────────────────────────────────────────────────
    const readStart = Date.now();
    const res = http.get(`${APP_URL}/users/${userId}`, {
      tags: { name: 'get_user', operation: 'read' },
      timeout: '10s',
    });
    readLatency.add(Date.now() - readStart);

    const ok = check(res, {
      'read status is 200 or 404': (r) => r.status === 200 || r.status === 404,
    });

    errorRate.add(!ok);

    if (ok && res.status === 200) {
      // Check if response indicates cache hit
      try {
        const body = JSON.parse(res.body);
        const fromCache = body.cache === true || body.source === 'cache' || body.cached === true;
        if (fromCache) {
          cacheHits.add(1);
        } else {
          cacheMisses.add(1);
        }
      } catch (_) {
        cacheMisses.add(1);
      }
    } else if (!ok) {
      cacheErrors.add(1);
    }
  } else {
    // ── Cache Write ─────────────────────────────────────────────────────────
    const writeStart = Date.now();
    const payload = JSON.stringify({
      id: userId,
      name: `User ${userId}`,
      email: `user${userId}@example.com`,
      updated_at: new Date().toISOString(),
    });

    const res = http.put(`${APP_URL}/users/${userId}`, payload, {
      headers: { 'Content-Type': 'application/json' },
      tags: { name: 'update_user', operation: 'write' },
      timeout: '10s',
    });
    writeLatency.add(Date.now() - writeStart);

    const ok = check(res, {
      'write status is 200 or 204': (r) => r.status === 200 || r.status === 204 || r.status === 201,
    });

    errorRate.add(!ok);
    if (!ok) {
      cacheErrors.add(1);
    }
  }

  sleep(0.1);
}

// ─── Setup ────────────────────────────────────────────────────────────────────
export function setup() {
  console.log('=== Redis Sharding Load Test ===');
  console.log(`App URL      : ${APP_URL}`);
  console.log(`User ID range: ${USER_ID_MIN} - ${USER_ID_MAX}`);
  console.log(`Read ratio   : 70%`);
  console.log(`Write ratio  : 30%`);
  console.log('');
  console.log('After test, check shard distribution:');
  console.log('  for port in 6379 6380 6381; do');
  console.log('    echo "Port $port:"; redis-cli -p $port INFO keyspace; done');
  console.log('================================');

  // Pre-test connectivity
  const res = http.get(`${APP_URL}/health`, { timeout: '5s' });
  if (res.status !== 200) {
    console.warn(`WARNING: Pre-test /health check failed (status=${res.status})`);
  }

  return { appUrl: APP_URL };
}

// ─── Teardown ─────────────────────────────────────────────────────────────────
export function teardown(data) {
  console.log('\n=== Sharding Test Complete ===');
  console.log('');
  console.log('Key metrics to check:');
  console.log('  cache_hits         : Cache hit count (should increase during sustained load)');
  console.log('  cache_misses       : Cache miss count (high during warmup, low after)');
  console.log('  cache_read_latency : p99 should be < 200ms for Redis cache reads');
  console.log('  error_rate         : Should be near 0%');
  console.log('');
  console.log('Verify shard distribution with redis-cli:');
  for (let i = 0; i < 3; i++) {
    const port = 6379 + i;
    console.log(`  redis-cli -p ${port} INFO keyspace   # shard ${i}`);
  }
  console.log('');
  console.log('Expected: roughly equal key counts across all 3 shards (~33% each)');
  console.log('==============================');
}
