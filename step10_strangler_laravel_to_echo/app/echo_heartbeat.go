package main

import (
	"context"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/golang-jwt/jwt/v5"
	echojwt "github.com/labstack/echo-jwt/v4"
	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
)

// getEnv は環境変数を取得し、未設定の場合はデフォルト値を返す
func getEnv(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

// HeartbeatResponse は Laravel の HeartbeatController と同じ JSON 形式を返す
type HeartbeatResponse struct {
	Status    string    `json:"status"`
	Service   string    `json:"service"`
	Timestamp time.Time `json:"timestamp"`
	Version   string    `json:"version"`
	RequestID string    `json:"request_id,omitempty"`
}

// JWTClaims はトークンのペイロード定義
type JWTClaims struct {
	DeviceID string `json:"device_id"`
	jwt.RegisteredClaims
}

func main() {
	e := echo.New()
	e.HideBanner = true

	// ── ミドルウェア ──────────────────────────────────────────────────
	e.Use(middleware.Logger())
	e.Use(middleware.Recover())
	e.Use(RequestIDMiddleware()) // X-Request-ID 伝播

	// ── JWT シークレット (環境変数から取得、デフォルトは dev 用) ─────
	jwtSecret := getEnv("JWT_SECRET", "dev-secret-change-in-production")

	// ── 認証不要ルート ────────────────────────────────────────────────
	// /health は JWT なしでヘルスチェック可能
	e.GET("/health", healthHandler)

	// ── 認証必要ルート ────────────────────────────────────────────────
	// JWT ミドルウェアを適用したグループ
	protected := e.Group("")
	protected.Use(echojwt.WithConfig(echojwt.Config{
		NewClaimsFunc: func(c echo.Context) jwt.Claims {
			return new(JWTClaims)
		},
		SigningKey:   []byte(jwtSecret),
		TokenLookup: "header:Authorization",
		AuthScheme:  "Bearer",
		// カスタムエラーハンドラ: JWT エラー時に 401 JSON を返す
		ErrorHandler: func(c echo.Context, err error) error {
			return c.JSON(http.StatusUnauthorized, map[string]interface{}{
				"error":   "unauthorized",
				"message": "JWT token missing or invalid",
				"detail":  err.Error(),
			})
		},
	}))

	// Laravel の GET /heartbeat と同等
	protected.GET("/heartbeat", heartbeatHandler)

	// POST /events (step11 の非同期キューと連携)
	protected.POST("/events", eventsHandler)

	// ── サーバー起動 (シグナル受信時にグレースフルシャットダウン) ───
	port := getEnv("PORT", "8080")
	srv := &http.Server{Addr: ":" + port, Handler: e}

	go func() {
		e.Logger.Infof("Starting server on :%s", port)
		if err := e.StartServer(srv); err != nil && err != http.ErrServerClosed {
			e.Logger.Fatalf("server error: %v", err)
		}
	}()

	// OS シグナルを待機
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, os.Interrupt, syscall.SIGTERM)
	<-quit

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		e.Logger.Fatal(err)
	}
}

// heartbeatHandler は Laravel の HeartbeatController::index() と同等の処理を行う
// Laravel 側のレスポンス形式:
//
//	{
//	  "status": "ok",
//	  "service": "laravel-api",
//	  "timestamp": "2024-01-01T00:00:00Z"
//	}
//
// Echo 側も同じ形式を返す (service 名だけ変わる)
func heartbeatHandler(c echo.Context) error {
	// JWT クレームからデバイス ID を取得
	user, ok := c.Get("user").(*jwt.Token)
	deviceID := "unknown"
	if ok && user != nil {
		if claims, ok := user.Claims.(*JWTClaims); ok {
			deviceID = claims.DeviceID
		}
	}

	// X-Request-ID は RequestIDMiddleware がコンテキストにセット済み
	reqID, _ := c.Get("request_id").(string)

	resp := HeartbeatResponse{
		Status:    "ok",
		Service:   "echo-api",                // Laravel は "laravel-api"
		Timestamp: time.Now().UTC(),
		Version:   "1.0.0",
		RequestID: reqID,
	}

	// 処理したサービスを示すカスタムヘッダ (Nginx の X-Handled-By と別に Echo 自身もセット)
	c.Response().Header().Set("X-Handled-By", "echo")
	c.Response().Header().Set("X-Device-ID", deviceID)

	return c.JSON(http.StatusOK, resp)
}

// eventsHandler は POST /events を受け付けて 202 Accepted を返す
// 実際の処理は step11 の非同期ワーカーが行う
func eventsHandler(c echo.Context) error {
	type EventRequest struct {
		DeviceID  string `json:"device_id" validate:"required"`
		EventType string `json:"event_type" validate:"required"`
		Payload   string `json:"payload"`
	}

	var req EventRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{
			"error": "invalid request body",
		})
	}

	reqID, _ := c.Get("request_id").(string)

	return c.JSON(http.StatusAccepted, map[string]interface{}{
		"accepted":   true,
		"request_id": reqID,
		"message":    "event queued for processing",
	})
}

// healthHandler は認証なしで疎通確認用
func healthHandler(c echo.Context) error {
	return c.JSON(http.StatusOK, map[string]interface{}{
		"status":    "ok",
		"service":   "echo-api",
		"timestamp": time.Now().UTC(),
	})
}
