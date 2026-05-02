-- Advanced Scaling Engineering Curriculum
-- MySQL 8 Schema
-- Used across all modules as the shared data layer

CREATE DATABASE IF NOT EXISTS scaling;
USE scaling;

-- -------------------------------------------------------
-- users
-- Multi-tenant user table.  tenant_id is not a FK here
-- so that we can demonstrate sharding without cross-shard
-- joins to a tenants table.
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    id         BIGINT       NOT NULL AUTO_INCREMENT,
    tenant_id  BIGINT       NOT NULL,
    name       VARCHAR(100) NOT NULL DEFAULT '',
    email      VARCHAR(255) NOT NULL DEFAULT '',
    created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    INDEX idx_tenant_id (tenant_id),
    INDEX idx_email     (email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -------------------------------------------------------
-- devices
-- IoT / edge devices owned by a tenant.
-- device_id is the external identifier sent by the device.
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS devices (
    id         BIGINT       NOT NULL AUTO_INCREMENT,
    tenant_id  BIGINT       NOT NULL,
    device_id  VARCHAR(100) NOT NULL,
    name       VARCHAR(100) NOT NULL DEFAULT '',
    created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_device_id (device_id),
    INDEX idx_tenant_id (tenant_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -------------------------------------------------------
-- heartbeats
-- High-volume time-series table. Each device sends a
-- heartbeat every N seconds.  Designed to be pruned or
-- partitioned in later modules.
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS heartbeats (
    id          BIGINT      NOT NULL AUTO_INCREMENT,
    device_id   VARCHAR(100) NOT NULL DEFAULT '',
    status      VARCHAR(20)  NOT NULL DEFAULT 'ok',
    received_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    INDEX idx_device_received (device_id, received_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -------------------------------------------------------
-- migration_progress
-- Checkpoint table used by background migration jobs so
-- they can resume after a crash / restart without
-- re-processing already-migrated rows.
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS migration_progress (
    id                BIGINT       NOT NULL AUTO_INCREMENT,
    job_name          VARCHAR(100) NOT NULL,
    last_processed_id BIGINT       NOT NULL DEFAULT 0,
    status            VARCHAR(20)  NOT NULL DEFAULT 'running',
    updated_at        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_job_name (job_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
