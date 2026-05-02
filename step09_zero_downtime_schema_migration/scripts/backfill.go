// backfill.go — ゼロダウンタイムスキーママイグレーション用バックフィルスクリプト
//
// users.name を first_name / last_name に変換する。
// サービス稼働中に安全に実行できるよう設計されている。
//
// 設計:
//   - LIMIT N バッチで少量ずつ UPDATE（長時間トランザクション回避）
//   - migration_progress テーブルで進捗を管理（中断・再開可能）
//   - SIGINT (Ctrl+C) で安全に中断し、次回実行時に続きから再開
//   - バッチ間に sleep を挟むことでDB負荷を軽減
//
// 使用方法:
//   go run scripts/backfill.go \
//     --dsn "root:root@tcp(127.0.0.1:3306)/appdb?parseTime=true" \
//     --batch-size 1000 \
//     --sleep-ms 10 \
//     --table users
package main

import (
	"database/sql"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

// ─── Config ───────────────────────────────────────────────────────────────────

type Config struct {
	DSN           string
	TableName     string
	BatchSize     int
	SleepBetween  time.Duration
	MigrationName string
}

// ─── Backfiller ───────────────────────────────────────────────────────────────

type Backfiller struct {
	db    *sql.DB
	cfg   Config
	stop  int32 // atomic flag
	start time.Time
}

func NewBackfiller(cfg Config) (*Backfiller, error) {
	db, err := sql.Open("mysql", cfg.DSN)
	if err != nil {
		return nil, fmt.Errorf("sql.Open: %w", err)
	}
	db.SetMaxOpenConns(5)
	db.SetMaxIdleConns(2)
	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("ping: %w", err)
	}
	return &Backfiller{db: db, cfg: cfg, start: time.Now()}, nil
}

func (b *Backfiller) Close() { b.db.Close() }

// ensureProgressTable creates the migration_progress table if it doesn't exist.
func (b *Backfiller) ensureProgressTable() error {
	_, err := b.db.Exec(`
		CREATE TABLE IF NOT EXISTS migration_progress (
			migration_name    VARCHAR(255) NOT NULL PRIMARY KEY,
			last_processed_id BIGINT UNSIGNED NOT NULL DEFAULT 0,
			total_processed   BIGINT UNSIGNED NOT NULL DEFAULT 0,
			updated_at        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
			                  ON UPDATE CURRENT_TIMESTAMP
		) ENGINE=InnoDB
	`)
	return err
}

// getProgress reads the last processed ID and total processed count.
func (b *Backfiller) getProgress() (lastID int64, totalDone int64, err error) {
	row := b.db.QueryRow(
		`SELECT last_processed_id, total_processed FROM migration_progress WHERE migration_name = ?`,
		b.cfg.MigrationName,
	)
	err = row.Scan(&lastID, &totalDone)
	if err == sql.ErrNoRows {
		return 0, 0, nil
	}
	return lastID, totalDone, err
}

// saveProgress writes progress to the tracking table.
func (b *Backfiller) saveProgress(lastID, totalDone int64) error {
	_, err := b.db.Exec(`
		INSERT INTO migration_progress (migration_name, last_processed_id, total_processed)
		VALUES (?, ?, ?)
		ON DUPLICATE KEY UPDATE
			last_processed_id = VALUES(last_processed_id),
			total_processed   = VALUES(total_processed),
			updated_at        = CURRENT_TIMESTAMP
	`, b.cfg.MigrationName, lastID, totalDone)
	return err
}

// totalRemaining returns the count of rows not yet migrated.
func (b *Backfiller) totalRemaining() int64 {
	var count int64
	b.db.QueryRow(
		fmt.Sprintf(`SELECT COUNT(*) FROM %s WHERE first_name IS NULL`, b.cfg.TableName),
	).Scan(&count)
	return count
}

// runBatch processes one batch: update up to batchSize rows where first_name IS NULL.
// Returns the number of rows updated.
func (b *Backfiller) runBatch() (updated int64, maxID int64, err error) {
	// Get the max ID of rows we'll update in this batch (for progress tracking)
	row := b.db.QueryRow(fmt.Sprintf(`
		SELECT COALESCE(MAX(sub.id), 0) FROM (
			SELECT id FROM %s WHERE first_name IS NULL LIMIT ?
		) sub
	`, b.cfg.TableName), b.cfg.BatchSize)
	if err = row.Scan(&maxID); err != nil {
		return 0, 0, fmt.Errorf("get batch max id: %w", err)
	}
	if maxID == 0 {
		return 0, 0, nil // nothing to do
	}

	// Update the batch
	result, err := b.db.Exec(fmt.Sprintf(`
		UPDATE %s
		SET
			first_name = SUBSTRING_INDEX(name, ' ', 1),
			last_name  = SUBSTRING_INDEX(name, ' ', -1)
		WHERE first_name IS NULL
		LIMIT ?
	`, b.cfg.TableName), b.cfg.BatchSize)
	if err != nil {
		return 0, maxID, fmt.Errorf("update batch: %w", err)
	}

	affected, _ := result.RowsAffected()
	return affected, maxID, nil
}

// Run executes the backfill until all rows are migrated or interrupted.
func (b *Backfiller) Run() error {
	if err := b.ensureProgressTable(); err != nil {
		return fmt.Errorf("ensure progress table: %w", err)
	}

	lastID, totalDone, err := b.getProgress()
	if err != nil {
		return fmt.Errorf("get progress: %w", err)
	}

	remaining := b.totalRemaining()

	if lastID > 0 {
		log.Printf("[backfill] Resuming: last_id=%d total_done=%d remaining=%d",
			lastID, totalDone, remaining)
	} else {
		log.Printf("[backfill] Starting: total_remaining=%d batch_size=%d sleep=%s",
			remaining, b.cfg.BatchSize, b.cfg.SleepBetween)
	}

	batchNum := 0
	for {
		// Check interrupt flag
		if atomic.LoadInt32(&b.stop) == 1 {
			log.Printf("[backfill] Interrupted after %d batches, %d rows. Saving progress...",
				batchNum, totalDone)
			if err := b.saveProgress(lastID, totalDone); err != nil {
				log.Printf("[backfill] WARNING: could not save progress: %v", err)
			}
			log.Printf("[backfill] Progress saved. Rerun to resume.")
			return nil
		}

		updated, maxID, err := b.runBatch()
		if err != nil {
			return fmt.Errorf("batch %d: %w", batchNum, err)
		}

		if updated == 0 {
			// All done
			remaining = b.totalRemaining()
			log.Printf("[backfill] Complete! batches=%d total_migrated=%d remaining=%d elapsed=%s",
				batchNum, totalDone, remaining, time.Since(b.start).Round(time.Millisecond))
			return b.saveProgress(lastID, totalDone)
		}

		totalDone += updated
		lastID = maxID
		batchNum++

		// Save progress after every batch
		if err := b.saveProgress(lastID, totalDone); err != nil {
			log.Printf("[backfill] WARNING: saveProgress failed: %v", err)
		}

		// Log progress every 10 batches
		elapsed := time.Since(b.start)
		rowsPerSec := float64(totalDone) / elapsed.Seconds()
		remaining = b.totalRemaining()
		log.Printf("[backfill] batch=%d last_id=%d migrated=%d remaining=%d rate=%.0f rows/s",
			batchNum, lastID, totalDone, remaining, rowsPerSec)

		// Sleep to reduce DB load
		if b.cfg.SleepBetween > 0 {
			time.Sleep(b.cfg.SleepBetween)
		}
	}
}

// Stop signals the backfiller to stop after the current batch.
func (b *Backfiller) Stop() {
	atomic.StoreInt32(&b.stop, 1)
}

// ─── main ─────────────────────────────────────────────────────────────────────

func main() {
	var (
		dsn           = flag.String("dsn", "", "MySQL DSN (required)\n  example: root:root@tcp(127.0.0.1:3306)/appdb?parseTime=true")
		tableName     = flag.String("table", "users", "Table to backfill")
		batchSize     = flag.Int("batch-size", 1000, "Rows per batch")
		sleepMs       = flag.Int("sleep-ms", 10, "Milliseconds to sleep between batches")
		migrationName = flag.String("migration-name", "name_to_first_last", "Migration identifier for progress tracking")
	)
	flag.Parse()

	if *dsn == "" {
		*dsn = os.Getenv("DSN")
	}
	if *dsn == "" {
		fmt.Fprintln(os.Stderr, "Error: --dsn is required (or set DSN environment variable)")
		flag.Usage()
		os.Exit(1)
	}

	cfg := Config{
		DSN:           *dsn,
		TableName:     *tableName,
		BatchSize:     *batchSize,
		SleepBetween:  time.Duration(*sleepMs) * time.Millisecond,
		MigrationName: *migrationName,
	}

	backfiller, err := NewBackfiller(cfg)
	if err != nil {
		log.Fatalf("[backfill] Init failed: %v", err)
	}
	defer backfiller.Close()

	// Handle SIGINT / SIGTERM
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigCh
		log.Printf("[backfill] Received %v, stopping after current batch...", sig)
		backfiller.Stop()
	}()

	if err := backfiller.Run(); err != nil {
		log.Fatalf("[backfill] Failed: %v", err)
	}
}
