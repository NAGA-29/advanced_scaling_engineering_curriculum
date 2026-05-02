// backfill.go migrates users from the source DB to sharded DBs.
//
// Design:
//   - Reads source DB in batches (default 1000 rows per batch)
//   - Uses migration_progress table to track the last processed ID
//   - Routes each row to the correct shard via TenantIDResolver
//   - Uses INSERT IGNORE to safely handle duplicate runs (idempotent)
//   - Handles SIGINT (Ctrl+C) by saving progress before exit
//   - Logs progress every batch
//
// Usage:
//
//	go run backfill.go \
//	  --source-dsn "root:root@tcp(127.0.0.1:3306)/appdb?parseTime=true" \
//	  --shard0-dsn "root:root@tcp(127.0.0.1:3307)/appdb?parseTime=true" \
//	  --shard1-dsn "root:root@tcp(127.0.0.1:3308)/appdb?parseTime=true" \
//	  --batch-size 1000 \
//	  --migration-name "users_sharding_v1"
package main

import (
	"context"
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

// ─── User model ───────────────────────────────────────────────────────────────

type User struct {
	ID        int64
	TenantID  int64
	Name      string
	Email     string
	CreatedAt time.Time
}

// ─── Backfill config ──────────────────────────────────────────────────────────

type BackfillConfig struct {
	SourceDSN     string
	ShardDSNs     []string
	BatchSize     int
	MigrationName string
	SleepBetween  time.Duration // sleep between batches to reduce DB load
}

// ─── Backfill runner ──────────────────────────────────────────────────────────

type Backfiller struct {
	cfg      BackfillConfig
	sourceDB *sql.DB
	resolver *TenantIDResolver

	// Stats
	totalProcessed int64
	totalInserted  int64
	totalSkipped   int64
	startTime      time.Time

	// Interrupt handling
	interrupted int32 // atomic flag set by signal handler
}

// NewBackfiller creates a Backfiller and opens DB connections.
func NewBackfiller(cfg BackfillConfig) (*Backfiller, error) {
	if cfg.BatchSize <= 0 {
		cfg.BatchSize = 1000
	}
	if cfg.MigrationName == "" {
		cfg.MigrationName = "default_migration"
	}
	if cfg.SleepBetween == 0 {
		cfg.SleepBetween = 10 * time.Millisecond
	}

	// Open source DB
	sourceDB, err := sql.Open("mysql", cfg.SourceDSN)
	if err != nil {
		return nil, fmt.Errorf("open source DB: %w", err)
	}
	sourceDB.SetMaxOpenConns(5)
	if err := sourceDB.Ping(); err != nil {
		return nil, fmt.Errorf("ping source DB: %w", err)
	}

	// Open shard DBs via resolver
	resolver, err := NewTenantIDResolver(cfg.ShardDSNs)
	if err != nil {
		sourceDB.Close()
		return nil, fmt.Errorf("create resolver: %w", err)
	}

	return &Backfiller{
		cfg:       cfg,
		sourceDB:  sourceDB,
		resolver:  resolver,
		startTime: time.Now(),
	}, nil
}

// Close releases all DB connections.
func (b *Backfiller) Close() {
	b.sourceDB.Close()
	b.resolver.Close()
}

// ensureMigrationProgressTable creates the migration_progress table if not exists.
func (b *Backfiller) ensureMigrationProgressTable(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS migration_progress (
			migration_name    VARCHAR(255) NOT NULL PRIMARY KEY,
			last_processed_id BIGINT UNSIGNED NOT NULL DEFAULT 0,
			updated_at        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
			                  ON UPDATE CURRENT_TIMESTAMP
		) ENGINE=InnoDB
	`)
	return err
}

// getLastProcessedID reads the last processed ID from the progress table.
// Returns 0 if no progress exists (i.e., start from beginning).
func (b *Backfiller) getLastProcessedID(db *sql.DB) (int64, error) {
	var lastID int64
	err := db.QueryRow(
		`SELECT last_processed_id FROM migration_progress WHERE migration_name = ?`,
		b.cfg.MigrationName,
	).Scan(&lastID)
	if err == sql.ErrNoRows {
		return 0, nil
	}
	return lastID, err
}

// saveProgress writes the last processed ID to all shard progress tables.
func (b *Backfiller) saveProgress(lastID int64) error {
	for i, db := range b.resolver.AllShards() {
		_, err := db.Exec(`
			INSERT INTO migration_progress (migration_name, last_processed_id)
			VALUES (?, ?)
			ON DUPLICATE KEY UPDATE
				last_processed_id = VALUES(last_processed_id),
				updated_at = CURRENT_TIMESTAMP
		`, b.cfg.MigrationName, lastID)
		if err != nil {
			return fmt.Errorf("saveProgress shard %d: %w", i, err)
		}
	}
	return nil
}

// fetchBatch retrieves a batch of users from source DB starting after lastID.
func (b *Backfiller) fetchBatch(ctx context.Context, afterID int64, batchSize int) ([]User, error) {
	rows, err := b.sourceDB.QueryContext(ctx, `
		SELECT id, tenant_id, name, email, created_at
		FROM users
		WHERE id > ?
		ORDER BY id ASC
		LIMIT ?
	`, afterID, batchSize)
	if err != nil {
		return nil, fmt.Errorf("fetchBatch: %w", err)
	}
	defer rows.Close()

	users := make([]User, 0, batchSize)
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.TenantID, &u.Name, &u.Email, &u.CreatedAt); err != nil {
			return nil, fmt.Errorf("fetchBatch Scan: %w", err)
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

// insertBatch inserts a batch of users into the correct shard.
// Groups users by shard to minimize the number of DB round trips.
func (b *Backfiller) insertBatch(ctx context.Context, users []User) (inserted, skipped int, err error) {
	// Group by shard index
	byShardIdx := make(map[int][]User)
	for _, u := range users {
		idx := b.resolver.ShardIndexFor(u.TenantID)
		byShardIdx[idx] = append(byShardIdx[idx], u)
	}

	for idx, shardUsers := range byShardIdx {
		db, err := b.resolver.ResolveByTenantID(int64(idx))
		if err != nil {
			return inserted, skipped, fmt.Errorf("resolve shard %d: %w", idx, err)
		}

		// Build bulk INSERT IGNORE
		query := `INSERT IGNORE INTO users (id, tenant_id, name, email, created_at) VALUES `
		args := make([]interface{}, 0, len(shardUsers)*5)
		for i, u := range shardUsers {
			if i > 0 {
				query += ", "
			}
			query += "(?, ?, ?, ?, ?)"
			args = append(args, u.ID, u.TenantID, u.Name, u.Email, u.CreatedAt)
		}

		result, err := db.ExecContext(ctx, query, args...)
		if err != nil {
			return inserted, skipped, fmt.Errorf("insertBatch shard %d: %w", idx, err)
		}

		rowsAffected, _ := result.RowsAffected()
		inserted += int(rowsAffected)
		skipped += len(shardUsers) - int(rowsAffected) // INSERT IGNORE skips duplicates
	}

	return inserted, skipped, nil
}

// Run executes the backfill until completion or interruption.
func (b *Backfiller) Run(ctx context.Context) error {
	// Ensure progress tables exist on all shards
	for i, db := range b.resolver.AllShards() {
		if err := b.ensureMigrationProgressTable(db); err != nil {
			return fmt.Errorf("ensure progress table shard %d: %w", i, err)
		}
	}

	// Get starting point from any shard (they should agree)
	lastID, err := b.getLastProcessedID(b.resolver.AllShards()[0])
	if err != nil {
		return fmt.Errorf("getLastProcessedID: %w", err)
	}

	if lastID > 0 {
		log.Printf("[backfill] Resuming from id=%d (migration=%s)", lastID, b.cfg.MigrationName)
	} else {
		log.Printf("[backfill] Starting from beginning (migration=%s)", b.cfg.MigrationName)
	}

	log.Printf("[backfill] Config: batch_size=%d, shards=%d, sleep=%s",
		b.cfg.BatchSize, b.resolver.ShardCount(), b.cfg.SleepBetween)

	batchNum := 0
	for {
		// Check for interrupt
		if atomic.LoadInt32(&b.interrupted) == 1 {
			log.Printf("[backfill] Interrupted. Saving progress at id=%d...", lastID)
			if saveErr := b.saveProgress(lastID); saveErr != nil {
				log.Printf("[backfill] WARNING: failed to save progress: %v", saveErr)
			} else {
				log.Printf("[backfill] Progress saved. Resume with: --migration-name %s", b.cfg.MigrationName)
			}
			return fmt.Errorf("interrupted after processing %d rows", atomic.LoadInt64(&b.totalProcessed))
		}

		// Check context cancellation
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		// Fetch next batch
		users, err := b.fetchBatch(ctx, lastID, b.cfg.BatchSize)
		if err != nil {
			return fmt.Errorf("batch %d fetchBatch: %w", batchNum, err)
		}

		if len(users) == 0 {
			// No more rows
			log.Printf("[backfill] Complete! Total processed: %d, inserted: %d, skipped (duplicates): %d",
				atomic.LoadInt64(&b.totalProcessed),
				atomic.LoadInt64(&b.totalInserted),
				atomic.LoadInt64(&b.totalSkipped),
			)
			// Save final progress
			return b.saveProgress(lastID)
		}

		// Insert into shards
		inserted, skipped, err := b.insertBatch(ctx, users)
		if err != nil {
			return fmt.Errorf("batch %d insertBatch: %w", batchNum, err)
		}

		// Update tracking
		lastID = users[len(users)-1].ID
		atomic.AddInt64(&b.totalProcessed, int64(len(users)))
		atomic.AddInt64(&b.totalInserted, int64(inserted))
		atomic.AddInt64(&b.totalSkipped, int64(skipped))
		batchNum++

		// Save progress after each batch
		if err := b.saveProgress(lastID); err != nil {
			log.Printf("[backfill] WARNING: failed to save progress: %v", err)
		}

		// Log progress
		elapsed := time.Since(b.startTime)
		rowsPerSec := float64(atomic.LoadInt64(&b.totalProcessed)) / elapsed.Seconds()
		log.Printf("[backfill] batch=%d last_id=%d processed=%d inserted=%d skipped=%d rate=%.0f rows/s",
			batchNum, lastID,
			atomic.LoadInt64(&b.totalProcessed),
			atomic.LoadInt64(&b.totalInserted),
			atomic.LoadInt64(&b.totalSkipped),
			rowsPerSec,
		)

		// Sleep between batches to reduce load on source DB
		if b.cfg.SleepBetween > 0 {
			time.Sleep(b.cfg.SleepBetween)
		}
	}
}

// SetInterrupted marks the backfiller as interrupted (called by signal handler).
func (b *Backfiller) SetInterrupted() {
	atomic.StoreInt32(&b.interrupted, 1)
}

// ─── main ─────────────────────────────────────────────────────────────────────

func main() {
	var (
		sourceDSN     = flag.String("source-dsn", "", "Source DB DSN (required)")
		shard0DSN     = flag.String("shard0-dsn", "", "Shard 0 DB DSN (required)")
		shard1DSN     = flag.String("shard1-dsn", "", "Shard 1 DB DSN (required)")
		batchSize     = flag.Int("batch-size", 1000, "Rows per batch")
		migrationName = flag.String("migration-name", "users_sharding_v1", "Migration identifier")
		sleepMs       = flag.Int("sleep-ms", 10, "Milliseconds to sleep between batches")
	)
	flag.Parse()

	if *sourceDSN == "" || *shard0DSN == "" || *shard1DSN == "" {
		fmt.Fprintln(os.Stderr, "Error: --source-dsn, --shard0-dsn, and --shard1-dsn are required")
		flag.Usage()
		os.Exit(1)
	}

	cfg := BackfillConfig{
		SourceDSN:     *sourceDSN,
		ShardDSNs:     []string{*shard0DSN, *shard1DSN},
		BatchSize:     *batchSize,
		MigrationName: *migrationName,
		SleepBetween:  time.Duration(*sleepMs) * time.Millisecond,
	}

	backfiller, err := NewBackfiller(cfg)
	if err != nil {
		log.Fatalf("[backfill] Failed to initialize: %v", err)
	}
	defer backfiller.Close()

	// Handle SIGINT / SIGTERM gracefully
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigCh
		log.Printf("[backfill] Received signal: %v. Saving progress before exit...", sig)
		backfiller.SetInterrupted()
	}()

	ctx := context.Background()
	if err := backfiller.Run(ctx); err != nil {
		if err.Error() != "" && err.Error()[:11] == "interrupted" {
			log.Printf("[backfill] Stopped: %v", err)
			os.Exit(0) // graceful exit on interrupt
		}
		log.Fatalf("[backfill] Error: %v", err)
	}

	log.Println("[backfill] Done.")
}
