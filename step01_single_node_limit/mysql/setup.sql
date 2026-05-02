-- =============================================================
-- STEP 01: MySQL セットアップ・シードデータ・slow query 設定
-- 実行方法:
--   mysql -u apiuser -papipassword appdb < setup.sql
-- または EC2 内で:
--   mysql -u apiuser -papipassword appdb
--   source /tmp/setup.sql
-- =============================================================

USE appdb;

-- -------------------------------------------------------
-- 1. テーブル定義（べき等: すでに存在する場合はスキップ）
-- -------------------------------------------------------

CREATE TABLE IF NOT EXISTS tenants (
  id         VARCHAR(36)  NOT NULL PRIMARY KEY,
  name       VARCHAR(255) NOT NULL,
  plan       VARCHAR(50)  NOT NULL DEFAULT 'free',
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  INDEX idx_tenants_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS users (
  id         BIGINT        NOT NULL AUTO_INCREMENT PRIMARY KEY,
  tenant_id  VARCHAR(36)   NOT NULL,
  name       VARCHAR(255)  NOT NULL,
  email      VARCHAR(255)  NOT NULL,
  status     VARCHAR(50)   NOT NULL DEFAULT 'active',
  created_at DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_users_email (email),
  INDEX idx_users_tenant_id (tenant_id),
  INDEX idx_users_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS devices (
  id         BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
  tenant_id  VARCHAR(36)  NOT NULL,
  user_id    BIGINT       NOT NULL,
  device_key VARCHAR(255) NOT NULL,
  status     VARCHAR(50)  NOT NULL DEFAULT 'active',
  last_seen  DATETIME     NULL,
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_devices_key (device_key),
  INDEX idx_devices_tenant_id (tenant_id),
  INDEX idx_devices_user_id (user_id),
  INDEX idx_devices_last_seen (last_seen)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -------------------------------------------------------
-- 2. テナントシードデータ（10 テナント）
-- -------------------------------------------------------

INSERT IGNORE INTO tenants (id, name, plan) VALUES
  ('tenant-001', 'Acme Corp',        'enterprise'),
  ('tenant-002', 'Globex Corp',      'pro'),
  ('tenant-003', 'Initech',          'pro'),
  ('tenant-004', 'Umbrella Ltd',     'free'),
  ('tenant-005', 'Stark Industries', 'enterprise'),
  ('tenant-006', 'Wayne Enterprises','pro'),
  ('tenant-007', 'Oscorp',           'free'),
  ('tenant-008', 'Nakatomi Corp',    'free'),
  ('tenant-009', 'Cyberdyne Systems','enterprise'),
  ('tenant-010', 'Weyland Corp',     'pro');

-- -------------------------------------------------------
-- 3. ユーザーシードデータ（100,000 件）
--    テナントごとに約 10,000 件を均等に分散
-- -------------------------------------------------------

-- ストアドプロシージャで大量データを投入
DROP PROCEDURE IF EXISTS seed_users;

DELIMITER $$
CREATE PROCEDURE seed_users()
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE tenant_num INT;
  DECLARE tenant_id_val VARCHAR(36);

  -- 既存データが少ない場合のみ投入（べき等性のため）
  IF (SELECT COUNT(*) FROM users) < 100000 THEN
    WHILE i <= 100000 DO
      SET tenant_num = ((i - 1) MOD 10) + 1;
      SET tenant_id_val = CONCAT('tenant-', LPAD(tenant_num, 3, '0'));

      INSERT IGNORE INTO users (tenant_id, name, email, status)
      VALUES (
        tenant_id_val,
        CONCAT('User ', i),
        CONCAT('user', i, '@example.com'),
        CASE (i MOD 5)
          WHEN 0 THEN 'inactive'
          ELSE 'active'
        END
      );

      SET i = i + 1;
    END WHILE;
  END IF;
END$$
DELIMITER ;

CALL seed_users();
DROP PROCEDURE IF EXISTS seed_users;

-- 投入件数の確認
SELECT 'users count' AS label, COUNT(*) AS count FROM users;
SELECT 'tenants count' AS label, COUNT(*) AS count FROM tenants;

-- テナント別のユーザー数を確認
SELECT tenant_id, COUNT(*) AS user_count
FROM users
GROUP BY tenant_id
ORDER BY tenant_id;

-- -------------------------------------------------------
-- 4. Slow Query Log の設定
-- -------------------------------------------------------

-- slow query log を有効化
SET GLOBAL slow_query_log = 1;
SET GLOBAL slow_query_log_file = '/var/log/mysql/slow.log';

-- 1 秒以上かかるクエリをスロークエリとして記録
SET GLOBAL long_query_time = 1;

-- インデックスを使っていないクエリも記録（Index なし検証で使用）
SET GLOBAL log_queries_not_using_indexes = 1;

-- 現在の設定を確認
SHOW VARIABLES LIKE 'slow_query_log%';
SHOW VARIABLES LIKE 'long_query_time';
SHOW VARIABLES LIKE 'log_queries_not_using_indexes';

-- -------------------------------------------------------
-- 5. MySQL 接続数・バッファ設定の確認
-- -------------------------------------------------------

-- 最大接続数
SHOW VARIABLES LIKE 'max_connections';

-- バッファプールサイズ（t3.micro では 128MB 程度）
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';

-- 現在の接続状態
SHOW STATUS LIKE 'Threads_connected';
SHOW STATUS LIKE 'Max_used_connections';

-- -------------------------------------------------------
-- 6. インデックスの確認
-- -------------------------------------------------------

-- users テーブルのインデックス一覧
SHOW INDEX FROM users;

-- EXPLAIN でインデックスが使われていることを確認
EXPLAIN SELECT id, name, email FROM users WHERE id = 1;
-- type: const, key: PRIMARY を確認

EXPLAIN SELECT id, name, email FROM users WHERE tenant_id = 'tenant-001' LIMIT 10;
-- type: ref, key: idx_users_tenant_id を確認

EXPLAIN SELECT id, name, email FROM users WHERE email = 'user1@example.com';
-- type: const, key: uq_users_email を確認

-- -------------------------------------------------------
-- 7. アプリケーションユーザーの権限確認
-- -------------------------------------------------------

SHOW GRANTS FOR 'apiuser'@'localhost';
SHOW GRANTS FOR 'apiuser'@'127.0.0.1';
