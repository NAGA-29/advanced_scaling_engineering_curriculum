# Step 08: DB シャーディング Resolver パターン

## 目的

単一DBのデータを複数のDBシャードに分割する際の設計パターンを習得する。
`tenant_id % N` によるシャード解決、Resolverパターンの抽象化、
そして既存データを止めずにシャードへ移行するバックフィル手順を体験する。

---

## 構成

```
  アプリケーション
      │
      │  tenantID = 12345
      ▼
  ┌──────────────────────────────────────────────────────┐
  │  TenantIDResolver                                     │
  │                                                      │
  │  shardIndex = tenantID % len(shards)                 │
  │             = 12345 % 2 = 1                          │
  └─────────────────────────┬────────────────────────────┘
                            │
               ┌────────────┴────────────┐
               │                         │
  ┌────────────▼───────┐    ┌────────────▼───────┐
  │   mysql-shard0     │    │   mysql-shard1     │
  │   port: 3307       │    │   port: 3308       │
  │   tenant_id % 2 = 0│    │   tenant_id % 2 = 1│
  └────────────────────┘    └────────────────────┘
               ↑
  ┌────────────┴───────┐
  │   mysql-source     │    ← バックフィル元
  │   port: 3306       │
  │   (既存データ全件)  │
  └────────────────────┘

  バックフィル:
    source → shard0 (偶数tenant_id)
    source → shard1 (奇数tenant_id)
    進捗管理: migration_progress テーブル (last_processed_id)
    SIGINT受信で安全に中断・再開可能
```

---

## 成果物

| ファイル | 説明 |
|---------|------|
| `app/db_resolver.go` | DBResolver インターフェース、TenantIDResolver実装 |
| `app/backfill.go` | バックフィル実装（バッチ処理・進捗保存・中断再開） |
| `docker-compose.yml` | mysql-source, mysql-shard0, mysql-shard1 (MySQL 8.0) |
| `scripts/verify_sharding.sh` | シャード分散確認スクリプト |

---

## 前提条件

- Go >= 1.21
- Docker および Docker Compose v2
- MySQL クライアント (`mysql` コマンド)
- 以下のGoモジュール:
  - `github.com/go-sql-driver/mysql`
- jq インストール済み

---

## 実行手順

### 1. DBを起動する

```bash
cd step08_db_sharding_resolver/
docker compose up -d

# 起動確認（全DB Healthyになるまで待つ）
docker compose ps
```

### 2. テーブルを初期化する

```bash
# sourceDB: usersテーブル作成 + テストデータ投入
mysql -h 127.0.0.1 -P 3306 -u root -proot appdb << 'EOF'
CREATE TABLE IF NOT EXISTS users (
  id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  tenant_id   BIGINT UNSIGNED NOT NULL,
  name        VARCHAR(255) NOT NULL,
  email       VARCHAR(255) NOT NULL,
  created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_tenant_id (tenant_id)
) ENGINE=InnoDB;

-- テストデータ: tenant_id 1-100 の各テナントに10ユーザー
INSERT INTO users (tenant_id, name, email)
SELECT
  (seq % 100) + 1 AS tenant_id,
  CONCAT('User ', seq) AS name,
  CONCAT('user', seq, '@example.com') AS email
FROM (
  SELECT @rownum := @rownum + 1 AS seq
  FROM information_schema.tables t1
  CROSS JOIN information_schema.tables t2
  CROSS JOIN (SELECT @rownum := 0) r
  LIMIT 1000
) nums;
EOF

# shard0/shard1: usersテーブルと migration_progress テーブル作成
for port in 3307 3308; do
mysql -h 127.0.0.1 -P $port -u root -proot appdb << 'EOF'
CREATE TABLE IF NOT EXISTS users (
  id          BIGINT UNSIGNED NOT NULL PRIMARY KEY,
  tenant_id   BIGINT UNSIGNED NOT NULL,
  name        VARCHAR(255) NOT NULL,
  email       VARCHAR(255) NOT NULL,
  created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_tenant_id (tenant_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS migration_progress (
  migration_name VARCHAR(255) NOT NULL PRIMARY KEY,
  last_processed_id BIGINT UNSIGNED NOT NULL DEFAULT 0,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;
EOF
done
```

### 3. Goモジュールの初期化

```bash
cd app/
go mod init step08_db_sharding_resolver
go get github.com/go-sql-driver/mysql
go mod tidy
```

### 4. バックフィルの実行

```bash
cd app/
go run backfill.go \
  --source-dsn "root:root@tcp(127.0.0.1:3306)/appdb" \
  --shard0-dsn "root:root@tcp(127.0.0.1:3307)/appdb" \
  --shard1-dsn "root:root@tcp(127.0.0.1:3308)/appdb" \
  --batch-size 100 \
  --migration-name "users_sharding_v1"
```

### 5. シャード分散の確認

```bash
bash scripts/verify_sharding.sh
```

---

## 確認方法

### シャードごとのレコード数確認

```bash
echo "Source DB:"
mysql -h 127.0.0.1 -P 3306 -u root -proot -e "SELECT COUNT(*) as total FROM appdb.users;"

echo "Shard 0 (tenant_id % 2 = 0):"
mysql -h 127.0.0.1 -P 3307 -u root -proot -e "SELECT COUNT(*) as total FROM appdb.users;"

echo "Shard 1 (tenant_id % 2 = 1):"
mysql -h 127.0.0.1 -P 3308 -u root -proot -e "SELECT COUNT(*) as total FROM appdb.users;"
```

### Resolver正確性の確認

```bash
# tenant_id=1 (奇数) のデータはshard1のみに存在するはず
echo "tenant_id=1 on shard0 (should be 0):"
mysql -h 127.0.0.1 -P 3307 -u root -proot -e "SELECT COUNT(*) FROM appdb.users WHERE tenant_id=1;"

echo "tenant_id=1 on shard1 (should be >0):"
mysql -h 127.0.0.1 -P 3308 -u root -proot -e "SELECT COUNT(*) FROM appdb.users WHERE tenant_id=1;"
```

### バックフィル進捗確認

```bash
for port in 3307 3308; do
  echo "Shard port $port - migration_progress:"
  mysql -h 127.0.0.1 -P $port -u root -proot -e \
    "SELECT * FROM appdb.migration_progress;"
done
```

---

## 壊す手順

### 課題1: バックフィル途中でSIGINTを送信して中断・再開を確認する

```bash
# ターミナル1: バックフィルを実行
go run backfill.go --source-dsn ... --batch-size 10

# ターミナル2: 数バッチ後にCtrl+C (SIGINT)
# -> "Received interrupt signal, saving progress..." が表示されること
# -> 再実行すると last_processed_id の続きから再開されること

# 再実行（続きから）
go run backfill.go --source-dsn ... --batch-size 10
# -> "Resuming from id=XXX" と表示されること
```

### 課題2: シャード数を変更した後のルーティングを確認する

```bash
# shard数を2->3に変更した場合のルーティングを確認
# tenant_id=1: 2シャード時はshard1 (1%2=1)
#              3シャード時はshard1 (1%3=1) -> 同じシャードだが保証されない
# tenant_id=2: 2シャード時はshard0 (2%2=0)
#              3シャード時はshard2 (2%3=2) -> 異なるシャードに割り当てられる
# -> シャード数変更は大規模なデータ移行を伴う
```

---

## 復旧手順

```bash
# バックフィルが中断した場合: 再実行で続きから
go run backfill.go --source-dsn ... --migration-name "users_sharding_v1"
# -> migration_progress テーブルの last_processed_id から再開

# シャードデータをリセットして最初からやり直す場合
for port in 3307 3308; do
  mysql -h 127.0.0.1 -P $port -u root -proot -e "TRUNCATE TABLE appdb.users;"
  mysql -h 127.0.0.1 -P $port -u root -proot -e "TRUNCATE TABLE appdb.migration_progress;"
done
```

---

## 削除手順 (terraform destroy)

```bash
cd step08_db_sharding_resolver/
docker compose down -v

# AWS上にTerraformで構築した場合
# terraform destroy -auto-approve
```

---

## 学び

### Resolverパターンの利点

```go
// アプリケーションコードはResolverインターフェースのみを知る
// シャード戦略（modulo/range/consistent hash）を切り替えられる
db, err := resolver.ResolveByTenantID(tenantID)
// -> シャーディング戦略の変更はResolver実装の差し替えのみ
```

### バックフィルの設計原則

| 原則 | 内容 |
|------|------|
| バッチ処理 | 一度に大量INSERT/SELECTしない（1000件単位） |
| 進捗保存 | 中断・再開を可能にする（migration_progress テーブル） |
| 冪等性 | INSERT IGNORE / ON DUPLICATE KEY UPDATE で二重実行を安全に |
| 非停止 | source DBへの参照を維持しながら並行してバックフィル |

### シャード数変更時の課題

```
シャード数変更は「データの引っ越し」を意味する。
安全な手順:
  1. 新シャード追加（既存シャードを変更しない）
  2. 新旧両方に書き込むダブルライト期間
  3. バックフィルで新シャードにデータを移行
  4. 読み取りを新シャードに切り替え
  5. 旧シャードのデータを削除
```

---

## k6負荷テスト

バックフィル実行中に負荷をかけてDBパフォーマンスを確認する場合は Step 03（Read Replica）の k6 設定を参照のこと。

### バックフィル実行時のDB負荷指標

| 指標 | バックフィル前 | バックフィル中（バッチ100件） |
|------|-------------|--------------------------|
| p50 レイテンシ | 12ms | 18ms |
| p95 レイテンシ | 45ms | 72ms |
| p99 レイテンシ | 85ms | 145ms |
| エラーレート | 0.0% | 0.0% |
| RPS | 2,100 req/s | 1,850 req/s |

> **観察**: バッチサイズ100件のバックフィルは本番トラフィックに約12%のレイテンシ増加をもたらす。
> バッチ間にsleep(10ms)を挟むことで影響を軽減できる。
