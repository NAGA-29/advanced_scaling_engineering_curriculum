// base_load_test.js
// Baseline load test: 50 VUs for 60 seconds.
// Exercises the two most common endpoints: GET /users/:id and POST /heartbeat.
//
// Run:
//   k6 run base_load_test.js
//   k6 run -e BASE_URL=http://api.example.com base_load_test.js

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

// Custom metric: track the overall error rate separately from k6 built-ins.
const errorRate = new Rate('errors');

export const options = {
    vus: 50,
    duration: '60s',
    thresholds: {
        // 95 % of requests must finish below 200 ms.
        http_req_duration: ['p(95)<200'],
        // Less than 1 % of requests may fail.
        errors: ['rate<0.01'],
    },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export default function () {
    // ── GET /users/:id ───────────────────────────────────────────────────────
    const userId = Math.floor(Math.random() * 1_000_000) + 1;
    const getUserRes = http.get(`${BASE_URL}/users/${userId}`, {
        tags: { name: 'GetUser' },
    });

    const getUserOk = check(getUserRes, {
        'GET /users/:id status 200': (r) => r.status === 200,
        'GET /users/:id latency < 200ms': (r) => r.timings.duration < 200,
    });
    errorRate.add(!getUserOk);

    // ── POST /heartbeat ──────────────────────────────────────────────────────
    const heartbeatPayload = JSON.stringify({
        device_id: `dev-load-${__VU}`,
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
        'POST /heartbeat latency < 200ms': (r) => r.timings.duration < 200,
    });
    errorRate.add(!heartbeatOk);

    sleep(1);
}
