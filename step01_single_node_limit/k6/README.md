# STEP 01 k6 負荷テスト

## 概要

`load_test.js` は EC2 1台 + MySQL 1台の構成で、以下の 2 パターンのリクエストを混在させて性能限界を計測する。

| パターン | 割合 | エンドポイント | 説明 |
|---------|------|--------------|------|
| A | 70% | `GET /users/:id` | Primary Key 検索（Index あり） |
| B | 30% | `GET /users?tenant_id=...` | テナント別一覧（Index あり / なしで比較） |

---

## 前提条件

```bash
# k6 がインストールされていること
k6 version
# k6 v0.50.0 以上を推奨

# EC2_IP 環境変数が設定されていること
export EC2_IP=<EC2のパブリックIP>

# MySQL にデータが投入されていること（users 100,000 件）
curl -s http://${EC2_IP}:8080/users/1 | jq .
# {"id":1,"tenant_id":"tenant-001",...} が返ること
```

---

## 実行方法

### 基本実行

```bash
cd step01_single_node_limit
k6 run -e EC2_IP=${EC2_IP} k6/load_test.js
```

### VUs / Duration を変えて実行

```bash
# 軽めのテスト（動作確認）
k6 run --vus 10 --duration 30s -e EC2_IP=${EC2_IP} k6/load_test.js

# 標準テスト（ベースライン計測）
k6 run --vus 50 --duration 60s -e EC2_IP=${EC2_IP} k6/load_test.js

# 高負荷テスト（限界確認）
k6 run --vus 200 --duration 60s -e EC2_IP=${EC2_IP} k6/load_test.js
```

### JSON 形式で結果を保存

```bash
k6 run \
  --vus 50 \
  --duration 60s \
  --out json=results_with_index.json \
  -e EC2_IP=${EC2_IP} \
  k6/load_test.js
```

---

## 観測項目

テスト実行中は別ターミナルで以下を監視する。

### 1. API ログ（EC2 内）

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "sudo journalctl -u go-echo-api -f"
```

### 2. MySQL 状態

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "watch -n2 'mysql -u apiuser -papipassword appdb -e \
    \"SHOW STATUS LIKE \\\"Threads_connected\\\"; \
     SHOW STATUS LIKE \\\"Slow_queries\\\"; \
     SHOW STATUS LIKE \\\"Questions\\\";\"'"
```

### 3. EC2 リソース使用率

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "watch -n2 'top -bn1 | head -15'"
```

### 4. Slow Query ログ

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "sudo tail -f /var/log/mysql/slow.log"
```

---

## Index あり / なし の比較実験手順

### ステップ 1: Index あり でベースライン計測

```bash
k6 run --vus 50 --duration 60s \
  --out json=results_with_index.json \
  -e EC2_IP=${EC2_IP} k6/load_test.js
```

### ステップ 2: Index を削除

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb -e \
    'ALTER TABLE users DROP INDEX idx_users_tenant_id; \
     ALTER TABLE users DROP INDEX idx_users_status;'"
```

### ステップ 3: Index なし で再計測

```bash
k6 run --vus 50 --duration 60s \
  --out json=results_without_index.json \
  -e EC2_IP=${EC2_IP} k6/load_test.js
```

### ステップ 4: Index を復元

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb -e \
    'ALTER TABLE users ADD INDEX idx_users_tenant_id (tenant_id); \
     ALTER TABLE users ADD INDEX idx_users_status (status);'"
```

---

## 期待される結果

### Index あり（正常状態）

| メトリクス | 期待値 |
|-----------|--------|
| p50 latency | < 5ms |
| p95 latency | < 20ms |
| p99 latency | < 50ms |
| Error Rate | < 0.1% |
| RPS | 300〜500 req/s |
| EC2 CPU | 30〜50% |
| MySQL Threads Connected | < 30 |

### Index なし（壊した状態）

| メトリクス | 期待値 |
|-----------|--------|
| p50 latency | 50〜300ms |
| p95 latency | 500ms〜2s |
| p99 latency | 1s〜5s |
| Error Rate | 1〜10% (タイムアウト) |
| RPS | 20〜80 req/s（大幅低下）|
| EC2 CPU | 80〜100% |
| MySQL Threads Connected | 増加・詰まり |

---

## k6 出力の読み方

```
     checks.........................: 98.52% ✓ 29556  ✗ 444
     data_received..................: 12 MB  198 kB/s
     data_sent......................: 2.7 MB 44 kB/s
     error_rate.....................: 0.01%  ✓ 30000  ✗ 3
     get_user_latency...............: avg=3.2ms  min=0.5ms  med=2.1ms  max=98.3ms  p(90)=7.2ms  p(95)=12.4ms
     http_req_duration..............: avg=5.1ms  min=0.4ms  med=3.3ms  max=254.1ms p(90)=12.8ms p(95)=21.4ms
   ✓ http_req_duration.............: p(95)<200  ← しきい値クリア
     http_reqs......................: 30003  499.9/s
     list_users_latency.............: avg=9.8ms  min=1.2ms  med=7.4ms  max=312ms   p(90)=22.3ms p(95)=38.1ms
     vus............................: 50     min=50    max=50
```

| フィールド | 説明 |
|-----------|------|
| `checks` | `check()` 関数で定義した条件の成功率 |
| `http_req_duration` | リクエスト全体のレイテンシ分布 |
| `http_reqs` | 総リクエスト数 / RPS |
| `get_user_latency` | カスタムトレンド（パターン A のみ） |
| `list_users_latency` | カスタムトレンド（パターン B のみ） |
| `✓` / `✗` | しきい値クリア / 違反 |

---

## トラブルシューティング

### エラー: `dial: connection refused`

```bash
# API が起動しているか確認
curl http://${EC2_IP}:8080/health
ssh ... "sudo systemctl status go-echo-api"
```

### エラー: `request timeout`

- EC2 の Security Group で 8080 番が開いているか確認
- MySQL が起動しているか確認: `sudo systemctl status mysqld`

### k6 が `WARN[XXXXX]` を出す

- `WARN[...] Request Failed` が多い場合はサーバー側が過負荷
- VUs を減らして再実行する
