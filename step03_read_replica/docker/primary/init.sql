-- =============================================================
-- Primary 初期化 SQL
-- Docker コンテナ初回起動時に自動実行される
-- =============================================================

-- レプリケーション用ユーザーの作成
CREATE USER IF NOT EXISTS 'replicator'@'%'
  IDENTIFIED WITH mysql_native_password BY 'replicator_pass';
GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'%';

-- apiuser にも % からのアクセスを許可（Docker ネットワーク内から接続するため）
GRANT ALL PRIVILEGES ON appdb.* TO 'apiuser'@'%';
FLUSH PRIVILEGES;

-- テーブル作成
USE appdb;

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
  INDEX idx_devices_user_id (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- シードデータ（テナント）
INSERT IGNORE INTO tenants (id, name, plan) VALUES
  ('tenant-001', 'Acme Corp',        'enterprise'),
  ('tenant-002', 'Globex Corp',      'pro'),
  ('tenant-003', 'Initech',          'pro'),
  ('tenant-004', 'Umbrella Ltd',     'free'),
  ('tenant-005', 'Stark Industries', 'enterprise');

-- シードデータ（ユーザー 1,000 件 - テナントごとに 200 件）
INSERT IGNORE INTO users (tenant_id, name, email, status)
SELECT
  CONCAT('tenant-', LPAD(((n-1) MOD 5) + 1, 3, '0')),
  CONCAT('User ', n),
  CONCAT('user', n, '@example.com'),
  CASE (n MOD 5) WHEN 0 THEN 'inactive' ELSE 'active' END
FROM (
  WITH RECURSIVE nums AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM nums WHERE n < 1000
  )
  SELECT n FROM nums
) AS t;
