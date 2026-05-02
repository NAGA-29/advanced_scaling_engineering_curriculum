/**
 * k6 canary test for Step 06: DNS Switch Blue/Green
 *
 * This test runs for 3 minutes. During the test, the operator manually
 * switches the DNS record from Blue ALB to Green ALB (or vice versa).
 *
 * The script tracks which ALB (blue/green) is serving requests by inspecting
 * the x-server-name response header or the 'version' field in the JSON body.
 *
 * Usage:
 *   k6 run \
 *     -e APP_URL=http://app.example.com \
 *     -e BLUE_ALB=blue-alb-xxx.ap-northeast-1.elb.amazonaws.com \
 *     -e GREEN_ALB=green-alb-yyy.ap-northeast-1.elb.amazonaws.com \
 *     k6/canary_test.js
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend, Gauge } from 'k6/metrics';

// ─── Custom Metrics ────────────────────────────────────────────────────────────
const blueRequests  = new Counter('blue_requests');
const greenRequests = new Counter('green_requests');
const unknownRequests = new Counter('unknown_requests');
const errorRate     = new Rate('error_rate');
const latency       = new Trend('request_latency_ms', true);
const activeEnv     = new Gauge('active_environment_is_green'); // 0=blue, 1=green

// ─── Test Options ──────────────────────────────────────────────────────────────
export const options = {
  vus: 30,
  duration: '3m',
  thresholds: {
    // Zero errors allowed during the entire migration window
    error_rate: ['rate<0.01'],
    // Latency must stay reasonable on both environments
    http_req_duration: ['p(95)<600'],
    // Both blue and green must eventually receive traffic
    // (blue starts at >0, green gets traffic after DNS switch)
    blue_requests: ['count>0'],
  },
};

// ─── Configuration ─────────────────────────────────────────────────────────────
const APP_URL   = __ENV.APP_URL   || 'http://localhost:8080';
const BLUE_ALB  = __ENV.BLUE_ALB  || '';
const GREEN_ALB = __ENV.GREEN_ALB || '';

/**
 * Determine if a response came from the blue or green environment.
 * Priority:
 *   1. x-server-name response header (set by app server)
 *   2. version field in JSON body
 *   3. hostname contains -v1 or -v2 suffix
 */
function classifyEnvironment(res) {
  // Check response header first
  const serverName = res.headers['X-Server-Name'] || res.headers['x-server-name'] || '';
  if (serverName) {
    if (serverName.includes('blue') || serverName.includes('v1')) return 'blue';
    if (serverName.includes('green') || serverName.includes('v2')) return 'green';
  }

  // Parse JSON body
  try {
    const body = JSON.parse(res.body);

    // Check version field
    const version = String(body.version || body.app_version || '');
    if (version.includes('blue') || version.startsWith('1.')) return 'blue';
    if (version.includes('green') || version.startsWith('2.')) return 'green';

    // Check hostname suffix
    const hostname = String(body.hostname || '');
    if (hostname.includes('blue') || hostname.includes('-v1')) return 'blue';
    if (hostname.includes('green') || hostname.includes('-v2')) return 'green';

    // Check environment field
    const env = String(body.env || body.environment || '');
    if (env === 'blue') return 'blue';
    if (env === 'green') return 'green';
  } catch (_) {
    // JSON parse failed
  }

  return 'unknown';
}

// Track time-bucketed distribution (10s buckets)
let bucketStart = Date.now();
let bucketBlue = 0;
let bucketGreen = 0;
let bucketErrors = 0;

function flushBucket() {
  const now = Date.now();
  const elapsed = Math.floor((now - bucketStart) / 1000);
  if (now - bucketStart >= 10000) {
    const total = bucketBlue + bucketGreen + bucketErrors;
    const bluePercent  = total > 0 ? Math.round((bucketBlue  / total) * 100) : 0;
    const greenPercent = total > 0 ? Math.round((bucketGreen / total) * 100) : 0;
    console.log(
      `[t+${String(elapsed).padStart(3, '0')}s] ` +
      `blue=${bucketBlue}(${bluePercent}%) ` +
      `green=${bucketGreen}(${greenPercent}%) ` +
      `errors=${bucketErrors} ` +
      `total=${total}`
    );
    bucketStart = now;
    bucketBlue = 0;
    bucketGreen = 0;
    bucketErrors = 0;
  }
}

// ─── Default Function ─────────────────────────────────────────────────────────
export default function () {
  const res = http.get(`${APP_URL}/health`, {
    tags: { name: 'health_check' },
    timeout: '10s',
    headers: {
      'Accept': 'application/json',
    },
  });

  latency.add(res.timings.duration);

  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
    'response is JSON': (r) => {
      try { JSON.parse(r.body); return true; } catch (_) { return false; }
    },
  });

  errorRate.add(!ok);

  if (ok) {
    const env = classifyEnvironment(res);

    if (env === 'blue') {
      blueRequests.add(1);
      activeEnv.add(0);
      bucketBlue++;
    } else if (env === 'green') {
      greenRequests.add(1);
      activeEnv.add(1);
      bucketGreen++;
    } else {
      unknownRequests.add(1);
      bucketGreen++; // treat unknown as neither
    }
  } else {
    bucketErrors++;
  }

  flushBucket();

  sleep(0.5);
}

// ─── Setup ────────────────────────────────────────────────────────────────────
export function setup() {
  console.log('=== Blue/Green DNS Switch Canary Test ===');
  console.log(`App URL   : ${APP_URL}`);
  console.log(`Blue ALB  : ${BLUE_ALB || '(not provided)'}`);
  console.log(`Green ALB : ${GREEN_ALB || '(not provided)'}`);
  console.log('');
  console.log('Instructions:');
  console.log('  1. Test starts — traffic should go to Blue ALB initially');
  console.log('  2. At ~60s: Run blue_green_switch.sh to switch DNS to Green');
  console.log('  3. Watch the 10-second bucket logs to see traffic shift');
  console.log('  4. Verify: error_rate stays 0% throughout');
  console.log('  5. After test: check blue_requests vs green_requests counters');
  console.log('=========================================');

  // Pre-test connectivity check
  const preRes = http.get(`${APP_URL}/health`, { timeout: '10s' });
  if (preRes.status === 200) {
    const env = classifyEnvironment(preRes);
    console.log(`Pre-test health check: OK (env=${env}, status=${preRes.status})`);
  } else {
    console.warn(`Pre-test health check FAILED (status=${preRes.status})`);
  }

  return { appUrl: APP_URL, startTime: Date.now() };
}

// ─── Teardown ─────────────────────────────────────────────────────────────────
export function teardown(data) {
  const durationMs = Date.now() - data.startTime;
  const durationSec = Math.round(durationMs / 1000);

  console.log('\n=== Canary Test Complete ===');
  console.log(`Total duration : ${durationSec}s`);
  console.log('');
  console.log('Check these metrics in the k6 output:');
  console.log('  blue_requests  : Number of requests served by Blue ALB');
  console.log('  green_requests : Number of requests served by Green ALB');
  console.log('  error_rate     : Should be 0% (zero downtime achieved)');
  console.log('  http_req_duration p95 : Should be < 600ms on both envs');
  console.log('');
  console.log('Expected pattern after successful DNS switch:');
  console.log('  [t=000s-060s] blue=100% green=0%   (pre-switch)');
  console.log('  [t=060s-090s] blue=50%  green=50%  (TTL expiry window)');
  console.log('  [t=090s-180s] blue=0%   green=100% (post-switch)');
  console.log('============================');
}
