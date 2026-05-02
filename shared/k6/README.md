# k6 Load Tests

This directory contains three k6 test scripts used across the Advanced Scaling
Engineering Curriculum to observe how each service implementation behaves under
different traffic profiles.

## Prerequisites

Install k6 (v0.50+):

```bash
# macOS
brew install k6

# Linux (Debian/Ubuntu)
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
    --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
    | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install k6

# Docker (no install required)
docker run --rm -i grafana/k6 run - <script.js
```

## Test scripts

| Script | VUs | Duration | Purpose |
|---|---|---|---|
| `base_load_test.js` | 50 | 60 s | Baseline latency & error rate |
| `spike_test.js` | 0 → 200 → 0 | ~60 s | Rapid scale-up / recovery |
| `soak_test.js` | 30 | 10 min | Memory leaks, slow degradation |

## Running the tests

### Baseline load test

```bash
# Against local service (default BASE_URL=http://localhost:8080)
k6 run shared/k6/base_load_test.js

# Against a remote service
k6 run -e BASE_URL=http://api.example.com shared/k6/base_load_test.js
```

### Spike test

```bash
k6 run shared/k6/spike_test.js
k6 run -e BASE_URL=http://api.example.com shared/k6/spike_test.js
```

### Soak test

```bash
k6 run shared/k6/soak_test.js
```

## Exporting results

### JSON output (for post-processing / Grafana)

```bash
k6 run --out json=results/base_results.json shared/k6/base_load_test.js
```

The JSON file contains one object per data-point (metric sample), one per line
(newline-delimited JSON).  Example line:

```json
{"type":"Point","metric":"http_req_duration","data":{"time":"2025-01-01T12:00:00Z","value":42.1,"tags":{"name":"GetUser","status":"200"}}}
```

### CSV output

```bash
k6 run --out csv=results/base_results.csv shared/k6/base_load_test.js
```

### InfluxDB output (Grafana dashboards)

```bash
k6 run --out influxdb=http://localhost:8086/k6 shared/k6/base_load_test.js
```

### Saving the built-in end-of-test summary

```bash
k6 run --summary-export=results/summary.json shared/k6/base_load_test.js
```

## Key metrics to record

| Metric | Description | Target |
|---|---|---|
| `http_req_duration` p(50/95/99) | Latency percentiles | p(95) < 200 ms baseline |
| `http_req_failed` | % of non-2xx responses | < 1 % |
| `http_reqs` | Total request throughput (req/s) | Module-specific |
| `vus` | Concurrent virtual users over time | Matches scenario |
| `data_received` / `data_sent` | Bandwidth | Sanity-check |
| `errors` (custom) | Application-level check failures | < 1 % |
| `get_user_duration` p(95) | Endpoint-specific (soak) | < 300 ms |
| `heartbeat_duration` p(95) | Endpoint-specific (soak) | < 300 ms |

## Comparing results across modules

Run each module's service, execute the same test, and save the JSON summary:

```bash
# Module A
k6 run --summary-export=results/module_a_summary.json shared/k6/base_load_test.js

# Module B (after you have rebuilt the service)
k6 run --summary-export=results/module_b_summary.json shared/k6/base_load_test.js
```

Then compare `http_req_duration.p(95)` values between files to quantify
the improvement.
