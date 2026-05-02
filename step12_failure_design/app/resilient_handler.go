package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	_ "net/http/pprof"
	"os"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
	"github.com/redis/go-redis/v9"
)

// ── 設定 ─────────────────────────────────────────────────────────────────────

const (
	DBTimeout     = 5 * time.Second  // DB 呼び出しのタイムアウト
	CacheTTL      = 60 * time.Second // Redis キャッシュの有効期限
	CBMaxFailures = 5                // Circuit Breaker: 連続失敗閾値
	CBTimeout     = 30 * time.Second // Circuit Breaker: OPEN の持続時間
	MaxRetries    = 3                // リトライ回数
)

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// ── データ型 ──────────────────────────────────────────────────────────────────

// User はユーザーデータを表す
type User struct {
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	Email    string `json:"email"`
	CreatedAt string `json:"created_at,omitempty"`
	// Degraded は部分的なデータの場合 true (キャッシュからの stale データなど)
	Degraded bool   `json:"degraded"`
}

// ── 依存関係 ──────────────────────────────────────────────────────────────────

// App はアプリケーションの依存関係をまとめた構造体
type App struct {
	db      *sql.DB
	redis   *redis.Client
	cb      *CircuitBreaker
	logger  *log.Logger
}

// ── ハンドラ ──────────────────────────────────────────────────────────────────

// getUserHandler は全レジリエンスパターンを組み合わせた GET /users/:id ハンドラ
//
// 処理フロー:
//  1. Redis キャッシュを確認 (ヒットなら即座に返す)
//  2. Circuit Breaker → Timeout → Retry でDB に問い合わせ
//  3. DB 成功: キャッシュに保存して返す
//  4. DB 失敗 + キャッシュあり: stale データを degraded=true で返す (Fallback)
//  5. DB 失敗 + キャッシュなし: 部分データ or エラーを返す (Degraded Response)
func (a *App) getUserHandler(c echo.Context) error {
	userID := c.Param("id")
	cacheKey := fmt.Sprintf("user:%s", userID)

	// ── Step 1: Redis キャッシュ確認 ──────────────────────────────────
	if cached, err := a.getFromCache(c.Request().Context(), cacheKey); err == nil {
		cached.Degraded = false
		return c.JSON(http.StatusOK, cached)
	}

	// ── Step 2: Circuit Breaker + Timeout + Retry でDB 問い合わせ ────
	var user *User
	var dbErr error

	dbErr = withRetry(c.Request().Context(), MaxRetries, func() error {
		return a.cb.Call(func() error {
			// Timeout: DB が遅すぎる場合に諦める
			ctx, cancel := context.WithTimeout(c.Request().Context(), DBTimeout)
			defer cancel()

			u, err := a.getUserFromDB(ctx, userID)
			if err != nil {
				return err
			}
			user = u
			return nil
		})
	})

	// ── Step 3: DB 成功 ───────────────────────────────────────────────
	if dbErr == nil && user != nil {
		user.Degraded = false
		// キャッシュに保存 (TTL: 60秒)
		_ = a.saveToCache(c.Request().Context(), cacheKey, user, CacheTTL)
		return c.JSON(http.StatusOK, user)
	}

	// ── Step 4: Fallback — stale キャッシュから返す ───────────────────
	// (通常の Get はすでに TTL 切れで miss だが、長い TTL のバックアップがあるケースや
	//  stale-while-revalidate パターンを模倣)
	a.logger.Printf("DB error (user=%s): %v — attempting fallback", userID, dbErr)

	if stale, err := a.getFromCache(c.Request().Context(), cacheKey+":stale"); err == nil {
		stale.Degraded = true
		c.Response().Header().Set("X-Degraded", "true")
		c.Response().Header().Set("X-Degraded-Reason", "db_unavailable_using_stale_cache")
		return c.JSON(http.StatusOK, stale)
	}

	// ── Step 5: Degraded Response — 最低限の情報だけ返す ─────────────
	// Circuit Breaker が OPEN の場合は高速に拒否される
	if errors.Is(dbErr, ErrCircuitOpen) {
		a.logger.Printf("circuit breaker OPEN for user=%s", userID)
		c.Response().Header().Set("X-Degraded", "true")
		c.Response().Header().Set("X-Degraded-Reason", "circuit_breaker_open")
		// 最低限のデータを返す (ユーザーに完全エラーを見せない)
		return c.JSON(http.StatusOK, User{
			ID:       0,
			Name:     "Service Temporarily Unavailable",
			Degraded: true,
		})
	}

	// それ以外の DB エラー
	return c.JSON(http.StatusServiceUnavailable, map[string]interface{}{
		"error":    "database_unavailable",
		"message":  "Could not retrieve user data. Please retry.",
		"degraded": true,
	})
}

// ── DB 操作 ───────────────────────────────────────────────────────────────────

func (a *App) getUserFromDB(ctx context.Context, id string) (*User, error) {
	var u User
	err := a.db.QueryRowContext(ctx,
		"SELECT id, name, email, created_at FROM users WHERE id = ?", id,
	).Scan(&u.ID, &u.Name, &u.Email, &u.CreatedAt)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, fmt.Errorf("user %s not found", id)
		}
		return nil, fmt.Errorf("DB query error: %w", err)
	}
	return &u, nil
}

// ── キャッシュ操作 ────────────────────────────────────────────────────────────

func (a *App) getFromCache(ctx context.Context, key string) (*User, error) {
	val, err := a.redis.Get(ctx, key).Result()
	if err != nil {
		return nil, err
	}
	var u User
	if err := json.Unmarshal([]byte(val), &u); err != nil {
		return nil, err
	}
	return &u, nil
}

func (a *App) saveToCache(ctx context.Context, key string, u *User, ttl time.Duration) error {
	data, err := json.Marshal(u)
	if err != nil {
		return err
	}
	// 通常キャッシュ
	if err := a.redis.Set(ctx, key, data, ttl).Err(); err != nil {
		return err
	}
	// stale バックアップ (通常 TTL より長い)
	return a.redis.Set(ctx, key+":stale", data, ttl*10).Err()
}

// ── リトライ ──────────────────────────────────────────────────────────────────

// withRetry は fn を最大 maxRetries 回実行する (指数バックオフ)
func withRetry(ctx context.Context, maxRetries int, fn func() error) error {
	var lastErr error
	for attempt := 0; attempt < maxRetries; attempt++ {
		if err := fn(); err != nil {
			// Circuit Breaker OPEN はリトライしない (すぐに失敗させる)
			if errors.Is(err, ErrCircuitOpen) {
				return err
			}
			lastErr = err
			wait := time.Duration(100*(1<<attempt)) * time.Millisecond // 100ms, 200ms, 400ms
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(wait):
			}
			continue
		}
		return nil
	}
	return fmt.Errorf("all %d retries failed: %w", maxRetries, lastErr)
}

// ── メイン ─────────────────────────────────────────────────────────────────────

func main() {
	logger := log.New(os.Stdout, "[step12] ", log.LstdFlags|log.Lmicroseconds)

	// ── DB 接続 ───────────────────────────────────────────────────────
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true",
		getEnv("DB_USER", "root"),
		getEnv("DB_PASSWORD", "password"),
		getEnv("DB_HOST", "localhost"),
		getEnv("DB_PORT", "3306"),
		getEnv("DB_NAME", "appdb"),
	)
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		logger.Fatalf("sql.Open: %v", err)
	}
	db.SetMaxOpenConns(20)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)

	// usersテーブルを自動作成
	_, _ = db.Exec(`CREATE TABLE IF NOT EXISTS users (
		id         BIGINT AUTO_INCREMENT PRIMARY KEY,
		name       VARCHAR(128) NOT NULL,
		email      VARCHAR(256) NOT NULL,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	) ENGINE=InnoDB`)
	// サンプルデータ
	_, _ = db.Exec(`INSERT IGNORE INTO users (id, name, email) VALUES
		(1, 'Alice', 'alice@example.com'),
		(2, 'Bob',   'bob@example.com'),
		(3, 'Carol', 'carol@example.com')`)

	// ── Redis 接続 ────────────────────────────────────────────────────
	rdb := redis.NewClient(&redis.Options{
		Addr: getEnv("REDIS_ADDR", "localhost:6379"),
	})

	// ── Circuit Breaker 生成 ──────────────────────────────────────────
	cb := NewCircuitBreaker(CBMaxFailures, CBTimeout)

	app := &App{db: db, redis: rdb, cb: cb, logger: logger}

	// ── Echo ──────────────────────────────────────────────────────────
	e := echo.New()
	e.HideBanner = true
	e.Use(middleware.Logger())
	e.Use(middleware.Recover())

	// ── ルーティング ──────────────────────────────────────────────────
	e.GET("/users/:id", app.getUserHandler)

	// Circuit Breaker の状態確認エンドポイント
	e.GET("/circuit-breaker/status", func(c echo.Context) error {
		return c.JSON(http.StatusOK, cb.GetStats())
	})

	e.GET("/health", func(c echo.Context) error {
		status := "ok"
		checks := map[string]string{
			"circuit_breaker": cb.State().String(),
		}
		if err := db.PingContext(c.Request().Context()); err != nil {
			checks["mysql"] = "down: " + err.Error()
			status = "degraded"
		} else {
			checks["mysql"] = "up"
		}
		if err := rdb.Ping(c.Request().Context()).Err(); err != nil {
			checks["redis"] = "down: " + err.Error()
			status = "degraded"
		} else {
			checks["redis"] = "up"
		}
		code := http.StatusOK
		if status != "ok" {
			code = http.StatusServiceUnavailable
		}
		return c.JSON(code, map[string]interface{}{"status": status, "checks": checks})
	})

	port := getEnv("PORT", "8080")
	e.Logger.Fatal(e.Start(":" + port))
}
