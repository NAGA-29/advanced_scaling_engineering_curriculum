// v2_handler.go — Phase 3 新ハンドラー
//
// このハンドラーはバックフィル完了後にデプロイする。
//
// v2の動作:
//   - 読み取り: first_name/last_name から読む（name はフォールバック）
//   - 書き込み: first_name/last_name のみ書く（name には書かない）
//
// フォールバックロジック:
//   - first_name が NULL の場合は name を分割して返す（バックフィル未完ユーザー用）
//   - これにより、バックフィルが100%完了していなくても安全にデプロイ可能
//
// Contract (name DROP) の前提条件:
//   - このv2ハンドラーが全インスタンスにデプロイされていること
//   - name カラムを参照するコードがないこと
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

// UserV2 is the user model for the v2 handler.
// first_name and last_name are the primary fields.
// name is omitted (will not exist after Contract phase).
type UserV2 struct {
	ID        int64  `json:"id"`
	FirstName string `json:"first_name"`
	LastName  string `json:"last_name"`
	FullName  string `json:"full_name"` // derived: first_name + " " + last_name
	Email     string `json:"email"`
	CreatedAt string `json:"created_at"`
}

// CreateUserV2Request for POST /users (v2 API)
type CreateUserV2Request struct {
	FirstName string `json:"first_name"`
	LastName  string `json:"last_name"`
	Email     string `json:"email"`
	// Backward compatibility: accept "name" and split it
	Name string `json:"name,omitempty"`
}

// ─── DB ───────────────────────────────────────────────────────────────────────

var dbV2 *sql.DB

func initDBV2(dsn string) error {
	var err error
	dbV2, err = sql.Open("mysql", dsn)
	if err != nil {
		return fmt.Errorf("sql.Open: %w", err)
	}
	dbV2.SetMaxOpenConns(25)
	dbV2.SetMaxIdleConns(5)
	dbV2.SetConnMaxLifetime(5 * time.Minute)
	return dbV2.Ping()
}

// nameColumnExists checks if the legacy name column still exists.
// Returns false after Contract phase.
func nameColumnExists() bool {
	row := dbV2.QueryRow(`
		SELECT COUNT(*) FROM information_schema.COLUMNS
		WHERE TABLE_SCHEMA = DATABASE()
		  AND TABLE_NAME = 'users'
		  AND COLUMN_NAME = 'name'
	`)
	var count int
	if err := row.Scan(&count); err != nil {
		return false
	}
	return count > 0
}

// splitNameV2 splits a full name into first and last name.
func splitNameV2(fullName string) (firstName, lastName string) {
	parts := strings.SplitN(strings.TrimSpace(fullName), " ", 2)
	firstName = parts[0]
	if len(parts) == 2 {
		lastName = parts[1]
	} else {
		lastName = parts[0]
	}
	return firstName, lastName
}

// ─── Handlers ─────────────────────────────────────────────────────────────────

// handleGetUserV2 handles GET /users/:id
// Reads from first_name/last_name primarily.
// Falls back to splitting name if first_name is NULL (pre-backfill rows).
func handleGetUserV2(w http.ResponseWriter, r *http.Request) {
	idStr := strings.TrimPrefix(r.URL.Path, "/users/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid user id"}`, http.StatusBadRequest)
		return
	}

	var user UserV2
	var createdAt time.Time

	if nameColumnExists() {
		// During transition: name column still exists, read all for fallback
		var legacyName sql.NullString
		var firstName, lastName sql.NullString

		err = dbV2.QueryRowContext(r.Context(), `
			SELECT id, name, first_name, last_name, email, created_at
			FROM users WHERE id = ?
		`, id).Scan(&user.ID, &legacyName, &firstName, &lastName, &user.Email, &createdAt)
		if err != nil {
			goto handleErr
		}

		if firstName.Valid && firstName.String != "" {
			// Backfilled: use new columns
			user.FirstName = firstName.String
			user.LastName = lastName.String
		} else if legacyName.Valid {
			// Not yet backfilled: fall back to splitting name
			user.FirstName, user.LastName = splitNameV2(legacyName.String)
		}
	} else {
		// After Contract: name column removed, read only new columns
		err = dbV2.QueryRowContext(r.Context(), `
			SELECT id, first_name, last_name, email, created_at
			FROM users WHERE id = ?
		`, id).Scan(&user.ID, &user.FirstName, &user.LastName, &user.Email, &createdAt)
	}

handleErr:
	if err == sql.ErrNoRows {
		http.Error(w, `{"error":"user not found"}`, http.StatusNotFound)
		return
	}
	if err != nil {
		log.Printf("GetUserV2 error: %v", err)
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}

	user.FullName = strings.TrimSpace(user.FirstName + " " + user.LastName)
	user.CreatedAt = createdAt.Format(time.RFC3339)

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Handler-Version", "v2")
	json.NewEncoder(w).Encode(user)
}

// handleCreateUserV2 handles POST /users
// Writes to first_name/last_name primarily.
// If name is provided (backward compat), splits it.
func handleCreateUserV2(w http.ResponseWriter, r *http.Request) {
	var req CreateUserV2Request
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
		return
	}

	// Handle backward compatibility: if name is provided, split it
	if req.Name != "" && req.FirstName == "" {
		req.FirstName, req.LastName = splitNameV2(req.Name)
	}

	if req.FirstName == "" || req.Email == "" {
		http.Error(w, `{"error":"first_name and email are required"}`, http.StatusBadRequest)
		return
	}
	if req.LastName == "" {
		req.LastName = req.FirstName // single-name users
	}

	var result sql.Result
	var err error

	if nameColumnExists() {
		// Transition: still populate name for any remaining v1 code
		fullName := strings.TrimSpace(req.FirstName + " " + req.LastName)
		result, err = dbV2.ExecContext(r.Context(), `
			INSERT INTO users (name, first_name, last_name, email)
			VALUES (?, ?, ?, ?)
		`, fullName, req.FirstName, req.LastName, req.Email)
	} else {
		// After Contract: write only new columns
		result, err = dbV2.ExecContext(r.Context(), `
			INSERT INTO users (first_name, last_name, email)
			VALUES (?, ?, ?)
		`, req.FirstName, req.LastName, req.Email)
	}

	if err != nil {
		log.Printf("CreateUserV2 error: %v", err)
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}

	id, _ := result.LastInsertId()
	user := UserV2{
		ID:        id,
		FirstName: req.FirstName,
		LastName:  req.LastName,
		FullName:  strings.TrimSpace(req.FirstName + " " + req.LastName),
		Email:     req.Email,
		CreatedAt: time.Now().Format(time.RFC3339),
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Handler-Version", "v2")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(user)
}

// handleUpdateUserV2 handles PUT /users/:id
// Writes first_name/last_name. Does not write to name after Contract.
func handleUpdateUserV2(w http.ResponseWriter, r *http.Request) {
	idStr := strings.TrimPrefix(r.URL.Path, "/users/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, `{"error":"invalid user id"}`, http.StatusBadRequest)
		return
	}

	var req CreateUserV2Request
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
		return
	}

	if req.Name != "" && req.FirstName == "" {
		req.FirstName, req.LastName = splitNameV2(req.Name)
	}

	if nameColumnExists() {
		fullName := strings.TrimSpace(req.FirstName + " " + req.LastName)
		_, err = dbV2.ExecContext(r.Context(), `
			UPDATE users SET name = ?, first_name = ?, last_name = ? WHERE id = ?
		`, fullName, req.FirstName, req.LastName, id)
	} else {
		_, err = dbV2.ExecContext(r.Context(), `
			UPDATE users SET first_name = ?, last_name = ? WHERE id = ?
		`, req.FirstName, req.LastName, id)
	}

	if err != nil {
		log.Printf("UpdateUserV2 error: %v", err)
		http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Handler-Version", "v2")
	w.WriteHeader(http.StatusNoContent)
}

// handleHealthV2 handles GET /health
func handleHealthV2(w http.ResponseWriter, r *http.Request) {
	if err := dbV2.PingContext(r.Context()); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintf(w, `{"status":"unhealthy","error":"%s","version":"v2"}`, err.Error())
		return
	}

	hasName := nameColumnExists()
	phase := "contract"
	if hasName {
		phase = "transition"
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Handler-Version", "v2")
	hostname, _ := os.Hostname()
	fmt.Fprintf(w, `{"status":"ok","version":"v2","phase":"%s","hostname":"%s"}`,
		phase, hostname)
}

// ─── Router ───────────────────────────────────────────────────────────────────

func newMuxV2() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", handleHealthV2)
	mux.HandleFunc("/users/", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			handleGetUserV2(w, r)
		case http.MethodPut:
			handleUpdateUserV2(w, r)
		default:
			http.Error(w, `{"error":"method not allowed"}`, http.StatusMethodNotAllowed)
		}
	})
	mux.HandleFunc("/users", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			handleCreateUserV2(w, r)
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

	if err := initDBV2(dsn); err != nil {
		log.Fatalf("initDBV2: %v", err)
	}
	defer dbV2.Close()

	log.Printf("[v2] Starting new handler on :8080")
	log.Printf("[v2] name column exists (transition phase): %v", nameColumnExists())

	if err := http.ListenAndServe(":8080", newMuxV2()); err != nil {
		log.Fatalf("ListenAndServe: %v", err)
	}
}
