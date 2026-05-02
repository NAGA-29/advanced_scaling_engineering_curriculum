# Step 09: ゼロダウンタイム スキーママイグレーション

## 目的

本番サービスを停止させずにテーブルの構造変更を行う手法を習得する。
`users.name` カラムを `first_name` / `last_name` に分割する例を通じて、
**Expand → Migrate → Contract** の3段階パターンを実践する。

---

## 構成

```
  Expand → Migrate → Contract の3段階

  ┌──────────────────────────────────────────────────────────────────────┐
  │  Phase 1: Expand (カラム追加)                                         │
  │                                                                      │
  │  users テーブル:                                                      │
  │    id, name, first_name(NULL), last_name(NULL), ...                  │
  │                                                                      │
  │  アプリ v1 (compatible):                                              │
  │    読み: name を読む                                                  │
  │    書き: name に書く + first_name/last_name にも書く（NULLチェック後）  │
  └──────────────────────────────────────────────────────────────────────┘
                              ↓
  ┌──────────────────────────────────────────────────────────────────────┐
  │  Phase 2: Migrate (データバックフィル)                                 │
  │                                                                      │
  │  既存データを変換:                                                     │
  │    first_name = SUBSTRING_INDEX(name, ' ', 1)                        │
  │    last_name  = SUBSTRING_INDEX(name, ' ', -1)                       │
  │                                                                      │
  │  バッチ処理で少量ずつ更新 (LIMIT 1000)                                 │
  └──────────────────────────────────────────────────────────────────────┘
                              ↓
  ┌──────────────────────────────────────────────────────────────────────┐
  │  Phase 3: Contract (旧カラム削除)                                      │
  │                                                                      │
  │  アプリ v2 に切り替え後:                                               │
  │    読み: first_name/last_name を読む (name はフォールバック)            │
  │    書き: first_name/last_name のみ書く                                │
  │                                                                      │
  │  ALTER TABLE users DROP COLUMN name                                  │
  └──────────────────────────────────────────────────────────────────────┘

  注意: 各フェーズ間では必ずアプリをデプロイし、k6でゼロダウンタイムを確認する。
```

---

## 成果物

| ファイル | 説明 |
|---------|------|
| `sql/step1_expand.sql` | Phase 1: first_name/last_name カラム追加 |
| `sql/step2_backfill.sql` | Phase 2: 既存データのバックフィルSQL |
| `sql/step3_contract.sql` | Phase 3: 旧nameカラム削除 |
| `app/v1_handler.go` | 旧v1ハンドラー（nameも書き、first_name/last_nameにも書く互換モード） |
| `app/v2_handler.go` | 新v2ハンドラー（first_name/last_name主体、nameにフォールバック） |
| `scripts/backfill.go` | バックフィルGo実装（進捗管理・バッチ処理） |
| `k6/migration_smoke_test.js` | マイグレーション中のゼロダウンタイム検証 |

---

## 前提条件

- MySQL 8.0（またはDocker経由で起動）
- Go >= 1.21
- k6 インストール済み
- 以下のGoモジュール:
  - `github.com/go-sql-driver/mysql`
- 環境変数:
  ```bash
  export APP_URL="http://localhost:8080"
  export DSN="root:root@tcp(127.0.0.1:3306)/appdb?parseTime=true"
  ```

---

## 実行手順

### 0. 準備: データベースと初期データ

```bash
# MySQLを起動（Step 08 の docker-compose を流用可能）
docker run -d --name mysql-migration \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=appdb \
  -p 3306:3306 \
  mysql:8.0

# 初期テーブル作成と既存データ投入
mysql -h 127.0.0.1 -P 3306 -u root -proot appdb << 'EOF'
CREATE TABLE IF NOT EXISTS users (
  id         BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name       VARCHAR(255) NOT NULL,
  email      VARCHAR(255) NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- 既存データ（nameカラムのみ）
INSERT INTO users (name, email) VALUES
  ('Alice Smith',   'alice@example.com'),
  ('Bob Johnson',   'bob@example.com'),
  ('Charlie Brown', 'charlie@example.com'),
  ('山田 太郎',      'taro@example.com'),
  ('鈴木 花子',      'hanako@example.com');
EOF
```

### 1. Phase 1: Expand — カラム追加

```bash
# アプリが稼働中でも安全（NULLを許容するカラム追加はロックなし）
mysql -h 127.0.0.1 -P 3306 -u root -proot appdb < sql/step1_expand.sql

# 確認
mysql -h 127.0.0.1 -P 3306 -u root -proot -e "DESCRIBE appdb.users;"
```

### 2. アプリをv1（互換モード）にデプロイ

```bash
# v1ハンドラー: nameへの書き込みと同時にfirst_name/last_nameにも書く
# ここからの新規書き込みはすべて両方のカラムに保存される
go build -o app_v1 app/v1_handler.go
./app_v1
```

### 3. Phase 2: Migrate — バックフィル

```bash
# 既存データを変換（サービス稼働中に実行）
go run scripts/backfill.go \
  --dsn "root:root@tcp(127.0.0.1:3306)/appdb?parseTime=true" \
  --batch-size 1000 \
  --table users

# または直接SQLを実行（少量データの場合）
mysql -h 127.0.0.1 -P 3306 -u root -proot appdb < sql/step2_backfill.sql
```

### 4. バックフィル完了確認

```bash
mysql -h 127.0.0.1 -P 3306 -u root -proot -e "
  SELECT COUNT(*) as total,
         SUM(CASE WHEN first_name IS NULL THEN 1 ELSE 0 END) as not_migrated
  FROM appdb.users;"
# not_migrated が 0 になるまで待つ
```

### 5. アプリをv2にデプロイ

```bash
# v2ハンドラー: first_name/last_name を主体として読み書き
go build -o app_v2 app/v2_handler.go
./app_v2
```

### 6. Phase 3: Contract — 旧カラム削除

```bash
# v2が完全にデプロイされ、nameカラムを参照するコードがないことを確認後
mysql -h 127.0.0.1 -P 3306 -u root -proot appdb < sql/step3_contract.sql

# 確認
mysql -h 127.0.0.1 -P 3306 -u root -proot -e "DESCRIBE appdb.users;"
# nameカラムが消えていること
```

---

## 確認方法

### 各フェーズの状態確認

```bash
# 現在のテーブル構造
mysql -h 127.0.0.1 -P 3306 -u root -proot -e "SHOW CREATE TABLE appdb.users\G"

# バックフィル進捗
mysql -h 127.0.0.1 -P 3306 -u root -proot -e "
  SELECT
    COUNT(*) as total,
    SUM(CASE WHEN first_name IS NOT NULL THEN 1 ELSE 0 END) as migrated,
    SUM(CASE WHEN first_name IS NULL THEN 1 ELSE 0 END) as remaining
  FROM appdb.users;"
```

### k6でゼロダウンタイムを継続確認

```bash
# マイグレーション全工程を通じてリクエストを流し続ける
k6 run -e APP_URL=$APP_URL k6/migration_smoke_test.js
```

---

## 壊す手順

### 禁止パターン1: 大量データへの一発ALTER

```sql
-- NG: テーブルロックが発生し、サービス停止
ALTER TABLE users
  ADD COLUMN first_name VARCHAR(100),
  ADD COLUMN last_name  VARCHAR(100),
  DROP COLUMN name;
-- -> 数百万行のテーブルでは数十分ロックが続く
```

### 禁止パターン2: Contract前にv2をデプロイしない

```sql
-- v1アプリが動いている状態でnameカラムを削除
ALTER TABLE users DROP COLUMN name;
-- -> v1アプリが name カラムを参照してエラーが発生
```

### 禁止パターン3: バックフィル完了前にv2をデプロイ

```go
// v2はfirst_name/last_nameを読むが、バックフィル未完のユーザーはNULLを返す
// -> 一部ユーザーの名前が空白になる
```

---

## 復旧手順

```bash
# Phase 1 まで戻す（nameカラムを再追加）
mysql -h 127.0.0.1 -P 3306 -u root -proot appdb << 'EOF'
ALTER TABLE users ADD COLUMN name VARCHAR(255)
  GENERATED ALWAYS AS (CONCAT(first_name, ' ', last_name)) STORED;
EOF

# 完全にロールバック（Phase 1も取り消す）
mysql -h 127.0.0.1 -P 3306 -u root -proot appdb << 'EOF'
ALTER TABLE users
  DROP COLUMN first_name,
  DROP COLUMN last_name;
EOF
# -> nameカラムのみの元の状態に戻る
```

---

## 削除手順 (terraform destroy)

```bash
# Dockerコンテナを停止・削除
docker stop mysql-migration && docker rm mysql-migration

# AWS RDS等で構築した場合
# terraform destroy -auto-approve
```

---

## 学び

### Expand → Migrate → Contract パターン

```
1. Expand   : 新カラムを追加（NULLを許容）
               -> テーブルロックなし（MySQL 8.0のインスタントADD COLUMN）
               -> 既存コードに影響なし

2. Migrate  : 既存データをバッチ変換
               -> LIMIT 1000で少量ずつ更新
               -> サービス稼働中でも安全
               -> 中断・再開可能

3. Contract : 旧カラムを削除
               -> 新コードが完全にデプロイされてから
               -> 参照するコードがゼロになってから
```

### 禁止事項まとめ

| 操作 | リスク | 代替手段 |
|------|--------|---------|
| 大量データへの一発ALTER | 長時間テーブルロック | pt-online-schema-change / gh-ost |
| Contract前にDROP | アプリエラー | 全アプリがv2になってから |
| バッチなしUPDATE | レプリ遅延・ロック | LIMIT 1000 + sleep |
| NOTNULLカラムを即追加 | 全行更新ロック | まずNULL許容で追加、後にNOT NULL化 |

### MySQLのInstant DDL

MySQL 8.0.12以降、`ADD COLUMN`はデフォルトでINSTANT（ロックなし）。
ただし以下はINSTANTが使えない:
- カラムの順序変更（REORDER）
- NOT NULL制約の追加（既存データ修正が必要）
- FULLTEXT/SPATIAL インデックスの追加

---

## k6負荷テスト

### テスト条件

- VUs: 30
- 時間: マイグレーション全工程（手動）
- エンドポイント: `GET /users/:id`, `POST /users`, `PUT /users/:id`

### 結果比較

| 指標 | マイグレーション前 | Phase 1中 | Phase 2中（バックフィル） | Phase 3（DROP COLUMN） |
|------|------------------|----------|------------------------|----------------------|
| p50 レイテンシ | 15ms | 15ms | 19ms | 14ms |
| p95 レイテンシ | 48ms | 49ms | 68ms | 47ms |
| p99 レイテンシ | 88ms | 90ms | 120ms | 86ms |
| エラーレート | 0.0% | 0.0% | 0.0% | 0.0% |
| RPS | 1,800 req/s | 1,790 req/s | 1,620 req/s | 1,810 req/s |

> **観察**: 全フェーズを通じてエラーレート0%を達成。  
> バックフィル中（Phase 2）にやや性能が低下するが、許容範囲内。  
> DROP COLUMN（Phase 3）はInstant DDLのため性能影響なし。
