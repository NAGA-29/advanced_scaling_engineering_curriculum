# STEP 02: DB Index とクエリチューニング

## 目的

DBをスケールアウトする前に、クエリとインデックスで改善できることを学ぶ。  
スケールアウトは「すでに最適化されたクエリ」に対して行うべきであり、  
インデックスなしのクエリをそのまま複数台に分散しても効果は薄い。

- `EXPLAIN` の出力を読んでボトルネックを特定する
- 適切なインデックスを設計・追加する
- N+1 問題を認識し、JOIN または IN 句で解消する
- 複合インデックスの順序が検索パターンに与える影響を理解する

---

## EXPLAIN の読み方

```sql
EXPLAIN SELECT * FROM users WHERE tenant_id = 'tenant-001' AND status = 'active';
```

| フィールド | 意味 | 良い値 |
|-----------|------|--------|
| `type` | アクセスタイプ | `const` > `eq_ref` > `ref` > `range` > `index` > **`ALL`(最悪)** |
| `key` | 実際に使われたインデックス | NULL でないこと |
| `rows` | スキャン推定行数 | 小さいほど良い |
| `Extra` | 追加情報 | `Using index` は良い。`Using filesort`, `Using temporary` は要注意 |
| `possible_keys` | 使えるインデックス候補 | 複数ある場合はオプティマイザが選択 |

### アクセスタイプの詳細

| type | 意味 | 例 |
|------|------|-----|
| `const` | Primary Key または Unique Index での 1 件取得 | `WHERE id = 1` |
| `eq_ref` | JOIN で一意インデックスを使った 1 件取得 | `ON a.id = b.user_id` |
| `ref` | 非ユニークインデックスでの複数件取得 | `WHERE tenant_id = 'x'` |
| `range` | インデックスを使った範囲検索 | `WHERE created_at > '2024-01-01'` |
| `index` | Full Index Scan（インデックスを全走査） | カバリングインデックスの場合は速い |
| `ALL` | Full Table Scan（最悪）| インデックスが使えない場合 |

---

## 構成

```
step02_db_index_and_query_tuning/
├── README.md              # このファイル
├── sql/
│   ├── bad_queries.sql    # 意図的に悪いクエリ（Full Table Scan など）
│   ├── good_queries.sql   # 最適化済みクエリ
│   ├── add_indexes.sql    # インデックス追加
│   └── remove_indexes.sql # インデックス削除（壊す演習用）
└── k6/
    └── query_comparison_test.js  # インデックスあり/なし比較テスト
```

---

## 成果物

```
step02_db_index_and_query_tuning/
├── README.md
├── sql/
│   ├── bad_queries.sql
│   ├── good_queries.sql
│   ├── add_indexes.sql
│   └── remove_indexes.sql
└── k6/
    └── query_comparison_test.js
```

---

## 前提条件

- STEP 01 が完了し、`users` テーブルに 100,000 件のデータがあること
- MySQL クライアントが EC2 または ローカルからアクセスできること
- k6 がローカルにインストールされていること

```bash
# 前提確認
export EC2_IP=<EC2のパブリックIP>
curl -s http://${EC2_IP}:8080/health
# {"status":"ok"}

ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb -e 'SELECT COUNT(*) FROM users;'"
# 100000
```

---

## 実行手順

### 1. 現在のインデックス状態を確認

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb -e 'SHOW INDEX FROM users; SHOW INDEX FROM devices;'"
```

### 2. bad_queries.sql を実行して Full Table Scan を確認

```bash
scp -i ~/.ssh/scaling-key.pem sql/bad_queries.sql ec2-user@${EC2_IP}:/tmp/
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb < /tmp/bad_queries.sql"
```

`EXPLAIN` 出力で `type: ALL` が表示されることを確認する。

### 3. remove_indexes.sql でインデックスを削除

```bash
scp -i ~/.ssh/scaling-key.pem sql/remove_indexes.sql ec2-user@${EC2_IP}:/tmp/
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb < /tmp/remove_indexes.sql"
```

### 4. インデックスなしで k6 テストを実行（計測）

```bash
k6 run -e EC2_IP=${EC2_IP} k6/query_comparison_test.js
# 結果を記録する
```

### 5. EXPLAIN でクエリプランを確認

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb -e \
    'EXPLAIN SELECT * FROM users WHERE tenant_id = \"tenant-001\" AND status = \"active\";'"
```

`type: ALL`, `key: NULL`, `rows: ~100000` が表示されることを確認。

### 6. add_indexes.sql でインデックスを追加

```bash
scp -i ~/.ssh/scaling-key.pem sql/add_indexes.sql ec2-user@${EC2_IP}:/tmp/
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb < /tmp/add_indexes.sql"
```

### 7. インデックスありで k6 テストを再実行（比較）

```bash
k6 run -e EC2_IP=${EC2_IP} k6/query_comparison_test.js
# ステップ 4 との結果を比較する
```

### 8. good_queries.sql でクエリを確認

```bash
scp -i ~/.ssh/scaling-key.pem sql/good_queries.sql ec2-user@${EC2_IP}:/tmp/
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb < /tmp/good_queries.sql"
```

`type: ref` または `type: range`、`key: <index名>` が表示されることを確認。

---

## 確認方法

### EXPLAIN を使ったクエリプラン確認

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} bash << 'EOF'
mysql -u apiuser -papipassword appdb << 'MYSQL'
-- インデックスが効いているか確認
EXPLAIN SELECT id, name FROM users WHERE tenant_id = 'tenant-001';
EXPLAIN SELECT id, name FROM users WHERE email = 'user1@example.com';
EXPLAIN SELECT id, name FROM users WHERE tenant_id = 'tenant-001' AND status = 'active';

-- Slow Query ログでスロークエリを確認
SHOW STATUS LIKE 'Slow_queries';
MYSQL
EOF
```

### インデックス使用統計の確認

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb -e \
    'SELECT * FROM information_schema.TABLE_STATISTICS WHERE TABLE_NAME = \"users\";'"
```

---

## 壊す手順

### インデックスを削除して Full Table Scan を引き起こす

```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb < /tmp/remove_indexes.sql"

# EXPLAINで確認
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb -e \
    'EXPLAIN SELECT * FROM users WHERE tenant_id = \"tenant-001\";'"
# type: ALL, key: NULL が表示されること

# k6 で負荷テストしてレイテンシ悪化を確認
k6 run --vus 50 --duration 30s -e EC2_IP=${EC2_IP} k6/query_comparison_test.js
```

**期待される変化**:
- `type` が `ref` → `ALL` に変わる
- `rows` が `10000` → `100000` になる
- k6 の p95 レイテンシが大幅悪化

---

## 復旧手順

```bash
# インデックスを追加して復旧
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb < /tmp/add_indexes.sql"

# EXPLAIN で復旧を確認
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb -e \
    'EXPLAIN SELECT * FROM users WHERE tenant_id = \"tenant-001\";'"
# type: ref, key: idx_users_tenant_id が表示されること

# k6 で改善を確認
k6 run --vus 50 --duration 30s -e EC2_IP=${EC2_IP} k6/query_comparison_test.js
```

---

## 削除手順

STEP 02 は STEP 00/01 のインフラを流用するため、独自の AWS リソースはない。

データのリセット:
```bash
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP} \
  "mysql -u apiuser -papipassword appdb -e \
    'DROP TABLE IF EXISTS devices, users, tenants;'"
```

インフラ削除は STEP 00 の手順に従う:
```bash
cd ../step00_terraform_base
terraform destroy
```

---

## 学び

| 項目 | 学んだこと |
|------|-----------|
| EXPLAIN の type | `ALL` はテーブル全走査。`ref`, `const` が理想。インデックス設計の評価指標 |
| 複合インデックスの順序 | `(tenant_id, status)` は `WHERE tenant_id = ? AND status = ?` に効く。順序が逆だと効かない場合がある |
| カバリングインデックス | `SELECT` で取得するカラムすべてがインデックスに含まれると、テーブルアクセス不要（`Using index`） |
| N+1 問題 | ループ内で都度 DB クエリを発行する問題。JOIN や IN 句で 1 クエリにまとめる |
| インデックスのコスト | インデックスは書き込み（INSERT/UPDATE）を遅くする。読み取りが多いカラムに絞って設計する |
| slow query log | `long_query_time = 0.1` に設定すると 100ms 以上のクエリが全部記録され、ボトルネック発見に役立つ |

---

## k6 負荷テスト

### 実行コマンド

```bash
# インデックス削除後（悪い状態）
k6 run -e EC2_IP=${EC2_IP} -e SCENARIO=no_index k6/query_comparison_test.js

# インデックス追加後（良い状態）
k6 run -e EC2_IP=${EC2_IP} -e SCENARIO=with_index k6/query_comparison_test.js
```

### 期待結果比較表

テスト構成: 50 VUs, 60 秒, `GET /users?tenant_id=...` と `GET /users/:id` 混在

| メトリクス | Index あり | Index なし | 改善倍率 |
|-----------|-----------|-----------|---------|
| p50 latency | < 5ms | 80〜300ms | 16〜60x |
| p95 latency | < 20ms | 500ms〜2s | 25〜100x |
| p99 latency | < 50ms | 1s〜5s | 20〜100x |
| Error Rate | < 0.1% | 2〜15% | - |
| RPS | 300〜500 | 15〜60 | 5〜33x |
| MySQL rows scanned (tenant query) | ~10,000 | ~100,000 | 10x |

> **環境**: t3.micro, users 100,000 件, 10 テナント均等分散
