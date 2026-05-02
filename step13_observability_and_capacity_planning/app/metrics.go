package main

import (
	"context"
	"fmt"
	"net/http"
	_ "net/http/pprof" // /debug/pprof エンドポイントを登録
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
	"github.com/redis/go-redis/v9"
)

// ── キャッシュメトリクス ──────────────────────────────────────────────────────

// CacheMetrics はキャッシュのヒット/ミス数をスレッドセーフに記録する
type CacheMetrics struct {
	hits   int64 // atomic
	misses int64 // atomic
}

var globalCacheMetrics = &CacheMetrics{}

// Hit はキャッシュヒットを記録する
func (cm *CacheMetrics) Hit() {
	atomic.AddInt64(&cm.hits, 1)
}

// Miss はキャッシュミスを記録する
func (cm *CacheMetrics) Miss() {
	atomic.AddInt64(&cm.misses, 1)
}

// Stats はヒット数・ミス数・ヒット率を返す
func (cm *CacheMetrics) Stats() (hits, misses int64, hitRate float64) {
	h := atomic.LoadInt64(&cm.hits)
	m := atomic.LoadInt64(&cm.misses)
	total := h + m
	if total == 0 {
		return h, m, 0
	}
	return h, m, float64(h) / float64(total) * 100
}

// ── リクエストカウンター ──────────────────────────────────────────────────────

// RequestCounter はパス別リクエスト数とエラー数を記録する
type RequestCounter struct {
	mu          sync.RWMutex
	pathCounts  map[string]int64
	errorCounts map[string]int64
	totalCount  int64
}

func NewRequestCounter() *RequestCounter {
	return &RequestCounter{
		pathCounts:  make(map[string]int64),
		errorCounts: make(map[string]int64),
	}
}

func (rc *RequestCounter) Increment(path string, statusCode int) {
	rc.mu.Lock()
	rc.pathCounts[path]++
	rc.totalCount++
	if statusCode >= 500 {
		rc.errorCounts[path]++
	}
	rc.mu.Unlock()
}

func (rc *RequestCounter) Snapshot() (map[string]int64, map[string]int64, int64) {
	rc.mu.RLock()
	defer rc.mu.RUnlock()

	paths := make(map[string]int64, len(rc.pathCounts))
	errors := make(map[string]int64, len(rc.errorCounts))
	for k, v := range rc.pathCounts {
		paths[k] = v
	}
	for k, v := range rc.errorCounts {
		errors[k] = v
	}
	return paths, errors, rc.totalCount
}

var globalRequestCounter = NewRequestCounter()

// ── メトリクスミドルウェア ────────────────────────────────────────────────────

// MetricsMiddleware はリクエストのメトリクスを記録するミドルウェア
// ログには: method, path, status, latency, request_id を含む
func MetricsMiddleware() echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			start := time.Now()

			err := next(c)

			latency := time.Since(start)
			status := c.Response().Status
			path := c.Path() // ルートパターン (e.g., "/users/:id")
			method := c.Request().Method
			reqID, _ := c.Get("request_id").(string)

			// 構造化ログ出力
			fmt.Printf(`{"time":"%s","level":"INFO","method":"%s","path":"%s","status":%d,"latency_ms":%.2f,"request_id":"%s"}`+"\n",
				time.Now().UTC().Format(time.RFC3339),
				method,
				path,
				status,
				float64(latency.Microseconds())/1000.0,
				reqID,
			)

			// カウンター更新
			globalRequestCounter.Increment(path, status)

			return err
		}
	}
}

// RequestIDMiddleware は X-Request-ID を伝播する
func RequestIDMiddleware() echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			reqID := c.Request().Header.Get("X-Request-ID")
			if reqID == "" {
				reqID = uuid.New().String()
			}
			c.Set("request_id", reqID)
			c.Response().Header().Set("X-Request-ID", reqID)
			return next(c)
		}
	}
}

// ── /metrics エンドポイント ────────────────────────────────────────────────────

// MetricsResponse は /metrics の JSON レスポンス
type MetricsResponse struct {
	Timestamp     string            `json:"timestamp"`
	Uptime        string            `json:"uptime"`
	CacheHits     int64             `json:"cache_hits"`
	CacheMisses   int64             `json:"cache_misses"`
	CacheHitRate  float64           `json:"cache_hit_rate"`  // 0-100 (%)
	TotalRequests int64             `json:"total_requests"`
	PathCounts    map[string]int64  `json:"path_counts"`
	ErrorCounts   map[string]int64  `json:"error_counts"`
	GoRoutines    int               `json:"goroutines"`
}

// ── /heartbeat ハンドラ (Cached) ──────────────────────────────────────────────

func heartbeatHandler(rdb *redis.Client) echo.HandlerFunc {
	return func(c echo.Context) error {
		deviceID := c.QueryParam("device_id")
		if deviceID == "" {
			deviceID = "unknown"
		}

		cacheKey := fmt.Sprintf("hb:%s", deviceID)
		ctx := c.Request().Context()

		// キャッシュ確認
		if _, err := rdb.Get(ctx, cacheKey).Result(); err == nil {
			globalCacheMetrics.Hit()
			c.Response().Header().Set("X-Cache", "HIT")
			return c.JSON(http.StatusOK, map[string]interface{}{
				"status":    "ok",
				"device_id": deviceID,
				"cached":    true,
				"timestamp": time.Now().UTC(),
			})
		}

		// キャッシュミス
		globalCacheMetrics.Miss()
		c.Response().Header().Set("X-Cache", "MISS")

		// キャッシュに保存 (30秒 TTL)
		_ = rdb.Set(ctx, cacheKey, "1", 30*time.Second).Err()

		return c.JSON(http.StatusOK, map[string]interface{}{
			"status":    "ok",
			"device_id": deviceID,
			"cached":    false,
			"timestamp": time.Now().UTC(),
		})
	}
}

// ── メイン ─────────────────────────────────────────────────────────────────────

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	startTime := time.Now()

	// ── Redis 接続 ────────────────────────────────────────────────────
	rdb := redis.NewClient(&redis.Options{
		Addr: getEnv("REDIS_ADDR", "localhost:6379"),
	})
	ctx := context.Background()
	if err := rdb.Ping(ctx).Err(); err != nil {
		fmt.Fprintf(os.Stderr, "WARNING: Redis not available: %v\n", err)
	}

	// ── Echo セットアップ ─────────────────────────────────────────────
	e := echo.New()
	e.HideBanner = true
	e.Use(RequestIDMiddleware())
	e.Use(MetricsMiddleware())
	e.Use(middleware.Recover())

	// ── pprof エンドポイントを Echo に登録 ────────────────────────────
	// net/http/pprof は init() で DefaultServeMux に登録される
	// Echo からも /debug/pprof/* にアクセスできるようにする
	e.GET("/debug/pprof/*", echo.WrapHandler(http.DefaultServeMux))
	e.GET("/debug/pprof/", echo.WrapHandler(http.DefaultServeMux))

	// ── ビジネスルート ────────────────────────────────────────────────
	e.GET("/heartbeat", heartbeatHandler(rdb))

	e.GET("/health", func(c echo.Context) error {
		checks := map[string]string{"api": "up"}
		if err := rdb.Ping(c.Request().Context()).Err(); err != nil {
			checks["redis"] = "down"
		} else {
			checks["redis"] = "up"
		}
		return c.JSON(http.StatusOK, map[string]interface{}{
			"status": "ok",
			"checks": checks,
		})
	})

	// ── /metrics エンドポイント ───────────────────────────────────────
	e.GET("/metrics", func(c echo.Context) error {
		hits, misses, hitRate := globalCacheMetrics.Stats()
		pathCounts, errorCounts, total := globalRequestCounter.Snapshot()
		uptime := time.Since(startTime).Round(time.Second).String()

		return c.JSON(http.StatusOK, MetricsResponse{
			Timestamp:     time.Now().UTC().Format(time.RFC3339),
			Uptime:        uptime,
			CacheHits:     hits,
			CacheMisses:   misses,
			CacheHitRate:  hitRate,
			TotalRequests: total,
			PathCounts:    pathCounts,
			ErrorCounts:   errorCounts,
			GoRoutines:    runtime.NumGoroutine(),
		})
	})

	port := getEnv("PORT", "8080")
	e.Logger.Fatal(e.Start(":" + port))
}
