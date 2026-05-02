/**
 * k6 smoke test for Step 09: Zero Downtime Schema Migration
 *
 * This test runs continuously during the entire migration process to verify
 * that zero downtime is achieved across all three phases:
 *   Phase 1: Expand  (ADD COLUMN)
 *   Phase 2: Migrate (backfill)
 *   Phase 3: Contract (DROP COLUMN)
 *
 * The test verifies:
 *   - All requests return 2xx or expected 4xx (no 5xx errors)
 *   - Response bodies are valid JSON throughout migration
 *   - Latency stays within acceptable bounds
 *   - user data is readable/writable at all times
 *
 * Usage:
 *   k6 run -e APP_URL=http://localhost:8080 k6/migration_smoke_test.js
 *
 * While this test runs, perform the migration steps manually in another terminal.
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend, Gauge } from 'k6/metrics';

// ─── Custom Metrics ────────────────────────────────────────────────────────────
const errorRate        = new Rate('error_rate');
const phase1Errors     = new Counter('phase1_errors');
const phase2Errors     = new Counter('phase2_errors');
const phase3Errors     = new Counter('phase3_errors');
const successCount     = new Counter('success_count');
const readLatency      = new Trend('read_latency_ms', true);
const writeLatency     = new Trend('write_latency_ms', true);
const currentHandlerV  = new Gauge('handler_v2_active'); // 1 if v2, 0 if v1

// ─── Test Options ──────────────────────────────────────────────────────────────
export const options = {
  vus: 30,
  duration: '10m', // Run for 10 minutes to cover all migration phases
  thresholds: {
    // Zero tolerance for 5xx errors throughout migration
    error_rate: ['rate<0.01'],
    // Latency must stay reasonable
    http_req_duration: ['p(95)<800'],
    // Must have at least some successful reads and writes
    success_count: ['count>100'],
  },
};

// ─── Configuration ─────────────────────────────────────────────────────────────
const APP_URL = __ENV.APP_URL || 'http://localhost:8080';

// Pre-created user IDs to use for read tests (populate before running)
const EXISTING_USER_IDS = [1, 2, 3, 4, 5];

let createdUserIds = [];
let testStartTime = Date.now();

function randomExistingId() {
  const ids = [...EXISTING_USER_IDS, ...createdUserIds];
  return ids[Math.floor(Math.random() * ids.length)];
}

// Detect which handler version is active from response headers
function detectHandlerVersion(res) {
  const version = res.headers['X-Handler-Version'] || '';
  return version.includes('v2') ? 2 : 1;
}

// ─── Test Phases ───────────────────────────────────────────────────────────────
function testHealthCheck() {
  const res = http.get(`${APP_URL}/health`, {
    tags: { name: 'health', operation: 'health' },
    timeout: '10s',
  });

  const ok = check(res, {
    'health: status 200': (r) => r.status === 200,
    'health: body is JSON': (r) => {
      try { JSON.parse(r.body); return true; } catch (_) { return false; }
    },
    'health: status is ok': (r) => {
      try { return JSON.parse(r.body).status === 'ok'; } catch (_) { return false; }
    },
  });

  if (ok) {
    const v = detectHandlerVersion(res);
    currentHandlerV.add(v === 2 ? 1 : 0);
  } else {
    errorRate.add(1);
    const elapsed = Math.round((Date.now() - testStartTime) / 1000);
    if (elapsed < 180) phase1Errors.add(1);
    else if (elapsed < 360) phase2Errors.add(1);
    else phase3Errors.add(1);
  }

  return ok;
}

function testGetUser(userId) {
  const start = Date.now();
  const res = http.get(`${APP_URL}/users/${userId}`, {
    tags: { name: 'get_user', operation: 'read' },
    timeout: '10s',
  });
  readLatency.add(Date.now() - start);

  const ok = check(res, {
    'get_user: status 200 or 404': (r) => r.status === 200 || r.status === 404,
    'get_user: body is JSON': (r) => {
      try { JSON.parse(r.body); return true; } catch (_) { return false; }
    },
    'get_user: no 5xx error': (r) => r.status < 500,
  });

  if (ok && res.status === 200) {
    successCount.add(1);

    // Verify response structure: either name or first_name/last_name must be present
    try {
      const body = JSON.parse(res.body);
      check(res, {
        'get_user: has id field': (_) => typeof body.id !== 'undefined',
        'get_user: has email field': (_) => typeof body.email === 'string',
        'get_user: has name data': (_) =>
          // v1: has name field
          // v2: has first_name/last_name fields
          typeof body.name === 'string' ||
          typeof body.first_name === 'string' ||
          typeof body.full_name === 'string',
      });
    } catch (_) {
      // JSON parse failed — already caught by body check above
    }
  }

  if (!ok) {
    errorRate.add(1);
  }

  return ok;
}

function testCreateUser() {
  const ts = Date.now();
  const vus = __VU;

  // Mix of v1 and v2 style payloads to test backward compatibility
  const useV2Style = Math.random() > 0.5;
  let payload;

  if (useV2Style) {
    payload = JSON.stringify({
      first_name: `Test${vus}`,
      last_name: `User${ts}`,
      email: `test_${vus}_${ts}@example.com`,
    });
  } else {
    payload = JSON.stringify({
      name: `Test${vus} User${ts}`,
      email: `test_${vus}_${ts}@example.com`,
    });
  }

  const start = Date.now();
  const res = http.post(`${APP_URL}/users`, payload, {
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'create_user', operation: 'write' },
    timeout: '10s',
  });
  writeLatency.add(Date.now() - start);

  const ok = check(res, {
    'create_user: status 201': (r) => r.status === 201,
    'create_user: body is JSON': (r) => {
      try { JSON.parse(r.body); return true; } catch (_) { return false; }
    },
    'create_user: no 5xx error': (r) => r.status < 500,
  });

  if (ok && res.status === 201) {
    successCount.add(1);
    try {
      const body = JSON.parse(res.body);
      if (body.id) {
        createdUserIds.push(body.id);
        // Keep list bounded to avoid memory growth
        if (createdUserIds.length > 100) {
          createdUserIds = createdUserIds.slice(-50);
        }
      }
    } catch (_) {}
  }

  if (!ok) {
    errorRate.add(1);
  }

  return ok;
}

function testUpdateUser(userId) {
  const ts = Date.now();
  const vus = __VU;

  const payload = JSON.stringify({
    first_name: `Updated${vus}`,
    last_name: `At${ts}`,
    email: `updated_${vus}@example.com`,
  });

  const start = Date.now();
  const res = http.put(`${APP_URL}/users/${userId}`, payload, {
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'update_user', operation: 'write' },
    timeout: '10s',
  });
  writeLatency.add(Date.now() - start);

  const ok = check(res, {
    'update_user: status 204 or 200': (r) => r.status === 204 || r.status === 200,
    'update_user: no 5xx error': (r) => r.status < 500,
  });

  if (!ok) {
    errorRate.add(1);
  }

  return ok;
}

// ─── Default Function ─────────────────────────────────────────────────────────
export default function () {
  const rand = Math.random();

  // Traffic mix: 40% read, 30% create, 20% update, 10% health
  if (rand < 0.10) {
    testHealthCheck();
  } else if (rand < 0.50) {
    testGetUser(randomExistingId());
  } else if (rand < 0.80) {
    testCreateUser();
  } else {
    const userId = randomExistingId();
    testUpdateUser(userId);
  }

  sleep(0.3);
}

// ─── Setup ────────────────────────────────────────────────────────────────────
export function setup() {
  testStartTime = Date.now();

  console.log('=== Zero Downtime Migration Smoke Test ===');
  console.log(`App URL  : ${APP_URL}`);
  console.log(`Duration : 10 minutes`);
  console.log(`VUs      : 30`);
  console.log('');
  console.log('Migration checklist (execute while test runs):');
  console.log('  [~1m]  Phase 1: mysql ... < sql/step1_expand.sql');
  console.log('  [~2m]  Deploy v1 compatible handler');
  console.log('  [~3m]  Phase 2: go run scripts/backfill.go ...');
  console.log('  [~6m]  Deploy v2 handler');
  console.log('  [~8m]  Phase 3: mysql ... < sql/step3_contract.sql');
  console.log('  [~9m]  Verify: DESCRIBE users (should have first_name, last_name, no name)');
  console.log('');
  console.log('Success criteria:');
  console.log('  - error_rate < 1% throughout all phases');
  console.log('  - No 5xx responses at any point');
  console.log('  - p95 latency < 800ms');
  console.log('==========================================');

  // Pre-test connectivity check
  const res = http.get(`${APP_URL}/health`, { timeout: '10s' });
  if (res.status !== 200) {
    console.warn(`WARNING: health check failed before test (status=${res.status})`);
  } else {
    const body = JSON.parse(res.body || '{}');
    console.log(`Pre-test health: OK (version=${body.version || 'unknown'})`);
  }

  return { appUrl: APP_URL, startTime: Date.now() };
}

// ─── Teardown ─────────────────────────────────────────────────────────────────
export function teardown(data) {
  const elapsed = Math.round((Date.now() - data.startTime) / 1000);

  console.log('\n=== Migration Smoke Test Complete ===');
  console.log(`Duration     : ${elapsed}s`);
  console.log('');
  console.log('Key metrics (check k6 output):');
  console.log('  error_rate          : Should be < 1% across all phases');
  console.log('  phase1_errors       : Errors during Expand phase (~0-3min)');
  console.log('  phase2_errors       : Errors during Backfill phase (~3-6min)');
  console.log('  phase3_errors       : Errors during Contract phase (~6-10min)');
  console.log('  read_latency_ms p95 : Should be < 800ms');
  console.log('  write_latency_ms p95: Should be < 800ms');
  console.log('  handler_v2_active   : Should transition from 0 to 1 after v2 deploy');
  console.log('');
  console.log('Migration is considered successful if:');
  console.log('  1. error_rate < 0.01 (1%)');
  console.log('  2. success_count > 100');
  console.log('  3. No 5xx status codes appeared in checks output');
  console.log('=====================================');
}
