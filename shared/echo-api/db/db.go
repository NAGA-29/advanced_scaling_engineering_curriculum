package db

import (
	"database/sql"
	"fmt"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

// NewDB opens a MySQL connection pool using the given DSN, applies
// recommended pool settings, and verifies connectivity with a ping.
func NewDB(dsn string) (*sql.DB, error) {
	database, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, fmt.Errorf("db: open: %w", err)
	}

	database.SetMaxOpenConns(25)
	database.SetMaxIdleConns(25)
	database.SetConnMaxLifetime(5 * time.Minute)

	if err := database.Ping(); err != nil {
		database.Close()
		return nil, fmt.Errorf("db: ping: %w", err)
	}

	return database, nil
}
