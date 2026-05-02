# STEP 03: Read Replica で読み負荷を分散する

## 目的

MySQL の Read Replica を導入し、読み込みリクエストを Primary から逃がすことで  
Primary の負荷を軽減し、書き込み性能への影響を最小化する。

- Primary（書き込み）と Replica（読み込み）を Go アプリで切り替える仕組みを実装する
- Replica Lag（レプリケーション遅延）が何であるか・どう監視するかを学ぶ
- Replica が停止した場合の Fallback（Primary へのフォールバック）を実装する
- ローカル検証用の Docker Compose で Primary + Replica 環境を再現する

---

## 構成

```
[クライアント / k6]
        │
        ▼
[Go/Echo API]
   │           │
   │ Write     │ Read (SELECT)
   ▼           ▼
[MySQL         [MySQL
 Primary]       Replica]
  port 3307      port 3308
  (書き込み)      (読み込み)
        ↑
        │ Binary Log レプリケーション
        └──────────────────────────

Replica が停止した場合 → Primary にフォールバック
```

| リソース | 値 |
|---------|-----|
| MySQL Primary | port 3307 (Docker) / RDS Multi-AZ Primary |
| MySQL Replica | port 3308 (Docker) / RDS Read Replica |
| アプリ | Go/Echo, DBCluster で Read/Write 分離 |
| Replica Lag | `SHOW REPLICA STATUS` で確認 |

---

## 成果物

```
step03_read_replica/
├── README.md
├── app/
│   └── db_resolver.go       # Read/Write DB 分離ロジック
├── docker-compose.yml       # ローカル MySQL Primary + Replica 環境
└── k6/
    └── replica_test.js      # 読み負荷テスト（80% read, 20% write）
```

---

## 前提条件

### ローカル Docker 検証の場合

```bash
# Docker / Docker Compose がインストールされていること
docker --version    # 20.x 以上
docker compose version  # v2.x 以上
```

### AWS RDS の場合

- STEP 00 のインフラが起動していること
- RDS MySQL 8.0 インスタンスが作成済み
- RDS Read Replica が作成済み
- EC2 から RDS エンドポイントへのアクセスが SG で許可されていること

---

## 実行手順

### ローカル Docker での検証手順

#### 1. Docker Compose でローカル環境を起動

```bash
cd step03_read_replica
docker compose up -d

# 起動確認（全コンテナが healthy になるまで 1〜2 分待つ）
docker compose ps
```

期待出力:
```
NAME                     STATUS
mysql-primary            running (healthy)
mysql-replica            running (healthy)
mysql-replica-init       exited (0)    ← 正常終了
```

#### 2. Primary にデータを投入

```bash
# Primary に接続
docker exec -it mysql-primary mysql -u apiuser -papipassword appdb

# データ確認
mysql> SELECT COUNT(*) FROM users;
```

#### 3. Replica にデータが同期されていることを確認

```bash
docker exec -it mysql-replica mysql -u apiuser -papipassword appdb \
  -e "SELECT COUNT(*) FROM users;"
# Primary と同じ件数であること

# Replica のレプリケーション状態を確認
docker exec -it mysql-replica mysql -u root -prootpassword \
  -e "SHOW REPLICA STATUS\G" | grep -E "Seconds_Behind|Running|Error"
```

期待出力:
```
Replica_IO_Running: Yes
Replica_SQL_Running: Yes
Seconds_Behind_Source: 0
```

#### 4. Go アプリのビルドと起動

```bash
cd app
go mod init step03-read-replica
go get github.com/go-sql-driver/mysql@v1.8.1
go build -o db_resolver_demo .
```

#### 5. アプリから Replica への読み込みを確認

```bash
# 環境変数で接続先を指定
DB_PRIMARY_HOST=127.0.0.1 \
DB_PRIMARY_PORT=3307 \
DB_REPLICA_HOST=127.0.0.1 \
DB_REPLICA_PORT=3308 \
DB_USER=apiuser \
DB_PASSWORD=apipassword \
DB_NAME=appdb \
./db_resolver_demo
```

---

## 確認方法

### Replica Lag の確認

```bash
# Replica コンテナ内で確認
docker exec -it mysql-replica mysql -u root -prootpassword \
  -e "SHOW REPLICA STATUS\G" | grep -E "Seconds_Behind|Running|Pos"
```

| フィールド | 意味 |
|-----------|------|
| `Seconds_Behind_Source` | レプリケーション遅延（秒）。0 が理想 |
| `Replica_IO_Running` | Binary Log 受信スレッドが動作中か |
| `Replica_SQL_Running` | SQL 適用スレッドが動作中か |
| `Read_Source_Log_Pos` | Primary のどの位置まで読んだか |
| `Exec_Source_Log_Pos` | Replica がどこまで適用したか |

### 書き込みが Primary にだけ反映されることを確認

```bash
# Primary にデータを挿入
docker exec mysql-primary mysql -u apiuser -papipassword appdb \
  -e "INSERT INTO users (tenant_id, name, email) VALUES ('tenant-001', 'test', 'test_replica@example.com');"

# Replica で確認（1〜2 秒後に反映される）
sleep 2
docker exec mysql-replica mysql -u apiuser -papipassword appdb \
  -e "SELECT id, name, email FROM users WHERE email = 'test_replica@example.com';"
```

### Fallback の確認

```bash
# Replica を停止
docker compose stop mysql-replica

# アプリが Primary にフォールバックしていることをログで確認
# "[WARN] replica unavailable, falling back to primary" が出力されること
```

---

## 壊す手順

### 課題 1: Replica を停止して Fallback を確認する

```bash
# Replica を停止
docker compose stop mysql-replica

# k6 で読み負荷テストを実行
k6 run -e PRIMARY_HOST=127.0.0.1 \
       -e PRIMARY_PORT=3307 \
       -e REPLICA_PORT=3308 \
       k6/replica_test.js

# アプリログで "fallback to primary" が出力されることを確認
# エラーレートが 0% を維持することを確認（Fallback が成功している証拠）
```

### 課題 2: Replica を停止してから再起動し、データが追いつくことを確認する

```bash
# Replica 停止中に Primary に大量書き込み
for i in $(seq 1 100); do
  docker exec mysql-primary mysql -u apiuser -papipassword appdb \
    -e "INSERT INTO users (tenant_id, name, email) VALUES ('tenant-001', 'lag_test_${i}', 'lag${i}@example.com');"
done

# Replica を再起動
docker compose start mysql-replica

# Seconds_Behind_Source が増加してから 0 に戻ることを観察
watch -n1 "docker exec mysql-replica mysql -u root -prootpassword -e \"SHOW REPLICA STATUS\G\" 2>/dev/null | grep Seconds_Behind"
```

### 課題 3: Replica に書き込みしようとして拒否されることを確認する

```bash
docker exec mysql-replica mysql -u apiuser -papipassword appdb \
  -e "INSERT INTO users (tenant_id, name, email) VALUES ('tenant-001', 'write_to_replica', 'fail@example.com');"
# ERROR 1290 (HY000): The MySQL server is running with the --read-only option
```

---

## 復旧手順

### Replica を再起動する

```bash
docker compose start mysql-replica

# レプリケーション状態が復旧することを確認
watch -n2 "docker exec mysql-replica mysql -u root -prootpassword \
  -e 'SHOW REPLICA STATUS\G' 2>/dev/null | grep -E 'Running|Seconds_Behind'"
```

期待出力（復旧後）:
```
Replica_IO_Running: Yes
Replica_SQL_Running: Yes
Seconds_Behind_Source: 0
```

### レプリケーションエラーが発生した場合

```bash
# エラー内容を確認
docker exec mysql-replica mysql -u root -prootpassword \
  -e "SHOW REPLICA STATUS\G" | grep -E "Error|Errno"

# エラーをスキップして再開（1 件のエラーをスキップ）
docker exec mysql-replica mysql -u root -prootpassword \
  -e "STOP REPLICA; SET GLOBAL SQL_SLAVE_SKIP_COUNTER = 1; START REPLICA;"

# または完全リセット（データ再同期）
docker compose down -v
docker compose up -d
```

---

## 削除手順

### Docker 環境の削除

```bash
cd step03_read_replica

# コンテナとボリュームを削除
docker compose down -v

# イメージも削除する場合
docker compose down -v --rmi all

# 確認
docker ps -a | grep mysql
docker volume ls | grep step03
```

### AWS RDS 環境の削除（RDS を使用した場合）

```bash
# Read Replica の削除
aws rds delete-db-instance \
  --db-instance-identifier scaling-step03-replica \
  --skip-final-snapshot

# Primary の削除
aws rds delete-db-instance \
  --db-instance-identifier scaling-step03-primary \
  --skip-final-snapshot

# 削除完了を待つ
aws rds wait db-instance-deleted \
  --db-instance-identifier scaling-step03-primary
```

---

## 学び

| 項目 | 学んだこと |
|------|-----------|
| Read/Write 分離 | SELECT は Replica、INSERT/UPDATE/DELETE は Primary に向けることで Primary の CPU を節約 |
| Replica Lag | ネットワーク遅延・Replica の処理能力・大量書き込みが Lag の原因。`Seconds_Behind_Source` で監視 |
| 結果整合性 | Lag がある間は Replica の読み取り結果が Primary より古い。書き込み直後に読む場合は Primary を使うこと |
| Fallback 設計 | Replica が停止してもアプリが止まらないように、Primary への自動フォールバックを実装する |
| read-only | Replica には `--read-only` オプションで誤書き込みを防止する |
| 接続プールの分離 | Primary と Replica で別々の `*sql.DB` 接続プールを持つことで独立した管理が可能 |

---

## k6 負荷テスト

### 実行コマンド

```bash
# Docker 環境でテスト（Replica あり）
k6 run \
  -e PRIMARY_HOST=127.0.0.1 \
  -e PRIMARY_PORT=3307 \
  -e REPLICA_HOST=127.0.0.1 \
  -e REPLICA_PORT=3308 \
  k6/replica_test.js
```

### 期待結果比較表

テスト構成: 100 VUs, 60 秒, 80% 読み込み / 20% 書き込み

| メトリクス | Replica あり | Replica なし（全部 Primary）| 改善 |
|-----------|-------------|--------------------------|------|
| p50 latency | < 5ms | < 5ms | 同程度 |
| p95 latency (read) | < 15ms | < 30ms | ~2x 改善 |
| p99 latency | < 50ms | < 100ms | ~2x 改善 |
| Error Rate | < 0.1% | < 0.5% | 改善 |
| RPS | 500〜800 | 300〜500 | ~1.5x 向上 |
| Primary CPU | 20〜30% | 60〜80% | ~3x 低下 |

> **NOTE**: 単一ノードに比べ Primary の CPU を Replica で分散することが主目的。  
> レイテンシの改善より「Primary の余裕」を作ることが重要。
