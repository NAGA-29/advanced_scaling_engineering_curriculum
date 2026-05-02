// generate_users.go
// Bulk-inserts synthetic user rows into the `scaling` database.
//
// Usage:
//   go run generate_users.go \
//     --dsn "root:secret@tcp(127.0.0.1:3306)/scaling?parseTime=true" \
//     --count 1000000 \
//     --batch-size 1000 \
//     --tenants 100

package main

import (
	"database/sql"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

func main() {
	// ── flags ────────────────────────────────────────────────────────────────
	dsn       := flag.String("dsn",        "root:secret@tcp(127.0.0.1:3306)/scaling?parseTime=true", "MySQL DSN")
	count     := flag.Int("count",         1_000_000, "Total number of users to insert")
	batchSize := flag.Int("batch-size",    1_000,     "Rows per INSERT statement")
	tenants   := flag.Int("tenants",       100,       "Number of tenants to spread users across")
	flag.Parse()

	// ── graceful interrupt ───────────────────────────────────────────────────
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	done := make(chan struct{})

	go func() {
		defer close(done)
		if err := run(*dsn, *count, *batchSize, *tenants, stop); err != nil {
			log.Fatalf("generate_users: %v", err)
		}
	}()

	select {
	case <-done:
	case sig := <-stop:
		log.Printf("Received signal %s – stopping early.\n", sig)
		<-done
	}
}

func run(dsn string, count, batchSize, tenants int, stop <-chan os.Signal) error {
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return fmt.Errorf("open db: %w", err)
	}
	defer db.Close()

	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(4)
	db.SetConnMaxLifetime(5 * time.Minute)

	if err := db.Ping(); err != nil {
		return fmt.Errorf("ping db: %w", err)
	}
	log.Printf("Connected. Inserting %d users in batches of %d across %d tenants.\n",
		count, batchSize, tenants)

	start := time.Now()
	inserted := 0
	batch := 0

	for inserted < count {
		// Check for interrupt before each batch.
		select {
		case <-stop:
			log.Printf("Interrupted after %d rows.\n", inserted)
			return nil
		default:
		}

		// Calculate how many rows this batch should hold.
		remaining := count - inserted
		thisSize := batchSize
		if remaining < batchSize {
			thisSize = remaining
		}

		if err := insertBatch(db, inserted, thisSize, tenants); err != nil {
			return fmt.Errorf("insertBatch at offset %d: %w", inserted, err)
		}

		inserted += thisSize
		batch++

		if batch%100 == 0 {
			elapsed := time.Since(start).Round(time.Millisecond)
			rate := float64(inserted) / time.Since(start).Seconds()
			log.Printf("  batch %d | rows inserted: %d / %d | %.0f rows/sec | elapsed: %s\n",
				batch, inserted, count, rate, elapsed)
		}
	}

	log.Printf("Done. Inserted %d rows in %s.\n", inserted, time.Since(start).Round(time.Millisecond))
	return nil
}

// insertBatch builds a single multi-row INSERT and executes it.
func insertBatch(db *sql.DB, offset, size, tenants int) error {
	const baseSQL = "INSERT INTO users (tenant_id, name, email, created_at, updated_at) VALUES "

	placeholders := make([]string, size)
	args := make([]interface{}, 0, size*5)

	now := time.Now().UTC().Format("2006-01-02 15:04:05")

	for j := 0; j < size; j++ {
		i := offset + j
		tenantID := (i % tenants) + 1
		name := fmt.Sprintf("User%d", i)
		email := fmt.Sprintf("user%d@example.com", i)

		placeholders[j] = "(?,?,?,?,?)"
		args = append(args, tenantID, name, email, now, now)
	}

	query := baseSQL + strings.Join(placeholders, ",")

	_, err := db.Exec(query, args...)
	return err
}
