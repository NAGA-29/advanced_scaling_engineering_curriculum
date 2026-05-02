// Package main implements the Cache-Aside pattern with Redis and MySQL.
// On cache miss, data is fetched from MySQL and stored in Redis with a TTL.
// On cache invalidation (write), the Redis key is deleted (not updated).
// If Redis is unavailable, all requests fall back to MySQL transparently.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/redis/go-redis/v9"
)

// -------------------------------------------------------
// 定数・設定
// -------------------------------------------------------

const (
	// DefaultUserTTL はユーザーキャッシュのデフォルト TTL（秒）
	DefaultUserTTL = 300 * time.Second

	// DefaultTenantUsersTTL はテナント別ユーザー一覧キャッシュの TTL
	DefaultTenantUsersTTL = 120 * time.Second

	// DefaultDeviceHeartbeatTTL はデバイスハートビートの TTL（短い）
	DefaultDeviceHeartbeatTTL = 30 * time.Second
)

// -------------------------------------------------------
// キーパターン
// -------------------------------------------------------

// userCacheKey returns the Redis key for a user by ID.
// Pattern: user:{id}
func userCacheKey(id int64) string {
	return fmt.Sprintf("user:%d", id)
}

// tenantUsersCacheKey returns the Redis key for a tenant's user list.
// Pattern: tenant:{tenant_id}:users
func tenantUsersCacheKey(tenantID string) string {
	return fmt.Sprintf("tenant:%s:users", tenantID)
}

// deviceHeartbeatKey returns the Redis key for a device heartbeat.
// Pattern: heartbeat:{device_id}
func deviceHeartbeatKey(deviceID int64) string {
	return fmt.Sprintf("heartbeat:%d", deviceID)
}

// -------------------------------------------------------
// モデル
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

// -------------------------------------------------------
// CacheStore: Redis ラッパー（Fallback 付き）
// -------------------------------------------------------

// CacheStore wraps a Redis client and provides graceful degradation
// when Redis is unavailable.
type CacheStore struct {
	client *redis.Client
}

// NewCacheStore creates a CacheStore and verifies the Redis connection.
// Returns a non-nil store even if Redis is down; all operations will
// fall through to the DB in that case.
func NewCacheStore(addr, password string, db int) *CacheStore {
	client := redis.NewClient(&redis.Options{
		Addr:         addr,
		Password:     password,
		DB:           db,
		DialTimeout:  2 * time.Second,
		ReadTimeout:  1 * time.Second,
		WriteTimeout: 1 * time.Second,
		PoolSize:     20,
		MinIdleConns: 5,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	if err := client.Ping(ctx).Err(); err != nil {
		log.Printf("[WARN] Redis connection failed at startup (will fall back to DB): %v", err)
	} else {
		log.Println("[INFO] Redis connected successfully")
	}

	return &CacheStore{client: client}
}

// Get fetches a value by key. Returns ("", false, nil) on miss,
// ("", false, err) on error, ("value", true, nil) on hit.
func (c *CacheStore) Get(ctx context.Context, key string) (string, bool, error) {
	val, err := c.client.Get(ctx, key).Result()
	if errors.Is(err, redis.Nil) {
		return "", false, nil // キャッシュミス（エラーではない）
	}
	if err != nil {
		return "", false, fmt.Errorf("redis GET %s: %w", key, err)
	}
	return val, true, nil
}

// Set stores a value with TTL.
func (c *CacheStore) Set(ctx context.Context, key string, value interface{}, ttl time.Duration) error {
	data, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("marshal %s: %w", key, err)
	}

	if err := c.client.Set(ctx, key, data, ttl).Err(); err != nil {
		return fmt.Errorf("redis SET %s: %w", key, err)
	}
	return nil
}

// Delete removes a key from Redis.
func (c *CacheStore) Delete(ctx context.Context, keys ...string) error {
	if err := c.client.Del(ctx, keys...).Err(); err != nil {
		return fmt.Errorf("redis DEL %v: %w", keys, err)
	}
	return nil
}

// Ping checks Redis connectivity.
func (c *CacheStore) Ping(ctx context.Context) error {
	return c.client.Ping(ctx).Err()
}

// -------------------------------------------------------
// Cache-Aside 実装
// -------------------------------------------------------

// GetUserWithCache implements the Cache-Aside read pattern.
//
//  1. Redis から user:{id} を取得
//  2. ヒット → デシリアライズして返す（DB アクセスなし）
//  3. ミス  → DB から取得 → Redis にキャッシュ → 返す
//
// Redis が利用不可の場合は DB から直接取得する（Fallback）。
// レスポンスヘッダー X-Cache に HIT/MISS を記録する。
func GetUserWithCache(ctx context.Context, cache *CacheStore, db *sql.DB, id int64) (*User, string, error) {
	key := userCacheKey(id)
	requestID := getRequestID(ctx)

	// ── Step 1: Redis から取得 ──
	cached, hit, err := cache.Get(ctx, key)
	if err != nil {
		// Redis エラー: Fallback to DB
		log.Printf("[WARN] request_id=%s Redis GET failed for key=%s, falling back to DB: %v",
			requestID, key, err)
	} else if hit {
		// ── キャッシュヒット ──
		var u User
		if jsonErr := json.Unmarshal([]byte(cached), &u); jsonErr != nil {
			log.Printf("[ERROR] request_id=%s JSON unmarshal for key=%s: %v", requestID, key, jsonErr)
			// 壊れたキャッシュは削除して DB へ Fallback
			_ = cache.Delete(ctx, key)
		} else {
			log.Printf("[DEBUG] request_id=%s CACHE HIT key=%s", requestID, key)
			return &u, "HIT", nil
		}
	}

	// ── Step 2: キャッシュミス or Redis エラー → DB から取得 ──
	log.Printf("[DEBUG] request_id=%s CACHE MISS key=%s, querying DB", requestID, key)

	u, dbErr := getUserFromDB(ctx, db, id)
	if dbErr != nil {
		return nil, "MISS", fmt.Errorf("DB query: %w", dbErr)
	}
	if u == nil {
		// Not Found（キャッシュしない）
		return nil, "MISS", nil
	}

	// ── Step 3: Redis にキャッシュ ──
	if cacheErr := cache.Set(ctx, key, u, DefaultUserTTL); cacheErr != nil {
		// キャッシュ保存の失敗はサービス継続に影響しない（ログのみ）
		log.Printf("[WARN] request_id=%s failed to cache user id=%d: %v", requestID, id, cacheErr)
	}

	return u, "MISS", nil
}

// InvalidateUser deletes the cached user entry and the tenant's user list cache.
// Call this after any user update or delete to prevent stale data.
func InvalidateUser(ctx context.Context, cache *CacheStore, userID int64, tenantID string) error {
	keys := []string{userCacheKey(userID)}
	if tenantID != "" {
		keys = append(keys, tenantUsersCacheKey(tenantID))
	}

	if err := cache.Delete(ctx, keys...); err != nil {
		return fmt.Errorf("InvalidateUser: %w", err)
	}

	log.Printf("[INFO] cache invalidated: keys=%v", keys)
	return nil
}

// GetTenantUsersWithCache implements Cache-Aside for the tenant user list.
// キャッシュキー: tenant:{tenant_id}:users
func GetTenantUsersWithCache(ctx context.Context, cache *CacheStore, db *sql.DB, tenantID string) ([]User, string, error) {
	key := tenantUsersCacheKey(tenantID)
	requestID := getRequestID(ctx)

	cached, hit, err := cache.Get(ctx, key)
	if err != nil {
		log.Printf("[WARN] request_id=%s Redis GET failed for key=%s: %v", requestID, key, err)
	} else if hit {
		var users []User
		if jsonErr := json.Unmarshal([]byte(cached), &users); jsonErr == nil {
			log.Printf("[DEBUG] request_id=%s CACHE HIT key=%s (count=%d)", requestID, key, len(users))
			return users, "HIT", nil
		}
		_ = cache.Delete(ctx, key)
	}

	log.Printf("[DEBUG] request_id=%s CACHE MISS key=%s, querying DB", requestID, key)

	users, dbErr := listUsersByTenantFromDB(ctx, db, tenantID)
	if dbErr != nil {
		return nil, "MISS", fmt.Errorf("DB query: %w", dbErr)
	}

	if cacheErr := cache.Set(ctx, key, users, DefaultTenantUsersTTL); cacheErr != nil {
		log.Printf("[WARN] request_id=%s failed to cache tenant users tenant_id=%s: %v",
			requestID, tenantID, cacheErr)
	}

	return users, "MISS", nil
}

// RecordHeartbeat stores a device heartbeat timestamp in Redis.
// This is a write-through pattern: always write to Redis directly.
// (The heartbeat is ephemeral and does not need to be in MySQL.)
func RecordHeartbeat(ctx context.Context, cache *CacheStore, deviceID int64) error {
	key := deviceHeartbeatKey(deviceID)
	now := time.Now().UTC().Format(time.RFC3339)

	if err := cache.client.Set(ctx, key, now, DefaultDeviceHeartbeatTTL).Err(); err != nil {
		return fmt.Errorf("RecordHeartbeat: %w", err)
	}
	return nil
}

// -------------------------------------------------------
// DB 操作ヘルパー
// -------------------------------------------------------

func getUserFromDB(ctx context.Context, db *sql.DB, id int64) (*User, error) {
	var u User
	err := db.QueryRowContext(ctx,
		`SELECT id, tenant_id, name, email, status, created_at
		   FROM users
		  WHERE id = ?`,
		id,
	).Scan(&u.ID, &u.TenantID, &u.Name, &u.Email, &u.Status, &u.CreatedAt)

	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &u, nil
}

func listUsersByTenantFromDB(ctx context.Context, db *sql.DB, tenantID string) ([]User, error) {
	rows, err := db.QueryContext(ctx,
		`SELECT id, tenant_id, name, email, status, created_at
		   FROM users
		  WHERE tenant_id = ?
		  ORDER BY id
		  LIMIT 100`,
		tenantID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var users []User
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.TenantID, &u.Name, &u.Email, &u.Status, &u.CreatedAt); err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

// -------------------------------------------------------
// HTTP ハンドラー
// -------------------------------------------------------

type App struct {
	db    *sql.DB
	cache *CacheStore
}

func (a *App) handleHealth(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	dbErr := a.db.PingContext(ctx)
	redisErr := a.cache.Ping(ctx)

	status := "ok"
	code := http.StatusOK
	if dbErr != nil {
		status = "ng"
		code = http.StatusServiceUnavailable
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	fmt.Fprintf(w, `{"status":%q,"db_ok":%v,"redis_ok":%v}`,
		status, dbErr == nil, redisErr == nil)
}

func (a *App) handleGetUser(w http.ResponseWriter, r *http.Request) {
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

	// リクエスト ID をコンテキストに追加（ログ追跡用）
	ctx := withRequestID(r.Context(), r.Header.Get("X-Request-ID"))

	u, cacheStatus, err := GetUserWithCache(ctx, a.cache, a.db, id)
	if err != nil {
		log.Printf("[ERROR] GetUserWithCache id=%d: %v", id, err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if u == nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}

	// X-Cache ヘッダーでキャッシュ状態を通知
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Cache", cacheStatus)

	data, _ := json.Marshal(u)
	w.Write(data)
}

func (a *App) handleListUsers(w http.ResponseWriter, r *http.Request) {
	tenantID := r.URL.Query().Get("tenant_id")
	if tenantID == "" {
		http.Error(w, "tenant_id required", http.StatusBadRequest)
		return
	}

	ctx := withRequestID(r.Context(), r.Header.Get("X-Request-ID"))

	users, cacheStatus, err := GetTenantUsersWithCache(ctx, a.cache, a.db, tenantID)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Cache", cacheStatus)

	if users == nil {
		users = []User{} // nil の代わりに空スライスを返す
	}
	data, _ := json.Marshal(users)
	w.Write(data)
}

func (a *App) handleCreateUser(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		TenantID string `json:"tenant_id"`
		Name     string `json:"name"`
		Email    string `json:"email"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}

	if req.TenantID == "" || req.Name == "" || req.Email == "" {
		http.Error(w, "tenant_id, name, email are required", http.StatusBadRequest)
		return
	}

	ctx := r.Context()

	res, err := a.db.ExecContext(ctx,
		`INSERT INTO users (tenant_id, name, email) VALUES (?, ?, ?)`,
		req.TenantID, req.Name, req.Email,
	)
	if err != nil {
		log.Printf("[ERROR] CreateUser: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	newID, _ := res.LastInsertId()

	// テナントのユーザー一覧キャッシュを無効化（新ユーザーが反映されるように）
	if cacheErr := InvalidateUser(ctx, a.cache, newID, req.TenantID); cacheErr != nil {
		log.Printf("[WARN] cache invalidation failed after CreateUser: %v", cacheErr)
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	fmt.Fprintf(w, `{"id":%d}`, newID)
}

func (a *App) handleUpdateUser(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	idStr := r.URL.Path[len("/users/"):]
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, "invalid id", http.StatusBadRequest)
		return
	}

	var req struct {
		Name     string `json:"name"`
		TenantID string `json:"tenant_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}

	ctx := r.Context()

	_, err = a.db.ExecContext(ctx,
		`UPDATE users SET name = ? WHERE id = ?`,
		req.Name, id,
	)
	if err != nil {
		log.Printf("[ERROR] UpdateUser id=%d: %v", id, err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	// キャッシュを無効化（次のリクエストで DB から最新データを取得する）
	if cacheErr := InvalidateUser(ctx, a.cache, id, req.TenantID); cacheErr != nil {
		log.Printf("[WARN] cache invalidation failed after UpdateUser id=%d: %v", id, cacheErr)
	}

	w.WriteHeader(http.StatusNoContent)
}

// -------------------------------------------------------
// コンテキストヘルパー（リクエスト ID の追跡）
// -------------------------------------------------------

type contextKey string

const requestIDKey contextKey = "request_id"

func withRequestID(ctx context.Context, id string) context.Context {
	if id == "" {
		id = fmt.Sprintf("req-%d", time.Now().UnixNano())
	}
	return context.WithValue(ctx, requestIDKey, id)
}

func getRequestID(ctx context.Context) string {
	if id, ok := ctx.Value(requestIDKey).(string); ok {
		return id
	}
	return "unknown"
}

// -------------------------------------------------------
// エントリーポイント
// -------------------------------------------------------

func main() {
	// MySQL 接続
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&charset=utf8mb4",
		getEnv("DB_USER", "apiuser"),
		getEnv("DB_PASSWORD", "apipassword"),
		getEnv("DB_HOST", "127.0.0.1"),
		getEnv("DB_PORT", "3306"),
		getEnv("DB_NAME", "appdb"),
	)

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		log.Fatalf("sql.Open: %v", err)
	}
	defer db.Close()

	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(10)
	db.SetConnMaxLifetime(5 * time.Minute)

	for i := 1; i <= 10; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		err = db.PingContext(ctx)
		cancel()
		if err == nil {
			log.Println("[INFO] MySQL connected")
			break
		}
		log.Printf("[INFO] MySQL ping attempt %d/10: %v", i, err)
		time.Sleep(2 * time.Second)
	}
	if err != nil {
		log.Fatalf("MySQL connection failed: %v", err)
	}

	// Redis 接続
	cache := NewCacheStore(
		getEnv("REDIS_ADDR", "127.0.0.1:6379"),
		getEnv("REDIS_PASSWORD", ""),
		0,
	)

	app := &App{db: db, cache: cache}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", app.handleHealth)
	mux.HandleFunc("/users/", func(w http.ResponseWriter, r *http.Request) {
		// /users/{id}
		path := r.URL.Path
		if len(path) > len("/users/") {
			if r.Method == http.MethodGet {
				app.handleGetUser(w, r)
			} else if r.Method == http.MethodPut {
				app.handleUpdateUser(w, r)
			} else {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			}
			return
		}
		// /users （末尾スラッシュなし）
		if r.Method == http.MethodGet {
			app.handleListUsers(w, r)
		} else if r.Method == http.MethodPost {
			app.handleCreateUser(w, r)
		} else {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})
	mux.HandleFunc("/users", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			app.handleListUsers(w, r)
		} else if r.Method == http.MethodPost {
			app.handleCreateUser(w, r)
		} else {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})

	port := getEnv("PORT", "8080")
	log.Printf("[INFO] Starting cache-aside demo server on :%s", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatalf("ListenAndServe: %v", err)
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
