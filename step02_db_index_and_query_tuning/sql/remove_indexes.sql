-- =============================================================
-- STEP 02: インデックス削除 SQL（壊す演習用）
-- 目的: インデックスを削除して Full Table Scan を発生させ、
--       パフォーマンス劣化を体感する
-- 警告: 本番環境では絶対に実行しないこと！
-- 実行方法:
--   mysql -u apiuser -papipassword appdb < remove_indexes.sql
-- =============================================================

USE appdb;

-- -------------------------------------------------------
-- 削除前の状態を確認
-- -------------------------------------------------------

SHOW INDEX FROM users;
SHOW INDEX FROM devices;

-- -------------------------------------------------------
-- users テーブルのインデックスを削除
-- -------------------------------------------------------

-- PRIMARY KEY と UNIQUE KEY は削除しない（アプリが壊れる）
-- ただし idx_users_tenant_id などの通常インデックスを削除

-- tenant_id インデックスの削除
-- これにより GET /users?tenant_id=... が Full Table Scan になる
ALTER TABLE users DROP INDEX IF EXISTS idx_users_tenant_id;

-- status インデックスの削除
ALTER TABLE users DROP INDEX IF EXISTS idx_users_status;

-- 複合インデックスの削除
ALTER TABLE users DROP INDEX IF EXISTS idx_users_tenant_status;
ALTER TABLE users DROP INDEX IF EXISTS idx_users_tenant_created;

-- -------------------------------------------------------
-- devices テーブルのインデックスを削除
-- -------------------------------------------------------

ALTER TABLE devices DROP INDEX IF EXISTS idx_devices_tenant_id;
ALTER TABLE devices DROP INDEX IF EXISTS idx_devices_user_id;
ALTER TABLE devices DROP INDEX IF EXISTS idx_devices_last_seen;
ALTER TABLE devices DROP INDEX IF EXISTS idx_devices_tenant_status;

-- -------------------------------------------------------
-- tenants テーブルのインデックスを削除
-- -------------------------------------------------------

ALTER TABLE tenants DROP INDEX IF EXISTS idx_tenants_name;
ALTER TABLE tenants DROP INDEX IF EXISTS idx_tenants_plan;

-- -------------------------------------------------------
-- 削除後の状態を確認
-- -------------------------------------------------------

SHOW INDEX FROM users;
-- PRIMARY と uq_users_email のみ残っていることを確認

-- -------------------------------------------------------
-- Full Table Scan になっていることを EXPLAIN で確認
-- -------------------------------------------------------

-- tenant_id で検索 → type: ALL になること
EXPLAIN
SELECT id, name, email
FROM users
WHERE tenant_id = 'tenant-001';
/*
期待される出力:
+----+-------------+-------+------+---------------+------+---------+------+--------+-------------+
| id | select_type | table | type | possible_keys | key  | key_len | ref  | rows   | Extra       |
+----+-------------+-------+------+---------------+------+---------+------+--------+-------------+
|  1 | SIMPLE      | users | ALL  | NULL          | NULL | NULL    | NULL | 100000 | Using where |
+----+-------------+-------+------+---------------+------+---------+------+--------+-------------+
type=ALL: テーブル全体をスキャン（Full Table Scan）
key=NULL: インデックスが使われていない
rows=100000: 全 100,000 行を読む
*/

-- status で検索 → type: ALL になること
EXPLAIN
SELECT id, name
FROM users
WHERE status = 'active';
/*
期待される出力:
type=ALL, key=NULL, rows=100000
*/

-- tenant_id + status の複合検索 → type: ALL になること
EXPLAIN
SELECT id, name
FROM users
WHERE tenant_id = 'tenant-001'
  AND status = 'active';
/*
期待される出力:
type=ALL, key=NULL, rows=100000
*/

-- -------------------------------------------------------
-- インデックスなしでの実行時間を計測
-- -------------------------------------------------------

SET @start = NOW(6);
SELECT COUNT(*) FROM users WHERE tenant_id = 'tenant-001';
SELECT TIMESTAMPDIFF(MICROSECOND, @start, NOW(6)) AS elapsed_microseconds;
-- インデックスあり: ~1ms、インデックスなし: ~50ms 以上になること

-- -------------------------------------------------------
-- Slow Query が記録されることを確認
-- -------------------------------------------------------

-- slow_query_log が有効であれば、以下のクエリは記録される
-- （long_query_time の値によっては記録されない場合もある）
SELECT SQL_NO_CACHE *
FROM users
WHERE tenant_id = 'tenant-001'
  AND status = 'active'
ORDER BY created_at DESC
LIMIT 100;

-- スロークエリカウントの確認
SHOW STATUS LIKE 'Slow_queries';
