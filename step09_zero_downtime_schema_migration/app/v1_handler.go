// v1_handler.go — Phase 1 互換ハンドラー
//
// このハンドラーは Expand フェーズ（first_name/last_name カラム追加後）にデプロイする。
//
// 互換モードの動作:
//   - 読み取り: name カラムから読む（first_name/last_name がある場合はそちらも返す）
//   - 書き込み: name に書く + first_name/last_name にも書く（ダブルライト）
//
// これにより:
//   - Expand 後の新規書き込みは両方のカラムに保存される
//   - バックフィルが完了する前でも v2 への移行準備が整う
//   - v2 へのロールバックも v1 への切り戻しも安全に行える
package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

// ─── Models ───────────────────────────────────────────────────────────────────

// UserV1 is the user model for the v1 compatible handler.
// It always has name, and optionally has first_name/last_name.
type UserV1 struct {
	ID        int64   `json:"id"`
	Name      string  `json:"name"`
	FirstName *string `json:"first_name,omitempty"` // nil if column doesn't exist yet
	LastName  *string `json:"last_name,omitempty"`  // nil if column doesn't exist yet
	Email     string  `json:"email"`
	CreatedAt string  `json:"created_at"`
}

// CreateUserRequest for POST /users
type CreateUserRequest struct {
	Name  string `json:"name"`
	Email string `json:"email"`
}

// ─── DB ───────────────────────────────────────────────────────────────────────

var db *sql.DB

func initDB(dsn string) error {
	var err error
	db, err = sql.Open("mysql", dsn)
	if err != nil {
		return fmt.Errorf("sql.Open: %w", err)
	}
	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)
	return db.Ping()
}

// hasNewColumns checks whether first_name and last_name columns exist.
// This allows the handler to work both before and after Expand.
func hasNewColumns() bool {
	row := db.QueryRow(`
		SELECT COUNT(*) FROM information_schema.COLUMNS
		WHERE TABLE_SCHEMA = DATABASE()
		  AND TABLE_NAME = 'users'
		  AND COLUMN_NAME IN ('first_name', 'last_name')
	`)
	var count int
	if err := row.Scan(&count); err != nil {
		return false
	}
	return count >= 2
}

// splitName splits a full name into first and last name components.
// "Alice Smith" -> ("Alice", "Smith")
// "山田 太郎"   -> ("山田", "太郎")
// "Alice"       -> ("Alice", "Alice")  // single word: repeat
func splitName(name string) (firstName, lastName string) {
	parts := strings.SplitN(strings.TrimSpace(name), " ", 2)
	firstName = parts[0]
	if len(parts) == 2 {
		lastName = parts[1]
	} else {
		lastName = parts[0]
	}
	return firstName, lastName
}

// ─── Handlers ─────────────────────────────────────────────────────────────────

// handleGetUser handles GET /users/:id
// Reads from name (primary), also returns first_name/last_name if available.
func handleGetUser(w http.ResponseWriter, r *http.Request) {
	idStr := strings.TrimPrefix(r.URL.Path, "/users/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid user id"}`, http.StatusBadRequest)
		return
	}

	var user UserV1
	var createdAt time.Time

	if hasNewColumns() {
		// Phase 1+: read all columns
		var firstName, lastName sql.NullString
		err = db.QueryRowContext(r.Context(), `
			SELECT id, name, first_name, last_name, email, created_at
			FROM users WHERE id = ?
		`, id).Scan(&user.ID, &user.Name, &firstName, &lastName, &user.Email, &createdAt)
		if firstName.Valid {
			user.FirstName = &firstName.String
		}
		if lastName.Valid {
			user.LastName = &lastName.String
		}
	} else {
		// Before Expand: read only name column
		err = db.QueryRowContext(r.Context(), `
			SELECT id, name, email, created_at FROM users WHERE id = ?
		`, id).Scan(&user.ID, &user.Name, &user.Email, &createdAt)
	}

	if err == sql.ErrNoRows {
		http.Error(w, `{"error":"user not found"}`, http.StatusNotFound)
		return
	}
	if err != nil {
		log.Printf("GetUser error: %v", err)
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}

	user.CreatedAt = createdAt.Format(time.RFC3339)

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Handler-Version", "v1-compatible")
	json.NewEncoder(w).Encode(user)
}

// handleCreateUser handles POST /users
// Writes to name (primary). Also writes first_name/last_name if columns exist (double write).
func handleCreateUser(w http.ResponseWriter, r *http.Request) {
	var req CreateUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
		return
	}
	if req.Name == "" || req.Email == "" {
		http.Error(w, `{"error":"name and email are required"}`, http.StatusBadRequest)
		return
	}

	firstName, lastName := splitName(req.Name)

	var result sql.Result
	var err error

	if hasNewColumns() {
		// Double-write: populate both name and first_name/last_name
		result, err = db.ExecContext(r.Context(), `
			INSERT INTO users (name, first_name, last_name, email)
			VALUES (?, ?, ?, ?)
		`, req.Name, firstName, lastName, req.Email)
	} else {
		// Before Expand: write only name
		result, err = db.ExecContext(r.Context(), `
			INSERT INTO users (name, email) VALUES (?, ?)
		`, req.Name, req.Email)
	}

	if err != nil {
		log.Printf("CreateUser error: %v", err)
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}

	id, _ := result.LastInsertId()
	fn := firstName
	ln := lastName

	user := UserV1{
		ID:        id,
		Name:      req.Name,
		FirstName: &fn,
		LastName:  &ln,
		Email:     req.Email,
		CreatedAt: time.Now().Format(time.RFC3339),
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Handler-Version", "v1-compatible")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(user)
}

// handleUpdateUser handles PUT /users/:id
// Updates name (primary). Also updates first_name/last_name if columns exist.
func handleUpdateUser(w http.ResponseWriter, r *http.Request) {
	idStr := strings.TrimPrefix(r.URL.Path, "/users/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid user id"}`, http.StatusBadRequest)
		return
	}

	var req CreateUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
		return
	}

	firstName, lastName := splitName(req.Name)

	if hasNewColumns() {
		_, err = db.ExecContext(r.Context(), `
			UPDATE users
			SET name = ?, first_name = ?, last_name = ?
			WHERE id = ?
		`, req.Name, firstName, lastName, id)
	} else {
		_, err = db.ExecContext(r.Context(), `
			UPDATE users SET name = ? WHERE id = ?
		`, req.Name, id)
	}

	if err != nil {
		log.Printf("UpdateUser error: %v", err)
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Handler-Version", "v1-compatible")
	w.WriteHeader(http.StatusNoContent)
}

// handleHealth handles GET /health
func handleHealth(w http.ResponseWriter, r *http.Request) {
	if err := db.PingContext(r.Context()); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintf(w, `{"status":"unhealthy","error":"%s","version":"v1"}`, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Handler-Version", "v1-compatible")
	fmt.Fprintf(w, `{"status":"ok","version":"v1","hostname":"%s"}`, mustHostname())
}

func mustHostname() string {
	h, _ := os.Hostname()
	return h
}

// ─── Router ───────────────────────────────────────────────────────────────────

func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/users/", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			handleGetUser(w, r)
		case http.MethodPut:
			handleUpdateUser(w, r)
		default:
			http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		}
	})
	mux.HandleFunc("/users", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			handleCreateUser(w, r)
		} else {
			http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		}
	})
	return mux
}

func main() {
	dsn := os.Getenv("DSN")
	if dsn == "" {
		dsn = "root:root@tcp(127.0.0.1:3306)/appdb?parseTime=true"
	}

	if err := initDB(dsn); err != nil {
		log.Fatalf("initDB: %v", err)
	}
	defer db.Close()

	log.Printf("[v1] Starting compatible handler on :8080")
	log.Printf("[v1] new columns present: %v", hasNewColumns())

	if err := http.ListenAndServe(":8080", newMux()); err != nil {
		log.Fatalf("ListenAndServe: %v", err)
	}
}
