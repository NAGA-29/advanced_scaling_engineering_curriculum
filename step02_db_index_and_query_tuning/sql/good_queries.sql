-- =============================================================
-- STEP 02: 最適化済みクエリ集
-- 目的: インデックスを活用した効率的なクエリパターンを学ぶ
-- 実行方法:
--   mysql -u apiuser -papipassword appdb < good_queries.sql
-- =============================================================

USE appdb;

-- -------------------------------------------------------
-- 最適化 1: Primary Key 検索（type: const）
-- -------------------------------------------------------

EXPLAIN
SELECT id, tenant_id, name, email, status, created_at
FROM users
WHERE id = 42;
/*
期待される EXPLAIN 出力:
+----+-------------+-------+-------+---------------+---------+---------+-------+------+-------+
| id | select_type | table | type  | possible_keys | key     | key_len | ref   | rows | Extra |
+----+-------------+-------+-------+---------------+---------+---------+-------+------+-------+
|  1 | SIMPLE      | users | const | PRIMARY       | PRIMARY | 8       | const |    1 |       |
+----+-------------+-------+-------+---------------+---------+---------+-------+------+-------+
type=const: Primary Key での 1 件完全一致。最速のアクセスパターン。rows=1。
*/

-- 実際のクエリ
SELECT id, tenant_id, name, email, status, created_at
FROM users
WHERE id = 42;

-- -------------------------------------------------------
-- 最適化 2: Unique Index 検索（type: const）
-- -------------------------------------------------------

EXPLAIN
SELECT id, tenant_id, name, email
FROM users
WHERE email = 'user42@example.com';
/*
+----+-------------+-------+-------+------------------+------------------+---------+-------+------+-------+
| id | select_type | table | type  | possible_keys    | key              | key_len | ref   | rows | Extra |
+----+-------------+-------+-------+------------------+------------------+---------+-------+------+-------+
|  1 | SIMPLE      | users | const | uq_users_email   | uq_users_email   | 1022    | const |    1 |       |
+----+-------------+-------+-------+------------------+------------------+---------+-------+------+-------+
type=const: Unique Index での 1 件取得。Primary Key と同等の速度。
*/

-- -------------------------------------------------------
-- 最適化 3: 非ユニークインデックス検索（type: ref）
-- -------------------------------------------------------

EXPLAIN
SELECT id, name, email, status
FROM users
WHERE tenant_id = 'tenant-001'
ORDER BY id
LIMIT 100;
/*
+----+-------------+-------+------+-----------------------+-----------------------+---------+-------+-------+-------------+
| id | select_type | table | type | possible_keys         | key                   | key_len | ref   | rows  | Extra       |
+----+-------------+-------+------+-----------------------+-----------------------+---------+-------+-------+-------------+
|  1 | SIMPLE      | users | ref  | idx_users_tenant_id   | idx_users_tenant_id   | 146     | const | 10000 | Using where |
+----+-------------+-------+------+-----------------------+-----------------------+---------+-------+-------+-------------+
type=ref: 非ユニークインデックスでの等値検索。10,000 件のテナントデータから検索。
Full Table Scan（100,000 件）と比較して 10x 効率的。
*/

-- -------------------------------------------------------
-- 最適化 4: 複合インデックスの活用
-- -------------------------------------------------------

-- (tenant_id, status) の複合インデックスがある場合の最適クエリ
EXPLAIN
SELECT id, name, email
FROM users
WHERE tenant_id = 'tenant-001'
  AND status = 'active';
/*
複合インデックス idx_users_tenant_status が存在する場合:
+----+-------------+-------+------+---------------------------+---------------------------+---------+-------------+------+-------------+
| id | select_type | table | type | possible_keys             | key                       | key_len | ref         | rows | Extra       |
+----+-------------+-------+------+---------------------------+---------------------------+---------+-------------+------+-------------+
|  1 | SIMPLE      | users | ref  | idx_users_tenant_status   | idx_users_tenant_status   | 296     | const,const | 8000 | Using where |
+----+-------------+-------+------+---------------------------+---------------------------+---------+-------------+------+-------------+
2 条件を同時にインデックスで絞り込める。
*/

-- -------------------------------------------------------
-- 最適化 5: カバリングインデックス（Extra: Using index）
-- -------------------------------------------------------

-- SELECT するカラムがインデックスに含まれている場合、テーブルアクセスが不要
-- (tenant_id, id) または (tenant_id) インデックスで id だけを SELECT する場合
EXPLAIN
SELECT id
FROM users
WHERE tenant_id = 'tenant-001';
/*
+----+-------------+-------+------+---------------------+---------------------+---------+-------+-------+-------------+
| id | select_type | table | type | possible_keys       | key                 | key_len | ref   | rows  | Extra       |
+----+-------------+-------+------+---------------------+---------------------+---------+-------+-------+-------------+
|  1 | SIMPLE      | users | ref  | idx_users_tenant_id | idx_users_tenant_id | 146     | const | 10000 | Using index |
+----+-------------+-------+------+---------------------+---------------------+---------+-------+-------+-------------+
Extra: Using index はテーブルへのランダムアクセスなしでインデックスのみで解決できることを示す。
*/

-- -------------------------------------------------------
-- 最適化 6: N+1 問題の解決（JOIN を使う）
-- -------------------------------------------------------

-- 悪い例（N+1）: アプリ側でループして複数クエリを発行
-- 良い例: JOIN で 1 クエリに統合

EXPLAIN
SELECT
  t.id   AS tenant_id,
  t.name AS tenant_name,
  t.plan,
  COUNT(u.id) AS user_count
FROM tenants t
LEFT JOIN users u ON u.tenant_id = t.id
GROUP BY t.id, t.name, t.plan
ORDER BY user_count DESC;
/*
JOIN + GROUP BY で全テナントのユーザー数を 1 クエリで取得。
N+1（10 クエリ）→ 1 クエリ に削減。
*/

-- -------------------------------------------------------
-- 最適化 7: IN 句で N+1 を解決
-- -------------------------------------------------------

-- 悪い例: ループで 1 件ずつ取得
-- SELECT * FROM users WHERE id = 1;
-- SELECT * FROM users WHERE id = 2;
-- ...（100 回）

-- 良い例: IN 句で一括取得
EXPLAIN
SELECT id, name, email, tenant_id
FROM users
WHERE id IN (1, 2, 3, 4, 5, 10, 20, 50, 100, 200);
/*
+----+-------------+-------+-------+---------------+---------+---------+------+------+-------------+
| id | select_type | table | type  | possible_keys | key     | key_len | ref  | rows | Extra       |
+----+-------------+-------+-------+---------------+---------+---------+------+------+-------------+
|  1 | SIMPLE      | users | range | PRIMARY       | PRIMARY | 8       | NULL |   10 | Using where |
+----+-------------+-------+-------+---------------+---------+---------+------+------+-------------+
type=range: Primary Key の範囲検索として処理される。1 クエリで 10 件取得。
*/

-- -------------------------------------------------------
-- 最適化 8: LIMIT + インデックスを使ったページネーション
-- -------------------------------------------------------

-- 悪い例: OFFSET が大きいと遅くなる
EXPLAIN
SELECT id, name, email
FROM users
WHERE tenant_id = 'tenant-001'
ORDER BY id
LIMIT 20 OFFSET 9980;
/*
OFFSET が大きいと、その行数分スキャンしてから捨てるので遅くなる。
9980 件を読んで最後の 20 件だけ返す。
*/

-- 良い例: カーソルページネーション（最後に取得した id を使う）
EXPLAIN
SELECT id, name, email
FROM users
WHERE tenant_id = 'tenant-001'
  AND id > 9980           -- 前ページの最後の id
ORDER BY id
LIMIT 20;
/*
+----+-------------+-------+-------+---------------------+---------------------+---------+------+------+-------------+
| id | select_type | table | type  | possible_keys       | key                 | key_len | ref  | rows | Extra       |
+----+-------------+-------+-------+---------------------+---------------------+---------+------+------+-------------+
|  1 | SIMPLE      | users | range | idx_users_tenant_id | idx_users_tenant_id | 146     | NULL |   20 | Using where |
+----+-------------+-------+-------+---------------------+---------------------+---------+------+------+-------------+
type=range: id > 9980 の条件でインデックスを使い、20 件だけ読む。OFFSET と比べて O(1) に近い。
*/

-- -------------------------------------------------------
-- 最適化 9: 範囲検索（type: range）
-- -------------------------------------------------------

EXPLAIN
SELECT id, name, created_at
FROM users
WHERE created_at >= '2024-01-01 00:00:00'
  AND created_at <  '2024-02-01 00:00:00';
/*
created_at にインデックスがある場合:
type=range で効率的な範囲スキャン。
インデックスがない場合は type=ALL で全件スキャン。
*/

-- -------------------------------------------------------
-- 最適化 10: サブクエリよりも JOIN
-- -------------------------------------------------------

-- 悪い例: 相関サブクエリ（行ごとにサブクエリ実行）
EXPLAIN
SELECT id, name
FROM users u
WHERE (
  SELECT COUNT(*)
  FROM devices d
  WHERE d.user_id = u.id
    AND d.status = 'active'
) > 0;
/*
相関サブクエリは外側クエリの各行に対してサブクエリを実行するため非常に遅い。
*/

-- 良い例: EXISTS または JOIN を使う
EXPLAIN
SELECT DISTINCT u.id, u.name
FROM users u
INNER JOIN devices d ON d.user_id = u.id
WHERE d.status = 'active';
/*
JOIN でインデックスを活用し、1 回のスキャンで解決。
devices.user_id にインデックスがあれば type=ref で効率的。
*/

-- または EXISTS を使う（同等の結果だが、オプティマイザが最適化しやすい）
EXPLAIN
SELECT u.id, u.name
FROM users u
WHERE EXISTS (
  SELECT 1
  FROM devices d
  WHERE d.user_id = u.id
    AND d.status = 'active'
);
