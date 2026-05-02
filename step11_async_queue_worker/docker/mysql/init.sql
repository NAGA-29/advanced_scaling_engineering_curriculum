-- STEP 11: 初期テーブル作成
-- Worker が自動作成するが、ここでも定義しておく

CREATE DATABASE IF NOT EXISTS appdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE appdb;

CREATE TABLE IF NOT EXISTS events (
    id               BIGINT AUTO_INCREMENT PRIMARY KEY,
    stream_id        VARCHAR(64)  NOT NULL COMMENT 'Redis Stream Message ID',
    device_id        VARCHAR(128) NOT NULL,
    event_type       VARCHAR(64)  NOT NULL,
    payload          TEXT,
    idempotency_key  VARCHAR(256) NOT NULL DEFAULT '' COMMENT '重複処理防止キー',
    processed_at     DATETIME(3)  NOT NULL COMMENT 'Worker が処理した時刻',
    created_at       DATETIME(3)  NOT NULL COMMENT 'イベント発生時刻',
    UNIQUE KEY uq_idempotency_key (idempotency_key),
    INDEX idx_device_id (device_id),
    INDEX idx_event_type (event_type),
    INDEX idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
