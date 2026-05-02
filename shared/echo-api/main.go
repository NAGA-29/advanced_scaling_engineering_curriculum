package main

import (
	"context"
	"log"
	"net/http"
	_ "net/http/pprof" // registers pprof handlers on http.DefaultServeMux
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"

	"github.com/advanced-scaling/echo-api/cache"
	"github.com/advanced-scaling/echo-api/db"
	"github.com/advanced-scaling/echo-api/handler"
)

func main() {
	// -------------------------------------------------------------------------
	// Configuration from environment
	// -------------------------------------------------------------------------
	dsn := getEnv("DB_DSN", "root:root@tcp(127.0.0.1:3306)/app?parseTime=true")
	redisAddr := getEnv("REDIS_ADDR", "127.0.0.1:6379")
	appPort := getEnv("APP_PORT", "8080")
	redisEnabled := !strings.EqualFold(getEnv("REDIS_ENABLED", "true"), "false")

	// -------------------------------------------------------------------------
	// Database
	// -------------------------------------------------------------------------
	database, err := db.NewDB(dsn)
	if err != nil {
		log.Fatalf("failed to connect to database: %v", err)
	}
	defer database.Close()

	// -------------------------------------------------------------------------
	// Cache
	// -------------------------------------------------------------------------
	var cacheStore cache.CacheStore
	if redisEnabled {
		redisStore, err := cache.NewRedisStore(redisAddr)
		if err != nil {
			log.Printf("WARNING: redis unavailable (%v) – falling back to no-op cache", err)
			cacheStore = &cache.NoopStore{}
		} else {
			cacheStore = redisStore
		}
	} else {
		log.Println("Redis disabled via REDIS_ENABLED=false – using no-op cache")
		cacheStore = &cache.NoopStore{}
	}

	// -------------------------------------------------------------------------
	// Handlers
	// -------------------------------------------------------------------------
	userHandler := &handler.UserHandler{
		DB:    database,
		Cache: cacheStore,
	}
	hbHandler := &handler.HeartbeatHandler{
		DB: database,
	}

	// -------------------------------------------------------------------------
	// Echo instance
	// -------------------------------------------------------------------------
	e := echo.New()
	e.HideBanner = true
	e.HidePort = true

	// Request-ID middleware: honour an incoming X-Request-ID header or generate
	// a new UUID so that every request can be traced end-to-end.
	e.Use(middleware.RequestIDWithConfig(middleware.RequestIDConfig{
		Generator: func() string {
			return uuid.NewString()
		},
		RequestIDHandler: func(c echo.Context, id string) {
			c.Response().Header().Set(echo.HeaderXRequestID, id)
		},
		TargetHeader: echo.HeaderXRequestID,
	}))

	// Structured request logging.
	e.Use(middleware.LoggerWithConfig(middleware.LoggerConfig{
		Format: `{"time":"${time_rfc3339}","id":"${id}","method":"${method}","uri":"${uri}","status":${status},"latency_ms":${latency_ms}}` + "\n",
	}))

	e.Use(middleware.Recover())

	// -------------------------------------------------------------------------
	// Routes
	// -------------------------------------------------------------------------
	e.GET("/health", handler.GetHealth)

	e.GET("/users/:id", userHandler.GetUser)
	e.POST("/users", userHandler.CreateUser)

	e.POST("/heartbeat", hbHandler.PostHeartbeat)
	e.POST("/events", hbHandler.PostEvent)

	// pprof endpoints – served on the same port under /debug/pprof via a
	// thin Echo handler that delegates to the standard library's DefaultServeMux.
	debugGroup := e.Group("/debug/pprof")
	debugGroup.Any("", echo.WrapHandler(http.DefaultServeMux))
	debugGroup.Any("/*", echo.WrapHandler(http.DefaultServeMux))

	// -------------------------------------------------------------------------
	// Graceful shutdown
	// -------------------------------------------------------------------------
	go func() {
		addr := ":" + appPort
		log.Printf("starting server on %s", addr)
		if err := e.Start(addr); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	log.Println("shutting down server…")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := e.Shutdown(ctx); err != nil {
		log.Fatalf("server forced to shutdown: %v", err)
	}

	log.Println("server exited")
}

// getEnv returns the value of the named environment variable, or fallback
// when the variable is not set or is empty.
func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
