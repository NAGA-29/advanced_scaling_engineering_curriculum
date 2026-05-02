package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/redis/go-redis/v9"

	"github.com/advanced-scaling/step11-worker/queue"
)

// ── 設定 ─────────────────────────────────────────────────────────────────────

const (
	StreamName    = "events"
	GroupName     = "workers"
	MaxRetries    = 3
	RetryBaseWait = 100 * time.Millisecond
)

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// ── DB 初期化 ─────────────────────────────────────────────────────────────────

func initDB() (*sql.DB, error) {
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&charset=utf8mb4",
		getEnv("DB_USER", "root"),
		getEnv("DB_PASSWORD", "password"),
		getEnv("DB_HOST", "localhost"),
		getEnv("DB_PORT", "3306"),
		getEnv("DB_NAME", "appdb"),
	)

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, fmt.Errorf("sql.Open: %w", err)
	}

	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)

	// 起動時にテーブルを自動作成
	if err := createTables(db); err != nil {
		return nil, fmt.Errorf("createTables: %w", err)
	}

	return db, nil
}

func createTables(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS events (
			id               BIGINT AUTO_INCREMENT PRIMARY KEY,
			stream_id        VARCHAR(64)  NOT NULL,
			device_id        VARCHAR(128) NOT NULL,
			event_type       VARCHAR(64)  NOT NULL,
			payload          TEXT,
			idempotency_key  VARCHAR(256) NOT NULL DEFAULT '',
			processed_at     DATETIME(3)  NOT NULL,
			created_at       DATETIME(3)  NOT NULL,
			UNIQUE KEY uq_idempotency_key (idempotency_key),
			INDEX idx_device_id (device_id),
			INDEX idx_event_type (event_type),
			INDEX idx_created_at (created_at)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
	`)
	return err
}

// ── イベントプロセッサー ───────────────────────────────────────────────────────

// Processor はイベント処理ロジックを持つ構造体
type Processor struct {
	db     *sql.DB
	logger *log.Logger
}

func NewProcessor(db *sql.DB) *Processor {
	return &Processor{
		db:     db,
		logger: log.New(os.Stdout, "[worker] ", log.LstdFlags|log.Lmicroseconds),
	}
}

// ProcessEvent はイベントを1件処理する
// 冪等性チェック → DB 挿入 の順で行う
func (p *Processor) ProcessEvent(ctx context.Context, event queue.Event) error {
	p.logger.Printf("processing event: id=%s device=%s type=%s idempotency_key=%s",
		event.ID, event.DeviceID, event.EventType, event.IdempotencyKey)

	// ── 冪等性チェック ────────────────────────────────────────────────
	// 同じ idempotency_key が既に処理済みなら スキップ (重複処理防止)
	if event.IdempotencyKey != "" {
		var count int
		err := p.db.QueryRowContext(ctx,
			"SELECT COUNT(*) FROM events WHERE idempotency_key = ?",
			event.IdempotencyKey,
		).Scan(&count)
		if err != nil {
			return fmt.Errorf("idempotency check failed: %w", err)
		}
		if count > 0 {
			p.logger.Printf("SKIP (duplicate): idempotency_key=%s already processed", event.IdempotencyKey)
			return nil // 重複なのでスキップ (正常扱い)
		}
	}

	// ── DB 挿入 ───────────────────────────────────────────────────────
	_, err := p.db.ExecContext(ctx, `
		INSERT INTO events
			(stream_id, device_id, event_type, payload, idempotency_key, processed_at, created_at)
		VALUES
			(?, ?, ?, ?, ?, ?, ?)
	`,
		event.ID,
		event.DeviceID,
		event.EventType,
		event.Payload,
		event.IdempotencyKey,
		time.Now().UTC(),
		event.CreatedAt.UTC(),
	)
	if err != nil {
		return fmt.Errorf("DB insert failed: %w", err)
	}

	p.logger.Printf("SUCCESS: event=%s device=%s type=%s", event.ID, event.DeviceID, event.EventType)
	return nil
}

// ── リトライラッパー ──────────────────────────────────────────────────────────

// withRetry は fn を最大 maxRetries 回実行する
// 指数バックオフ: 100ms → 200ms → 400ms
func withRetry(ctx context.Context, maxRetries int, fn func() error) error {
	var lastErr error
	for attempt := 0; attempt < maxRetries; attempt++ {
		if err := fn(); err != nil {
			lastErr = err
			wait := RetryBaseWait * time.Duration(1<<attempt) // 100ms, 200ms, 400ms
			log.Printf("[retry] attempt=%d/%d error=%v waiting=%v",
				attempt+1, maxRetries, err, wait)

			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(wait):
			}
			continue
		}
		return nil // 成功
	}
	return fmt.Errorf("all %d retries failed: %w", maxRetries, lastErr)
}

// ── メイン ─────────────────────────────────────────────────────────────────────

func main() {
	logger := log.New(os.Stdout, "[worker-main] ", log.LstdFlags)

	// ── 1. DB 接続 ────────────────────────────────────────────────────
	logger.Println("connecting to MySQL...")
	db, err := initDB()
	if err != nil {
		logger.Fatalf("failed to connect to MySQL: %v", err)
	}
	defer db.Close()
	logger.Println("MySQL connected")

	// ── 2. Redis 接続 ─────────────────────────────────────────────────
	logger.Println("connecting to Redis...")
	rdb := redis.NewClient(&redis.Options{
		Addr:     getEnv("REDIS_ADDR", "localhost:6379"),
		Password: getEnv("REDIS_PASSWORD", ""),
		DB:       0,
	})
	ctx := context.Background()
	if _, err := rdb.Ping(ctx).Result(); err != nil {
		logger.Fatalf("failed to connect to Redis: %v", err)
	}
	defer rdb.Close()
	logger.Println("Redis connected")

	// ── 3. Consumer Group 作成 (既存なら無視) ─────────────────────────
	q := queue.NewRedisStreamQueue(rdb)
	if err := q.CreateGroup(ctx, StreamName, GroupName); err != nil {
		logger.Fatalf("failed to create consumer group: %v", err)
	}
	logger.Printf("consumer group ready: stream=%s group=%s", StreamName, GroupName)

	// ── 4. Graceful Shutdown の設定 ───────────────────────────────────
	// SIGINT (Ctrl+C) または SIGTERM を受けたらコンテキストをキャンセル
	cancelCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigCh
		logger.Printf("received signal: %v — shutting down gracefully...", sig)
		cancel() // Subscribe ループを終了させる
	}()

	// ── 5. ワーカー名設定 (複数ワーカー起動時に一意にする) ─────────────
	consumerName := getEnv("WORKER_NAME", fmt.Sprintf("worker-%d", os.Getpid()))
	logger.Printf("starting consumer: name=%s", consumerName)

	// ── 6. イベント購読・処理ループ ───────────────────────────────────
	processor := NewProcessor(db)

	err = q.Subscribe(cancelCtx, StreamName, GroupName, consumerName,
		func(ctx context.Context, event queue.Event) error {
			return withRetry(ctx, MaxRetries, func() error {
				return processor.ProcessEvent(ctx, event)
			})
		},
	)

	if err != nil && !errors.Is(err, context.Canceled) {
		logger.Fatalf("subscribe error: %v", err)
	}

	logger.Println("worker shutdown complete")
}
