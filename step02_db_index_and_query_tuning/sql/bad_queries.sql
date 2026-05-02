-- =============================================================
-- STEP 02: 意図的に悪いクエリ集（アンチパターン）
-- 目的: Full Table Scan、N+1、不適切なインデックス利用を学ぶ
-- 実行方法:
--   mysql -u apiuser -papipassword appdb < bad_queries.sql
-- =============================================================

USE appdb;

-- -------------------------------------------------------
-- アンチパターン 1: Full Table Scan（インデックスなし列での検索）
-- -------------------------------------------------------

-- 悪い例: tenant_id にインデックスがない場合
-- EXPLAIN の type: ALL、rows: ~100000 になる
EXPLAIN
SELECT id, name, email, status
FROM users
WHERE tenant_id = 'tenant-001';
/*
期待される EXPLAIN 出力（インデックスなし時）:
+----+-------------+-------+------+---------------+------+---------+------+--------+-------------+
| id | select_type | table | type | possible_keys | key  | key_len | ref  | rows   | Extra       |
+----+-------------+-------+------+---------------+------+---------+------+--------+-------------+
|  1 | SIMPLE      | users | ALL  | NULL          | NULL | NULL    | NULL | 100000 | Using where |
+----+-------------+-------+------+---------------+------+---------+------+--------+-------------+
type=ALL が Full Table Scan を意味する。100,000 行すべてを読んでいる。
*/

-- -------------------------------------------------------
-- アンチパターン 2: LIKE '%suffix%' は先頭ワイルドカードでインデックス不使用
-- -------------------------------------------------------

EXPLAIN
SELECT id, name, email
FROM users
WHERE email LIKE '%@example.com';
/*
期待される EXPLAIN 出力:
+----+-------------+-------+------+---------------+------+---------+------+--------+-------------+
| id | select_type | table | type | possible_keys | key  | key_len | ref  | rows   | Extra       |
+----+-------------+-------+------+---------------+------+---------+------+--------+-------------+
|  1 | SIMPLE      | users | ALL  | NULL          | NULL | NULL    | NULL | 100000 | Using where |
+----+-------------+-------+------+---------------+------+---------+------+--------+-------------+
先頭が % で始まる LIKE は B-Tree インデックスを使えない。
*/

-- 改善策: 前方一致なら使える
EXPLAIN
SELECT id, name, email
FROM users
WHERE email LIKE 'user1%';
/*
+----+-------------+-------+-------+------------------+------------------+---------+------+------+-------------+
| id | select_type | table | type  | possible_keys    | key              | key_len | ref  | rows | Extra       |
+----+-------------+-------+-------+------------------+------------------+---------+------+------+-------------+
|  1 | SIMPLE      | users | range | uq_users_email   | uq_users_email   | 1022    | NULL |  111 | Using where |
+----+-------------+-------+-------+------------------+------------------+---------+------+------+-------------+
type=range に改善。rows も大幅削減。
*/

-- -------------------------------------------------------
-- アンチパターン 3: OR 条件でインデックスが使われない場合
-- -------------------------------------------------------

EXPLAIN
SELECT id, name, email
FROM users
WHERE tenant_id = 'tenant-001'
   OR tenant_id = 'tenant-002';
/*
OR 条件は場合によってはインデックスが使われない。
UNION で書き直すほうが確実にインデックスを使える。
*/

-- 改善策: UNION ALL で書き直す
EXPLAIN
SELECT id, name, email FROM users WHERE tenant_id = 'tenant-001'
UNION ALL
SELECT id, name, email FROM users WHERE tenant_id = 'tenant-002';
/*
2 つのクエリそれぞれでインデックスを使い、より効率的になる。
*/

-- -------------------------------------------------------
-- アンチパターン 4: 関数を使ったインデックス無効化
-- -------------------------------------------------------

-- 悪い例: カラムに関数を適用するとインデックスが使えない
EXPLAIN
SELECT id, name
FROM users
WHERE DATE(created_at) = '2024-01-01';
/*
+----+-------------+-------+------+---------------+------+---------+------+--------+-------------+
| id | select_type | table | type | possible_keys | key  | key_len | ref  | rows   | Extra       |
+----+-------------+-------+------+---------------+------+---------+------+--------+-------------+
|  1 | SIMPLE      | users | ALL  | NULL          | NULL | NULL    | NULL | 100000 | Using where |
+----+-------------+-------+------+---------------+------+---------+------+--------+-------------+
DATE(created_at) は created_at カラムを変換してしまうのでインデックスが使えない。
*/

-- 改善策: 範囲条件で書き直す
EXPLAIN
SELECT id, name
FROM users
WHERE created_at >= '2024-01-01 00:00:00'
  AND created_at <  '2024-01-02 00:00:00';
/*
type=range に改善。インデックスを使った範囲スキャン。
*/

-- -------------------------------------------------------
-- アンチパターン 5: N+1 問題のシミュレーション
-- -------------------------------------------------------

-- 悪い例: アプリケーション側でこんなコードを書くと N+1 になる
-- Step 1: テナントリストを取得（1 クエリ）
SELECT id FROM tenants LIMIT 10;

-- Step 2: 各テナントに対してループでユーザーを取得（N クエリ）
-- アプリ側: for each tenant { SELECT * FROM users WHERE tenant_id = ? }
-- これが N+1 問題。テナントが 10 件なら合計 11 クエリ。

-- 悪い EXPLAIN（1 テナントずつ取得するパターン）
EXPLAIN
SELECT u.id, u.name, u.tenant_id
FROM users u
WHERE u.tenant_id = 'tenant-001';

-- インデックスなしなら毎回 Full Table Scan = 10 × 100,000 行スキャン

-- -------------------------------------------------------
-- アンチパターン 6: SELECT * の乱用（不要なデータ転送）
-- -------------------------------------------------------

-- 悪い例: すべてのカラムを取得（不要なカラムも含む）
EXPLAIN
SELECT *
FROM users
WHERE tenant_id = 'tenant-001';

-- 改善策: 必要なカラムだけを SELECT
EXPLAIN
SELECT id, name, email
FROM users
WHERE tenant_id = 'tenant-001';
-- Extra: Using index（カバリングインデックスの場合）になる可能性あり

-- -------------------------------------------------------
-- アンチパターン 7: インデックスの左端を使わない複合インデックス
-- -------------------------------------------------------

-- 仮に (status, tenant_id) の複合インデックスがあったとして
-- status を指定せず tenant_id だけで検索すると使えない
-- （実際には idx_users_tenant_id があるので問題ないが、複合インデックスの理解のため）

-- 確認: EXPLAIN で possible_keys を見る
EXPLAIN
SELECT id, name
FROM users
WHERE status = 'active'
  AND tenant_id = 'tenant-001';
/*
複合インデックス (tenant_id, status) があれば:
- WHERE tenant_id = ? → インデックス使用可
- WHERE tenant_id = ? AND status = ? → インデックス使用可
- WHERE status = ? → インデックス使用不可（左端の tenant_id を使っていないため）
*/

-- -------------------------------------------------------
-- 実際にスロークエリを発生させる（インデックスなし + 全件スキャン）
-- -------------------------------------------------------

-- slow_query_log が有効な場合、このクエリは記録される
-- （インデックスなしの場合、long_query_time を超える可能性が高い）
SELECT SQL_NO_CACHE
  u.id,
  u.name,
  u.email,
  u.status,
  u.tenant_id
FROM users u
WHERE u.tenant_id = 'tenant-001'
  AND u.status = 'active'
ORDER BY u.created_at DESC
LIMIT 20;

-- -------------------------------------------------------
-- Slow Query ログの確認（root ユーザー権限が必要）
-- -------------------------------------------------------
-- SHOW STATUS LIKE 'Slow_queries';
-- tail -20 /var/log/mysql/slow.log
