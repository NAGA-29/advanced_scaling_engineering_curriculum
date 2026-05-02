-- STEP 04 MySQL 初期化
GRANT ALL PRIVILEGES ON appdb.* TO 'apiuser'@'%' IDENTIFIED BY 'apipassword';
FLUSH PRIVILEGES;

USE appdb;

CREATE TABLE IF NOT EXISTS tenants (
  id         VARCHAR(36)  NOT NULL PRIMARY KEY,
  name       VARCHAR(255) NOT NULL,
  plan       VARCHAR(50)  NOT NULL DEFAULT 'free',
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS users (
  id         BIGINT        NOT NULL AUTO_INCREMENT PRIMARY KEY,
  tenant_id  VARCHAR(36)   NOT NULL,
  name       VARCHAR(255)  NOT NULL,
  email      VARCHAR(255)  NOT NULL,
  status     VARCHAR(50)   NOT NULL DEFAULT 'active',
  created_at DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_users_email (email),
  INDEX idx_users_tenant_id (tenant_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- シードデータ
INSERT IGNORE INTO tenants (id, name, plan) VALUES
  ('tenant-001', 'Acme Corp',    'enterprise'),
  ('tenant-002', 'Globex Corp',  'pro'),
  ('tenant-003', 'Initech',      'pro'),
  ('tenant-004', 'Umbrella Ltd', 'free'),
  ('tenant-005', 'Stark',        'enterprise');

-- 1,000 ユーザーをシード
INSERT IGNORE INTO users (tenant_id, name, email, status)
SELECT
  CONCAT('tenant-', LPAD(((n-1) MOD 5) + 1, 3, '0')),
  CONCAT('User ', n),
  CONCAT('user', n, '@example.com'),
  'active'
FROM (
  WITH RECURSIVE nums AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM nums WHERE n < 1000
  )
  SELECT n FROM nums
) AS t;
