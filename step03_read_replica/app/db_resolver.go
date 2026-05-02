// Package main demonstrates the Read/Write DB split pattern using a DBCluster.
// Primary handles all writes; Replica handles reads and falls back to Primary
// if the Replica is unavailable.
package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/go-sql-driver/mysql"
)

// -------------------------------------------------------
// DBCluster: Read/Write DB 分離の中心クラス
// -------------------------------------------------------

// DBCluster holds separate connection pools for the primary (write) and
// replica (read) databases.  If the replica is nil or unavailable, all
// queries fall back to the primary.
type DBCluster struct {
	primary        *sql.DB
	replica        *sql.DB
	mu             sync.RWMutex
	replicaHealthy bool
}

// NewDBCluster creates a DBCluster.  replicaDSN may be empty; in that case
// the cluster operates in primary-only mode.
func NewDBCluster(primaryDSN, replicaDSN string) (*DBCluster, error) {
	primary, err := openDB(primaryDSN)
	if err != nil {
		return nil, fmt.Errorf("primary DB open: %w", err)
	}

	c := &DBCluster{
		primary:        primary,
		replicaHealthy: false,
	}

	if replicaDSN != "" {
		replica, err := openDB(replicaDSN)
		if err != nil {
			log.Printf("[WARN] replica DB open failed (will use primary only): %v", err)
		} else {
			c.replica = replica
			c.replicaHealthy = true
		}
	}

	// Background goroutine: replica 死活監視（5 秒ごと）
	go c.watchReplica()

	return c, nil
}

// openDB opens a MySQL connection pool and verifies connectivity with retries.
func openDB(dsn string) (*sql.DB, error) {
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, err
	}

	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(10)
	db.SetConnMaxLifetime(5 * time.Minute)
	db.SetConnMaxIdleTime(2 * time.Minute)

	// 接続確認（最大 5 回リトライ）
	for i := 1; i <= 5; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		err = db.PingContext(ctx)
		cancel()
		if err == nil {
			return db, nil
		}
		log.Printf("[INFO] DB ping attempt %d/5 failed: %v", i, err)
		time.Sleep(2 * time.Second)
	}

	return nil, fmt.Errorf("cannot connect to DB after 5 attempts: %w", err)
}

// Writer returns the primary database connection pool.
// Always use this for INSERT / UPDATE / DELETE.
func (c *DBCluster) Writer() *sql.DB {
	return c.primary
}

// Reader returns the replica connection pool if it is healthy; otherwise it
// falls back to the primary connection pool.
//
// Fallback は自動で行われるため、呼び出し側はどちらが返されるかを意識しなくてよい。
// ただし、書き込み直後に一貫したデータを読む必要がある場合は Writer() を使うこと。
func (c *DBCluster) Reader() *sql.DB {
	c.mu.RLock()
	healthy := c.replicaHealthy
	replica := c.replica
	c.mu.RUnlock()

	if healthy && replica != nil {
		return replica
	}

	log.Println("[WARN] replica unavailable, falling back to primary")
	return c.primary
}

// IsReplicaHealthy reports whether the replica is currently reachable.
func (c *DBCluster) IsReplicaHealthy() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.replicaHealthy
}

// watchReplica periodically checks replica availability and updates the
// replicaHealthy flag.  This runs as a background goroutine.
func (c *DBCluster) watchReplica() {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		if c.replica == nil {
			continue
		}

		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		err := c.replica.PingContext(ctx)
		cancel()

		c.mu.Lock()
		if err != nil {
			if c.replicaHealthy {
				log.Printf("[WARN] replica became unhealthy: %v", err)
			}
			c.replicaHealthy = false
		} else {
			if !c.replicaHealthy {
				log.Println("[INFO] replica recovered and is healthy again")
			}
			c.replicaHealthy = true
		}
		c.mu.Unlock()
	}
}

// Close closes both primary and replica connection pools.
func (c *DBCluster) Close() {
	if c.primary != nil {
		c.primary.Close()
	}
	if c.replica != nil {
		c.replica.Close()
	}
}

// -------------------------------------------------------
// User モデルと DB 操作
// -------------------------------------------------------

// User represents a row in the users table.
type User struct {
	ID        int64     `json:"id"`
	TenantID  string    `json:"tenant_id"`
	Name      string    `json:"name"`
	Email     string    `json:"email"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

// GetUser fetches a user by ID using the replica (read) connection.
// Falls back to primary automatically via DBCluster.Reader().
func GetUser(ctx context.Context, cluster *DBCluster, id int64) (*User, error) {
	db := cluster.Reader() // Replica or Primary fallback

	var u User
	err := db.QueryRowContext(ctx,
		`SELECT id, tenant_id, name, email, status, created_at
		   FROM users
		  WHERE id = ?`,
		id,
	).Scan(&u.ID, &u.TenantID, &u.Name, &u.Email, &u.Status, &u.CreatedAt)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("GetUser: %w", err)
	}
	return &u, nil
}

// ListUsersByTenant fetches up to 100 users for a given tenant using the replica.
func ListUsersByTenant(ctx context.Context, cluster *DBCluster, tenantID string) ([]User, error) {
	db := cluster.Reader() // Replica or Primary fallback

	rows, err := db.QueryContext(ctx,
		`SELECT id, tenant_id, name, email, status, created_at
		   FROM users
		  WHERE tenant_id = ?
		  ORDER BY id
		  LIMIT 100`,
		tenantID,
	)
	if err != nil {
		return nil, fmt.Errorf("ListUsersByTenant: %w", err)
	}
	defer rows.Close()

	var users []User
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.TenantID, &u.Name, &u.Email, &u.Status, &u.CreatedAt); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

// CreateUser inserts a new user using the primary (write) connection.
func CreateUser(ctx context.Context, cluster *DBCluster, tenantID, name, email string) (int64, error) {
	db := cluster.Writer() // Always use Primary for writes

	res, err := db.ExecContext(ctx,
		`INSERT INTO users (tenant_id, name, email) VALUES (?, ?, ?)`,
		tenantID, name, email,
	)
	if err != nil {
		return 0, fmt.Errorf("CreateUser: %w", err)
	}

	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("LastInsertId: %w", err)
	}
	return id, nil
}

// -------------------------------------------------------
// 簡易 HTTP サーバー（動作確認用）
// -------------------------------------------------------

var cluster *DBCluster

func main() {
	// DSN を環境変数から構築
	primaryDSN := buildDSN(
		getEnv("DB_USER", "apiuser"),
		getEnv("DB_PASSWORD", "apipassword"),
		getEnv("DB_PRIMARY_HOST", "127.0.0.1"),
		getEnv("DB_PRIMARY_PORT", "3307"),
		getEnv("DB_NAME", "appdb"),
	)

	replicaDSN := ""
	replicaHost := getEnv("DB_REPLICA_HOST", "")
	replicaPort := getEnv("DB_REPLICA_PORT", "3308")
	if replicaHost != "" {
		replicaDSN = buildDSN(
			getEnv("DB_USER", "apiuser"),
			getEnv("DB_PASSWORD", "apipassword"),
			replicaHost,
			replicaPort,
			getEnv("DB_NAME", "appdb"),
		)
	}

	var err error
	cluster, err = NewDBCluster(primaryDSN, replicaDSN)
	if err != nil {
		log.Fatalf("NewDBCluster: %v", err)
	}
	defer cluster.Close()

	mux := http.NewServeMux()

	// GET /health → Primary と Replica の状態を返す
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		primaryErr := cluster.primary.PingContext(r.Context())
		replicaHealthy := cluster.IsReplicaHealthy()

		status := "ok"
		if primaryErr != nil {
			status = "ng"
			w.WriteHeader(http.StatusServiceUnavailable)
		}

		fmt.Fprintf(w, `{"status":%q,"primary_ok":%v,"replica_healthy":%v}`,
			status,
			primaryErr == nil,
			replicaHealthy,
		)
	})

	// GET /users/{id} → Replica で読む（Fallback あり）
	mux.HandleFunc("/users/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		idStr := r.URL.Path[len("/users/"):]
		id, err := strconv.ParseInt(idStr, 10, 64)
		if err != nil {
			http.Error(w, "invalid id", http.StatusBadRequest)
			return
		}

		u, err := GetUser(r.Context(), cluster, id)
		if err != nil {
			log.Printf("[ERROR] GetUser(%d): %v", id, err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		if u == nil {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"id":%d,"tenant_id":%q,"name":%q,"email":%q,"status":%q}`,
			u.ID, u.TenantID, u.Name, u.Email, u.Status)
	})

	// POST /users → Primary に書き込む
	mux.HandleFunc("/users", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			// GET /users?tenant_id=... の場合
			tenantID := r.URL.Query().Get("tenant_id")
			if tenantID == "" {
				http.Error(w, "tenant_id required", http.StatusBadRequest)
				return
			}
			users, err := ListUsersByTenant(r.Context(), cluster, tenantID)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"count":%d,"replica_used":%v}`, len(users), cluster.IsReplicaHealthy())
			return
		}

		// POST: ユーザー作成
		r.ParseForm()
		tenantID := r.FormValue("tenant_id")
		name := r.FormValue("name")
		email := r.FormValue("email")

		if tenantID == "" || name == "" || email == "" {
			http.Error(w, "tenant_id, name, email are required", http.StatusBadRequest)
			return
		}

		id, err := CreateUser(r.Context(), cluster, tenantID, name, email)
		if err != nil {
			log.Printf("[ERROR] CreateUser: %v", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		fmt.Fprintf(w, `{"id":%d}`, id)
	})

	port := getEnv("PORT", "8080")
	log.Printf("[INFO] Starting server on :%s (replica_host=%s)", port, replicaHost)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatalf("ListenAndServe: %v", err)
	}
}

// -------------------------------------------------------
// ヘルパー関数
// -------------------------------------------------------

func buildDSN(user, password, host, port, dbname string) string {
	cfg := mysql.NewConfig()
	cfg.User = user
	cfg.Passwd = password
	cfg.Net = "tcp"
	cfg.Addr = fmt.Sprintf("%s:%s", host, port)
	cfg.DBName = dbname
	cfg.ParseTime = true
	cfg.Params = map[string]string{
		"charset": "utf8mb4",
	}
	return cfg.FormatDSN()
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
