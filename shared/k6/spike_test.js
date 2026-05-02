// spike_test.js
// Simulates a sudden traffic spike to reveal how the service handles
// rapid scale-up and scale-down.
//
// Stages:
//   0 → 10 VUs  over 10 s  (warm-up)
//   10 → 200 VUs over 30 s  (spike)
//   200 → 10 VUs over 10 s  (recovery)
//   10 → 0 VUs  over 10 s  (wind-down)
//
// Run:
//   k6 run spike_test.js
//   k6 run -e BASE_URL=http://api.example.com spike_test.js

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const errorRate = new Rate('errors');

export const options = {
    stages: [
        { duration: '10s', target: 10  },   // warm-up
        { duration: '30s', target: 200 },   // spike
        { duration: '10s', target: 10  },   // recovery
        { duration: '10s', target: 0   },   // wind-down
    ],
    thresholds: {
        // 95th-percentile must stay under 500 ms even during the spike.
        http_req_duration: ['p(95)<500'],
        // No more than 5 % of requests may fail.
        http_req_failed: ['rate<0.05'],
        errors: ['rate<0.05'],
    },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export default function () {
    // ── GET /health ──────────────────────────────────────────────────────────
    const healthRes = http.get(`${BASE_URL}/health`, {
        tags: { name: 'Health' },
    });

    const healthOk = check(healthRes, {
        'GET /health status 200': (r) => r.status === 200,
        'GET /health latency < 500ms': (r) => r.timings.duration < 500,
    });
    errorRate.add(!healthOk);

    // ── GET /users/:id ───────────────────────────────────────────────────────
    const userId = Math.floor(Math.random() * 1_000_000) + 1;
    const getUserRes = http.get(`${BASE_URL}/users/${userId}`, {
        tags: { name: 'GetUser' },
    });

    const getUserOk = check(getUserRes, {
        'GET /users/:id status 200': (r) => r.status === 200,
        'GET /users/:id latency < 500ms': (r) => r.timings.duration < 500,
    });
    errorRate.add(!getUserOk);

    sleep(0.5);
}
