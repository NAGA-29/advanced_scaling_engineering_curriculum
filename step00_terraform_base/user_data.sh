#!/bin/bash
# EC2 User Data Script for Go/Echo API + MySQL 8.0
# Amazon Linux 2023
# This script runs once on first boot as root.

set -euxo pipefail
exec > /var/log/user-data.log 2>&1

echo "=== START user_data.sh ==="
date

# -------------------------------------------------------
# 1. System update
# -------------------------------------------------------
dnf update -y
dnf install -y \
  git \
  wget \
  curl \
  tar \
  gzip \
  jq \
  htop \
  unzip \
  tree

# -------------------------------------------------------
# 2. Install Go 1.22
# -------------------------------------------------------
GO_VERSION="1.22.4"
GO_ARCH="linux-amd64"
GO_TAR="go${GO_VERSION}.${GO_ARCH}.tar.gz"
GO_URL="https://go.dev/dl/${GO_TAR}"

echo "Installing Go ${GO_VERSION}..."
wget -q "${GO_URL}" -O "/tmp/${GO_TAR}"
rm -rf /usr/local/go
tar -C /usr/local -xzf "/tmp/${GO_TAR}"
rm -f "/tmp/${GO_TAR}"

# Set Go environment for root and ec2-user
for PROFILE in /etc/profile.d/go.sh /home/ec2-user/.bashrc; do
  cat >> "${PROFILE}" <<'GOENV'
export GOROOT=/usr/local/go
export GOPATH=/home/ec2-user/go
export PATH=$PATH:/usr/local/go/bin:/home/ec2-user/go/bin
GOENV
done

export GOROOT=/usr/local/go
export GOPATH=/root/go
export PATH=$PATH:/usr/local/go/bin:/root/go/bin

go version

# -------------------------------------------------------
# 3. Install MySQL 8.0 client tools
# -------------------------------------------------------
echo "Installing MySQL 8.0 client..."
dnf install -y mysql8.0

# -------------------------------------------------------
# 4. Install and configure MySQL 8.0 server
# -------------------------------------------------------
echo "Installing MySQL 8.0 server..."
dnf install -y mysql8.0-server

systemctl enable mysqld
systemctl start mysqld

# Wait for MySQL to start
echo "Waiting for MySQL to start..."
for i in $(seq 1 30); do
  if mysqladmin ping --silent 2>/dev/null; then
    echo "MySQL is up after ${i} attempts"
    break
  fi
  sleep 2
done

# Get temporary root password (may not apply on Amazon Linux 2023 package)
TEMP_PASS=$(grep 'temporary password' /var/log/mysqld.log 2>/dev/null | tail -1 | awk '{print $NF}' || echo "")

# Configure MySQL root and create application DB/user
if [ -n "${TEMP_PASS}" ]; then
  # When temporary password exists
  mysql --connect-expired-password -u root -p"${TEMP_PASS}" <<MYSQL_INIT
ALTER USER 'root'@'localhost' IDENTIFIED BY 'RootPassword123!';
MYSQL_INIT
  MYSQL_CMD="mysql -u root -pRootPassword123!"
else
  # Amazon Linux 2023 MySQL package may start without password
  MYSQL_CMD="mysql -u root"
fi

${MYSQL_CMD} <<MYSQL_SETUP
-- Create application database
CREATE DATABASE IF NOT EXISTS appdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Create application user
CREATE USER IF NOT EXISTS 'apiuser'@'localhost' IDENTIFIED BY 'apipassword';
GRANT ALL PRIVILEGES ON appdb.* TO 'apiuser'@'localhost';

-- Allow connections from 127.0.0.1 as well
CREATE USER IF NOT EXISTS 'apiuser'@'127.0.0.1' IDENTIFIED BY 'apipassword';
GRANT ALL PRIVILEGES ON appdb.* TO 'apiuser'@'127.0.0.1';

FLUSH PRIVILEGES;

-- Create tables
USE appdb;

CREATE TABLE IF NOT EXISTS tenants (
  id         VARCHAR(36)  NOT NULL PRIMARY KEY,
  name       VARCHAR(255) NOT NULL,
  plan       VARCHAR(50)  NOT NULL DEFAULT 'free',
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  INDEX idx_tenants_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS users (
  id         BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
  tenant_id  VARCHAR(36)  NOT NULL,
  name       VARCHAR(255) NOT NULL,
  email      VARCHAR(255) NOT NULL,
  status     VARCHAR(50)  NOT NULL DEFAULT 'active',
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_users_email (email),
  INDEX idx_users_tenant_id (tenant_id),
  INDEX idx_users_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS devices (
  id         BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
  tenant_id  VARCHAR(36)  NOT NULL,
  user_id    BIGINT       NOT NULL,
  device_key VARCHAR(255) NOT NULL,
  status     VARCHAR(50)  NOT NULL DEFAULT 'active',
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_devices_key (device_key),
  INDEX idx_devices_tenant_id (tenant_id),
  INDEX idx_devices_user_id (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Seed data: 1 tenant, 100 users
INSERT IGNORE INTO tenants (id, name, plan) VALUES ('tenant-001', 'Acme Corp', 'pro');

INSERT IGNORE INTO users (tenant_id, name, email, status)
SELECT
  'tenant-001',
  CONCAT('user-', n),
  CONCAT('user', n, '@example.com'),
  'active'
FROM (
  SELECT a.n + b.n * 10 + 1 AS n
  FROM
    (SELECT 0 AS n UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
     UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
    (SELECT 0 AS n UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
     UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
) nums
WHERE n <= 100;

-- Configure slow query log
SET GLOBAL slow_query_log = 1;
SET GLOBAL slow_query_log_file = '/var/log/mysql/slow.log';
SET GLOBAL long_query_time = 1;
SET GLOBAL log_queries_not_using_indexes = 1;
MYSQL_SETUP

echo "MySQL setup complete."

# Create slow query log directory
mkdir -p /var/log/mysql
chown mysql:mysql /var/log/mysql

# -------------------------------------------------------
# 5. Build Go/Echo API
# -------------------------------------------------------
APP_DIR="/opt/go-echo-api"
mkdir -p "${APP_DIR}"

cat > "${APP_DIR}/main.go" <<'GOAPP'
package main

import (
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
	_ "github.com/go-sql-driver/mysql"
)

type User struct {
	ID        int64     `json:"id"`
	TenantID  string    `json:"tenant_id"`
	Name      string    `json:"name"`
	Email     string    `json:"email"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

type CreateUserRequest struct {
	TenantID string `json:"tenant_id" validate:"required"`
	Name     string `json:"name"      validate:"required"`
	Email    string `json:"email"     validate:"required"`
}

var db *sql.DB

func initDB() {
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&charset=utf8mb4",
		getEnv("DB_USER", "apiuser"),
		getEnv("DB_PASSWORD", "apipassword"),
		getEnv("DB_HOST", "127.0.0.1"),
		getEnv("DB_PORT", "3306"),
		getEnv("DB_NAME", "appdb"),
	)

	var err error
	db, err = sql.Open("mysql", dsn)
	if err != nil {
		log.Fatalf("failed to open db: %v", err)
	}

	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(10)
	db.SetConnMaxLifetime(5 * time.Minute)

	// Retry connect
	for i := 0; i < 10; i++ {
		if err = db.Ping(); err == nil {
			log.Println("DB connected")
			return
		}
		log.Printf("DB ping failed (%d/10): %v", i+1, err)
		time.Sleep(2 * time.Second)
	}
	log.Fatalf("cannot connect to DB: %v", err)
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	initDB()

	e := echo.New()
	e.Use(middleware.Logger())
	e.Use(middleware.Recover())
	e.Use(middleware.RequestID())

	e.GET("/health", func(c echo.Context) error {
		if err := db.Ping(); err != nil {
			return c.JSON(http.StatusServiceUnavailable, map[string]string{
				"status": "ng", "error": err.Error(),
			})
		}
		return c.JSON(http.StatusOK, map[string]string{"status": "ok"})
	})

	e.GET("/users/:id", func(c echo.Context) error {
		id, err := strconv.ParseInt(c.Param("id"), 10, 64)
		if err != nil {
			return c.JSON(http.StatusBadRequest, map[string]string{"error": "invalid id"})
		}

		var u User
		err = db.QueryRowContext(c.Request().Context(),
			"SELECT id, tenant_id, name, email, status, created_at FROM users WHERE id = ?", id,
		).Scan(&u.ID, &u.TenantID, &u.Name, &u.Email, &u.Status, &u.CreatedAt)

		if err == sql.ErrNoRows {
			return c.JSON(http.StatusNotFound, map[string]string{"error": "not found"})
		}
		if err != nil {
			return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
		}
		return c.JSON(http.StatusOK, u)
	})

	e.POST("/users", func(c echo.Context) error {
		var req CreateUserRequest
		if err := c.Bind(&req); err != nil {
			return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
		}

		res, err := db.ExecContext(c.Request().Context(),
			"INSERT INTO users (tenant_id, name, email) VALUES (?, ?, ?)",
			req.TenantID, req.Name, req.Email,
		)
		if err != nil {
			return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
		}

		id, _ := res.LastInsertId()
		return c.JSON(http.StatusCreated, map[string]interface{}{"id": id})
	})

	e.GET("/users", func(c echo.Context) error {
		tenantID := c.QueryParam("tenant_id")
		if tenantID == "" {
			return c.JSON(http.StatusBadRequest, map[string]string{"error": "tenant_id required"})
		}

		rows, err := db.QueryContext(c.Request().Context(),
			"SELECT id, tenant_id, name, email, status, created_at FROM users WHERE tenant_id = ? ORDER BY id LIMIT 100",
			tenantID,
		)
		if err != nil {
			return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
		}
		defer rows.Close()

		var users []User
		for rows.Next() {
			var u User
			if err := rows.Scan(&u.ID, &u.TenantID, &u.Name, &u.Email, &u.Status, &u.CreatedAt); err != nil {
				return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
			}
			users = append(users, u)
		}
		return c.JSON(http.StatusOK, users)
	})

	port := getEnv("PORT", "8080")
	log.Printf("Starting server on :%s", port)
	e.Logger.Fatal(e.Start(":" + port))
}
GOAPP

# go.mod と go.sum を生成
cd "${APP_DIR}"
/usr/local/go/bin/go mod init go-echo-api
/usr/local/go/bin/go get github.com/labstack/echo/v4@v4.12.0
/usr/local/go/bin/go get github.com/labstack/echo/v4/middleware
/usr/local/go/bin/go get github.com/go-sql-driver/mysql@v1.8.1
/usr/local/go/bin/go mod tidy

# ビルド
/usr/local/go/bin/go build -o /usr/local/bin/go-echo-api .
echo "Go API build complete."

# -------------------------------------------------------
# 6. systemd サービス登録
# -------------------------------------------------------
cat > /etc/systemd/system/go-echo-api.service <<SYSTEMD
[Unit]
Description=Go Echo API Server
After=network.target mysqld.service
Requires=mysqld.service

[Service]
Type=simple
User=ec2-user
ExecStart=/usr/local/bin/go-echo-api
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=go-echo-api

Environment=PORT=8080
Environment=DB_HOST=127.0.0.1
Environment=DB_PORT=3306
Environment=DB_USER=apiuser
Environment=DB_PASSWORD=apipassword
Environment=DB_NAME=appdb

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable go-echo-api
systemctl start go-echo-api

# -------------------------------------------------------
# 7. 起動確認
# -------------------------------------------------------
sleep 5
if curl -sf http://localhost:8080/health > /dev/null; then
  echo "=== API is UP ==="
else
  echo "=== API health check FAILED. Check: journalctl -u go-echo-api ==="
fi

echo "=== END user_data.sh ==="
date
