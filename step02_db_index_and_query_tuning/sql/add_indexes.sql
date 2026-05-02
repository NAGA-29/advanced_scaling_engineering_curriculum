-- =============================================================
-- STEP 02: インデックス追加 SQL
-- 目的: パフォーマンス改善のためのインデックスを追加する
-- 実行方法:
--   mysql -u apiuser -papipassword appdb < add_indexes.sql
-- =============================================================

USE appdb;

-- -------------------------------------------------------
-- 追加前のインデックス状態を確認
-- -------------------------------------------------------

SHOW INDEX FROM users;
SHOW INDEX FROM devices;
SHOW INDEX FROM tenants;

-- -------------------------------------------------------
-- users テーブルへのインデックス追加
-- -------------------------------------------------------

-- tenant_id インデックス（テナント別ユーザー検索に必須）
-- 存在しない場合のみ追加（エラー回避）
ALTER TABLE users
  ADD INDEX idx_users_tenant_id (tenant_id);

-- status インデックス（ステータス別フィルタリング）
ALTER TABLE users
  ADD INDEX idx_users_status (status);

-- 複合インデックス: テナント + ステータスの同時検索に最適
-- WHERE tenant_id = ? AND status = ? のクエリを高速化
ALTER TABLE users
  ADD INDEX idx_users_tenant_status (tenant_id, status);

-- 複合インデックス: テナント + created_at の降順ソートに使用
-- WHERE tenant_id = ? ORDER BY created_at DESC のページネーションを高速化
ALTER TABLE users
  ADD INDEX idx_users_tenant_created (tenant_id, created_at);

-- -------------------------------------------------------
-- devices テーブルへのインデックス追加
-- -------------------------------------------------------

-- tenant_id インデックス
ALTER TABLE devices
  ADD INDEX idx_devices_tenant_id (tenant_id);

-- user_id インデックス（ユーザーのデバイス一覧取得）
ALTER TABLE devices
  ADD INDEX idx_devices_user_id (user_id);

-- last_seen インデックス（最終アクティブ日時での範囲検索）
ALTER TABLE devices
  ADD INDEX idx_devices_last_seen (last_seen);

-- 複合インデックス: テナント + ステータスの検索
ALTER TABLE devices
  ADD INDEX idx_devices_tenant_status (tenant_id, status);

-- -------------------------------------------------------
-- tenants テーブルへのインデックス追加
-- -------------------------------------------------------

-- name インデックス（テナント名での検索）
ALTER TABLE tenants
  ADD INDEX idx_tenants_name (name);

-- plan インデックス（プラン別テナント一覧）
ALTER TABLE tenants
  ADD INDEX idx_tenants_plan (plan);

-- -------------------------------------------------------
-- 追加後のインデックス状態を確認
-- -------------------------------------------------------

SHOW INDEX FROM users;
SHOW INDEX FROM devices;
SHOW INDEX FROM tenants;

-- -------------------------------------------------------
-- 追加したインデックスの効果を EXPLAIN で確認
-- -------------------------------------------------------

-- テナント別ユーザー検索（idx_users_tenant_id を使う）
EXPLAIN
SELECT id, name, email
FROM users
WHERE tenant_id = 'tenant-001'
ORDER BY id
LIMIT 20;
-- 期待: type=ref, key=idx_users_tenant_id

-- テナント + ステータスの検索（idx_users_tenant_status を使う）
EXPLAIN
SELECT id, name, email
FROM users
WHERE tenant_id = 'tenant-001'
  AND status = 'active';
-- 期待: type=ref, key=idx_users_tenant_status

-- ページネーション（idx_users_tenant_created を使う）
EXPLAIN
SELECT id, name, email, created_at
FROM users
WHERE tenant_id = 'tenant-001'
ORDER BY created_at DESC
LIMIT 20;
-- 期待: type=ref, key=idx_users_tenant_created

-- -------------------------------------------------------
-- インデックスのサイズ確認（オプション）
-- -------------------------------------------------------

SELECT
  TABLE_NAME,
  INDEX_NAME,
  ROUND(SUM(stat_value * @@innodb_page_size) / 1024 / 1024, 2) AS size_mb
FROM mysql.innodb_index_stats
WHERE database_name = 'appdb'
  AND stat_name = 'size'
GROUP BY TABLE_NAME, INDEX_NAME
ORDER BY TABLE_NAME, size_mb DESC;
