package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/google/uuid"
	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
	"github.com/redis/go-redis/v9"

	"github.com/advanced-scaling/step11-api/queue"
)

// ── リクエスト/レスポンス型 ──────────────────────────────────────────────────

// EventRequest は POST /events のリクエストボディ
type EventRequest struct {
	DeviceID  string `json:"device_id"  validate:"required"`
	EventType string `json:"event_type" validate:"required"`
	Payload   string `json:"payload"`
}

// EventResponse は POST /events の 202 レスポンス
type EventResponse struct {
	Accepted       bool   `json:"accepted"`
	EventID        string `json:"event_id"`        // クライアントが追跡に使う
	IdempotencyKey string `json:"idempotency_key"` // 冪等性キー
	Message        string `json:"message"`
	QueuedAt       string `json:"queued_at"`
}

// ── ハンドラ ──────────────────────────────────────────────────────────────────

// EventsHandler は POST /events を処理するハンドラ
// DB には書かず Redis Stream に XADD するだけなので超高速 (< 5ms)
func EventsHandler(q queue.Queue) echo.HandlerFunc {
	return func(c echo.Context) error {
		// ── 1. リクエスト解析 ──────────────────────────────────────────
		var req EventRequest
		if err := c.Bind(&req); err != nil {
			return c.JSON(http.StatusBadRequest, map[string]string{
				"error":   "invalid_request",
				"message": "request body must be valid JSON",
			})
		}

		if req.DeviceID == "" || req.EventType == "" {
			return c.JSON(http.StatusBadRequest, map[string]string{
				"error":   "missing_required_fields",
				"message": "device_id and event_type are required",
			})
		}

		// ── 2. 冪等性キーの決定 ───────────────────────────────────────
		// X-Idempotency-Key ヘッダがあればそれを使用、なければ UUID 生成
		idempotencyKey := c.Request().Header.Get("X-Idempotency-Key")
		if idempotencyKey == "" {
			idempotencyKey = uuid.New().String()
		}

		// ── 3. Redis Stream へ Publish ────────────────────────────────
		// この操作だけなのでレイテンシが低い
		event := queue.Event{
			DeviceID:       req.DeviceID,
			EventType:      req.EventType,
			Payload:        req.Payload,
			CreatedAt:      time.Now().UTC(),
			IdempotencyKey: idempotencyKey,
		}

		ctx, cancel := context.WithTimeout(c.Request().Context(), 3*time.Second)
		defer cancel()

		if err := q.Publish(ctx, "events", event); err != nil {
			// Redis エラーは 503 を返す
			return c.JSON(http.StatusServiceUnavailable, map[string]string{
				"error":   "queue_unavailable",
				"message": fmt.Sprintf("failed to queue event: %v", err),
			})
		}

		// ── 4. 202 Accepted を即座に返す ──────────────────────────────
		// クライアントには「受け付けた」だけを通知
		// 実際の処理完了は Worker が行う
		c.Response().Header().Set("X-Idempotency-Key", idempotencyKey)

		return c.JSON(http.StatusAccepted, EventResponse{
			Accepted:       true,
			EventID:        idempotencyKey,
			IdempotencyKey: idempotencyKey,
			Message:        "event accepted and queued for processing",
			QueuedAt:       time.Now().UTC().Format(time.RFC3339),
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
	// ── Redis 接続 ────────────────────────────────────────────────────
	rdb := redis.NewClient(&redis.Options{
		Addr:     getEnv("REDIS_ADDR", "localhost:6379"),
		Password: getEnv("REDIS_PASSWORD", ""),
		DB:       0,
	})

	ctx := context.Background()
	if _, err := rdb.Ping(ctx).Result(); err != nil {
		fmt.Fprintf(os.Stderr, "failed to connect to Redis: %v\n", err)
		os.Exit(1)
	}

	q := queue.NewRedisStreamQueue(rdb)

	// ── Echo セットアップ ─────────────────────────────────────────────
	e := echo.New()
	e.HideBanner = true
	e.Use(middleware.Logger())
	e.Use(middleware.Recover())

	// X-Request-ID ミドルウェア
	e.Use(func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			reqID := c.Request().Header.Get("X-Request-ID")
			if reqID == "" {
				reqID = uuid.New().String()
			}
			c.Set("request_id", reqID)
			c.Response().Header().Set("X-Request-ID", reqID)
			return next(c)
		}
	})

	// ── ルーティング ──────────────────────────────────────────────────
	e.POST("/events", EventsHandler(q))

	e.GET("/health", func(c echo.Context) error {
		// Redis の疎通確認
		if err := rdb.Ping(c.Request().Context()).Err(); err != nil {
			return c.JSON(http.StatusServiceUnavailable, map[string]string{
				"status":  "degraded",
				"redis":   "down",
				"message": err.Error(),
			})
		}
		return c.JSON(http.StatusOK, map[string]interface{}{
			"status":    "ok",
			"redis":     "up",
			"timestamp": time.Now().UTC(),
		})
	})

	port := getEnv("PORT", "8080")
	e.Logger.Fatal(e.Start(":" + port))
}
