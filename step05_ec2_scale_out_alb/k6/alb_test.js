/**
 * k6 load test for Step 05: EC2 Scale Out + ALB
 *
 * Tests:
 *   - Sustained load across ALB to verify round-robin distribution
 *   - Custom metric tracking unique hostnames per response
 *
 * Usage:
 *   k6 run -e ALB_URL=http://<alb-dns> k6/alb_test.js
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// ─── Custom Metrics ────────────────────────────────────────────────────────────
const hostnameCounter = {
  'app-01': new Counter('requests_to_app01'),
  'app-02': new Counter('requests_to_app02'),
  'unknown': new Counter('requests_to_unknown'),
};
const errorRate = new Rate('error_rate');
const httpLatency = new Trend('http_latency_ms', true);

// ─── Test Options ──────────────────────────────────────────────────────────────
export const options = {
  vus: 50,
  duration: '60s',
  thresholds: {
    // 99% of requests must complete within 500ms
    http_req_duration: ['p(99)<500'],
    // Error rate must stay below 1%
    error_rate: ['rate<0.01'],
    // Both instances should receive requests
    requests_to_app01: ['count>10'],
    requests_to_app02: ['count>10'],
  },
};

// ─── Helpers ───────────────────────────────────────────────────────────────────
const ALB_URL = __ENV.ALB_URL || 'http://localhost:8080';

function extractHostname(body) {
  try {
    const parsed = JSON.parse(body);
    return parsed.hostname || 'unknown';
  } catch (_) {
    return 'unknown';
  }
}

// ─── Default Function ─────────────────────────────────────────────────────────
export default function () {
  const healthUrl = `${ALB_URL}/health`;
  const usersUrl = `${ALB_URL}/users/1`;

  // ── Request 1: GET /health ─────────────────────────────────────────────────
  const healthRes = http.get(healthUrl, {
    tags: { name: 'health_check' },
    timeout: '10s',
  });

  httpLatency.add(healthRes.timings.duration);

  const healthOk = check(healthRes, {
    'health status is 200': (r) => r.status === 200,
    'health response has hostname': (r) => {
      try {
        const body = JSON.parse(r.body);
        return typeof body.hostname === 'string' && body.hostname.length > 0;
      } catch (_) {
        return false;
      }
    },
  });

  errorRate.add(!healthOk);

  // Track which instance served this request
  if (healthRes.status === 200) {
    const hostname = extractHostname(healthRes.body);
    if (hostname.includes('app-01') || hostname.endsWith('-01')) {
      hostnameCounter['app-01'].add(1);
    } else if (hostname.includes('app-02') || hostname.endsWith('-02')) {
      hostnameCounter['app-02'].add(1);
    } else {
      hostnameCounter['unknown'].add(1);
    }
  } else {
    errorRate.add(1);
  }

  sleep(0.3);

  // ── Request 2: GET /users/:id ──────────────────────────────────────────────
  const userRes = http.get(usersUrl, {
    tags: { name: 'get_user' },
    timeout: '10s',
  });

  httpLatency.add(userRes.timings.duration);

  const userOk = check(userRes, {
    'users status is 200 or 404': (r) => r.status === 200 || r.status === 404,
    'users response is JSON': (r) => {
      try {
        JSON.parse(r.body);
        return true;
      } catch (_) {
        return false;
      }
    },
  });

  errorRate.add(!userOk);

  sleep(0.2);
}

// ─── Setup: Print config ──────────────────────────────────────────────────────
export function setup() {
  console.log(`=== ALB Load Test ===`);
  console.log(`Target URL : ${ALB_URL}`);
  console.log(`VUs        : 50`);
  console.log(`Duration   : 60s`);
  console.log(`Thresholds : p99 < 500ms, error_rate < 1%`);
  console.log(`====================`);

  // Warm-up: verify ALB is reachable
  const res = http.get(`${ALB_URL}/health`);
  if (res.status !== 200) {
    console.warn(`WARNING: Pre-test health check failed (status=${res.status}). Proceeding anyway.`);
  } else {
    console.log(`Pre-test health check OK (status=200)`);
  }

  return { albUrl: ALB_URL };
}

// ─── Teardown: Print distribution summary ────────────────────────────────────
export function teardown(data) {
  console.log(`\n=== Distribution Summary ===`);
  console.log(`ALB URL : ${data.albUrl}`);
  console.log(`Note    : Check k6 output for requests_to_app01 / requests_to_app02 counters`);
  console.log(`Expected: roughly 50% each in steady state`);
  console.log(`============================`);
}
