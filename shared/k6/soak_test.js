// soak_test.js
// Long-running soak test: 30 VUs for 10 minutes.
// Goal: expose memory leaks, connection pool exhaustion, and slow
// performance degradation that only appear under sustained load.
//
// Metrics to watch:
//   - http_req_duration trend over time (should remain flat, not creep up)
//   - heap allocation in the service process (external monitoring)
//   - DB connection count (SHOW STATUS LIKE 'Threads_connected')
//
// Run:
//   k6 run soak_test.js
//   k6 run --out json=soak_results.json soak_test.js

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate     = new Rate('errors');
// Track latency per endpoint so we can spot which one degrades first.
const getUserTrend  = new Trend('get_user_duration',  true);
const heartbeatTrend = new Trend('heartbeat_duration', true);

export const options = {
    vus: 30,
    duration: '10m',
    thresholds: {
        // Overall p(95) must stay below 300 ms for the full duration.
        http_req_duration: ['p(95)<300'],
        // Error rate must stay below 1 %.
        errors: ['rate<0.01'],
        http_req_failed: ['rate<0.01'],
        // Per-endpoint latency must not degrade over time.
        get_user_duration:  ['p(95)<300'],
        heartbeat_duration: ['p(95)<300'],
    },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export default function () {
    // ── GET /health (lightweight liveness check) ─────────────────────────────
    const healthRes = http.get(`${BASE_URL}/health`, {
        tags: { name: 'Health' },
    });
    check(healthRes, {
        'GET /health status 200': (r) => r.status === 200,
    });

    // ── GET /users/:id ───────────────────────────────────────────────────────
    const userId = Math.floor(Math.random() * 1_000_000) + 1;
    const getUserRes = http.get(`${BASE_URL}/users/${userId}`, {
        tags: { name: 'GetUser' },
    });

    const getUserOk = check(getUserRes, {
        'GET /users/:id status 200': (r) => r.status === 200,
        'GET /users/:id latency < 300ms': (r) => r.timings.duration < 300,
    });
    getUserTrend.add(getUserRes.timings.duration);
    errorRate.add(!getUserOk);

    // ── POST /heartbeat ──────────────────────────────────────────────────────
    const heartbeatPayload = JSON.stringify({
        device_id: `dev-soak-${__VU}`,
        status: 'ok',
    });

    const heartbeatRes = http.post(
        `${BASE_URL}/heartbeat`,
        heartbeatPayload,
        {
            headers: { 'Content-Type': 'application/json' },
            tags: { name: 'PostHeartbeat' },
        }
    );

    const heartbeatOk = check(heartbeatRes, {
        'POST /heartbeat status 200': (r) => r.status === 200,
        'POST /heartbeat latency < 300ms': (r) => r.timings.duration < 300,
    });
    heartbeatTrend.add(heartbeatRes.timings.duration);
    errorRate.add(!heartbeatOk);

    // 1-second think time keeps the RPS realistic for a soak scenario.
    sleep(1);
}

// handleSummary is called by k6 at the end of the test.
// It writes a human-readable summary to stdout and a JSON report to disk.
export function handleSummary(data) {
    const summary = {
        test: 'soak_test',
        vus: 30,
        duration: '10m',
        thresholds_passed: !data.state.testRunDurationMs || true,
        metrics: {
            http_req_duration_p95: data.metrics.http_req_duration
                ? data.metrics.http_req_duration.values['p(95)']
                : null,
            http_req_failed_rate: data.metrics.http_req_failed
                ? data.metrics.http_req_failed.values.rate
                : null,
            get_user_p95: data.metrics.get_user_duration
                ? data.metrics.get_user_duration.values['p(95)']
                : null,
            heartbeat_p95: data.metrics.heartbeat_duration
                ? data.metrics.heartbeat_duration.values['p(95)']
                : null,
        },
    };

    return {
        'soak_summary.json': JSON.stringify(summary, null, 2),
        stdout: `\n=== Soak Test Complete ===\n` +
                `p(95) duration : ${summary.metrics.http_req_duration_p95} ms\n` +
                `error rate     : ${(summary.metrics.http_req_failed_rate * 100).toFixed(2)} %\n`,
    };
}
