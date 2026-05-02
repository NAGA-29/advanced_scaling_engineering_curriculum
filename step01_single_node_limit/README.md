# STEP 01: EC2 1台 + MySQL 1台の限界を知る

## 目的

単一 EC2 インスタンスと MySQL が同居する構成の性能上限を計測し、  
「なぜスケールアウトが必要か」を体感する。  
- p95 レイテンシが Index なし時にどれだけ劣化するかを数値で把握する
- slow query log, DB CPU, connection 数を観測し、ボトルネックを特定する
- Index あり / なし の両ケースで k6 負荷テストを実施して比較する

---

## 構成

```
[ローカル PC / k6]
      │ HTTP GET /users/:id
      │ HTTP GET /users?tenant_id=...
      ▼
[EC2 t3.micro]
  ├── Go/Echo API (port 8080, systemd: go-echo-api.service)
  └── MySQL 8.0   (port 3306, systemd: mysqld.service)
        ├── appdb.users (100,000 rows)
        └── appdb.tenants
```

| リソース | 値 |
|---------|-----|
| EC2 | t3.micro (2 vCPU, 1 GB RAM) |
| MySQL | 8.0, 同一 EC2 内 |
| データ量 | users 100,000 件, tenants 10 件 |
| API | Go/Echo, DB connection pool max 25 |

---

## 成果物

```
step01_single_node_limit/
├── README.md              # このファイル
├── k6/
│   ├── load_test.js       # k6 負荷テストスクリプト
│   └── README.md          # テスト実行方法と観測項目
└── mysql/
    └── setup.sql          # テーブル・シードデータ・slow query 設定
```

---

## 前提条件

- STEP 00 が完了し、EC2 + MySQL が起動していること
- k6 がローカル PC にインストールされていること
- `EC2_IP` 環境変数に EC2 のパブリック IP が設定されていること

```bash
# k6 インストール確認
k6 version

# EC2 IP 設定
export EC2_IP=$(cd ../step00_terraform_base && terraform output -raw public_ip)
echo "EC2_IP=${EC2_IP}"

# API 疎通確認
curl -s http://${EC2_IP}:8080/health
# {"status":"ok"}
```

---

## 実行手順

### 1. MySQL にテスト用データを投入

```bash
# EC2 に SSH
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP}

# MySQL に接続して setup.sql を実行
mysql -u apiuser -papipassword appdb < /dev/stdin <<'SQL'
-- step01/mysql/setup.sql の内容をここに貼るか、ファイルを転送して実行
SQL

# または SCP でファイル転送
scp -i ~/.ssh/scaling-key.pem mysql/setup.sql ec2-user@${EC2_IP}:/tmp/
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb < /tmp/setup.sql"
```

### 2. データ件数を確認

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb -e 'SELECT COUNT(*) FROM users; SELECT COUNT(*) FROM tenants;'"
```

期待出力:
```
+----------+
| COUNT(*) |
+----------+
|   100000 |
+----------+
+----------+
| COUNT(*) |
+----------+
|       10 |
+----------+
```

### 3. Index あり状態で負荷テスト（ベースライン）

```bash
cd step01_single_node_limit
k6 run -e EC2_IP=${EC2_IP} k6/load_test.js
```

結果をメモしておく（p50/p95/p99/rps）。

### 4. Index を削除して再テスト

```bash
# Index を削除
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb -e 'ALTER TABLE users DROP INDEX idx_users_tenant_id;'"

# 再度負荷テスト
k6 run -e EC2_IP=${EC2_IP} k6/load_test.js
```

劣化を確認する。

### 5. Slow Query ログを確認

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP}
sudo tail -50 /var/log/mysql/slow.log
```

### 6. Index を戻して復旧

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb -e 'ALTER TABLE users ADD INDEX idx_users_tenant_id (tenant_id);'"
```

---

## 確認方法

### API レスポンスの確認

```bash
# 単一ユーザー取得
curl -s http://${EC2_IP}:8080/users/1 | jq .

# テナント別ユーザー一覧（インデックスが効くクエリ）
curl -s "http://${EC2_IP}:8080/users?tenant_id=tenant-001" | jq '. | length'
```

### MySQL の状態確認

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} bash << 'EOF'
mysql -u apiuser -papipassword appdb << 'MYSQL'
-- コネクション数
SHOW STATUS LIKE 'Threads_connected';
SHOW STATUS LIKE 'Max_used_connections';

-- スロークエリ件数
SHOW STATUS LIKE 'Slow_queries';

-- 現在実行中のクエリ
SHOW PROCESSLIST;

-- テーブルのインデックス確認
SHOW INDEX FROM users;
MYSQL
EOF
```

### CPU / メモリ確認（EC2 内）

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "top -bn1 | head -20; free -m"
```

### CloudWatch メトリクス確認（オプション）

```bash
# EC2 CPU 使用率（過去 5 分）
INSTANCE_ID=$(cd ../step00_terraform_base && terraform output -raw instance_id)
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=${INSTANCE_ID} \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Average \
  --output table
```

---

## 壊す手順

### 課題 1: Index を外して検索を遅くする

```bash
# users テーブルの tenant_id インデックスを削除
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} bash << 'EOF'
mysql -u apiuser -papipassword appdb << 'MYSQL'
-- インデックスを削除
ALTER TABLE users DROP INDEX idx_users_tenant_id;
ALTER TABLE users DROP INDEX idx_users_status;

-- EXPLAIN で Full Table Scan を確認
EXPLAIN SELECT * FROM users WHERE tenant_id = 'tenant-001';
-- type: ALL, key: NULL, rows: ~100000 になること

EXPLAIN SELECT id FROM users WHERE tenant_id = 'tenant-001' LIMIT 10;
MYSQL
EOF

# 負荷テストを再実行して劣化を確認
k6 run -e EC2_IP=${EC2_IP} k6/load_test.js
```

**期待される変化**:
- p95 latency: < 20ms → > 500ms に悪化
- RPS: 大幅に低下
- EC2 CPU: 高騰
- `SHOW STATUS LIKE 'Slow_queries'` のカウントが増加

### 課題 2: MySQL の max_connections を下げる

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "sudo mysql -u root -e 'SET GLOBAL max_connections = 5;'"

# k6 で負荷をかける（接続エラーが発生することを確認）
k6 run --vus 20 -e EC2_IP=${EC2_IP} k6/load_test.js
```

**期待される変化**:
- `Too many connections` エラーが発生
- Error Rate が上昇

### 課題 3: API のコネクションプールを使い果たす

```bash
# 接続数を確認しながら高負荷をかける
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "watch -n1 'mysql -u apiuser -papipassword -e \"SHOW STATUS LIKE \\\"Threads_connected\\\";\"'"
```

別ターミナルで:
```bash
k6 run --vus 100 --duration 30s -e EC2_IP=${EC2_IP} k6/load_test.js
```

---

## 復旧手順

### Index を戻す

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} bash << 'EOF'
mysql -u apiuser -papipassword appdb << 'MYSQL'
ALTER TABLE users ADD INDEX idx_users_tenant_id (tenant_id);
ALTER TABLE users ADD INDEX idx_users_status (status);

-- インデックスが復活したことを確認
SHOW INDEX FROM users;

-- EXPLAIN で ref になることを確認
EXPLAIN SELECT * FROM users WHERE tenant_id = 'tenant-001';
MYSQL
EOF
```

### max_connections を戻す

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "sudo mysql -u root -e 'SET GLOBAL max_connections = 151;'"
```

### API サービスを再起動

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "sudo systemctl restart go-echo-api && sudo systemctl status go-echo-api"
```

---

## 削除手順

STEP 01 は STEP 00 のインフラを流用するため、独自の AWS リソースはない。  
データのみをリセットする場合:

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb -e 'TRUNCATE TABLE users; TRUNCATE TABLE tenants;'"
```

インフラを削除する場合は STEP 00 の手順に従う:

```bash
cd ../step00_terraform_base
terraform destroy
```

---

## 学び

| 項目 | 学んだこと |
|------|-----------|
| Index の威力 | tenant_id に Index がないと 100,000 件の Full Table Scan が発生し、レイテンシが 10〜50x 悪化する |
| p95/p99 の意味 | 平均は良くても p99 が高ければ一部ユーザーが極端に遅い体験をする |
| Slow Query Log | `long_query_time = 1` 以上のクエリをログに記録し、ボトルネック特定に使う |
| Connection Pool | アプリ側の pool size が MySQL の max_connections を超えると接続エラーになる |
| 単一ノードの限界 | 1 台の EC2 + MySQL では CPU, メモリ, I/O のいずれかが先に限界に達する |
| EXPLAIN の重要性 | `type: ALL` は危険信号。`type: ref` や `type: const` を目指す |

---

## k6 負荷テスト

### 実行コマンド

```bash
# Index あり（ベースライン）
k6 run -e EC2_IP=${EC2_IP} k6/load_test.js

# Index なし（壊した状態）
ssh ... "mysql ... 'ALTER TABLE users DROP INDEX idx_users_tenant_id;'"
k6 run -e EC2_IP=${EC2_IP} k6/load_test.js
```

### 期待結果比較表

| メトリクス | Index あり | Index なし | 比率 |
|-----------|-----------|-----------|------|
| p50 latency | < 5ms | 50〜200ms | 10〜40x 悪化 |
| p95 latency | < 20ms | 500ms〜2s | 25〜100x 悪化 |
| p99 latency | < 50ms | 1s〜5s | 20〜100x 悪化 |
| Error Rate | < 0.1% | 1〜10% | タイムアウト発生 |
| RPS | 300〜500 | 20〜50 | 6〜15x 低下 |

> **環境**: t3.micro, 100,000 件, 50 VUs, 60 秒間

### テスト構成

- **VUs**: 50
- **Duration**: 60 秒
- **エンドポイント**: `GET /users/:id` (70%) + `GET /users?tenant_id=...` (30%)
- **成功条件**: `status == 200`, `http_req_duration < 200ms`

詳細は [k6/README.md](./k6/README.md) を参照。
