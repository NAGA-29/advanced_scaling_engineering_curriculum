package handler

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/labstack/echo/v4"

	"github.com/advanced-scaling/echo-api/cache"
)

// UserHandler holds the dependencies required by user-related HTTP handlers.
type UserHandler struct {
	DB    *sql.DB
	Cache cache.CacheStore
}

// user is the internal representation of a user row.
type user struct {
	ID       int64  `json:"id"`
	TenantID int64  `json:"tenant_id"`
	Name     string `json:"name"`
	Email    string `json:"email"`
}

// createUserRequest is the body expected by POST /users.
type createUserRequest struct {
	TenantID int64  `json:"tenant_id"`
	Name     string `json:"name"`
	Email    string `json:"email"`
}

// cacheKey returns the Redis key for a user by their string ID.
func cacheKey(id string) string {
	return fmt.Sprintf("user:%s", id)
}

// GetUser handles GET /users/:id.
// It first checks the cache; on a miss it queries the database, then
// populates the cache for subsequent requests (cache-aside pattern).
func (h *UserHandler) GetUser(c echo.Context) error {
	id := c.Param("id")
	if id == "" {
		return echo.NewHTTPError(http.StatusBadRequest, "missing user id")
	}

	ctx := c.Request().Context()
	key := cacheKey(id)

	// Cache-aside: check cache first.
	if cached, err := h.Cache.Get(ctx, key); err == nil {
		var u user
		if jsonErr := json.Unmarshal([]byte(cached), &u); jsonErr == nil {
			c.Response().Header().Set("X-Cache", "HIT")
			return c.JSON(http.StatusOK, u)
		}
	}

	// Cache miss – fetch from database.
	var u user
	row := h.DB.QueryRowContext(ctx,
		"SELECT id, tenant_id, name, email FROM users WHERE id = ?", id)
	if err := row.Scan(&u.ID, &u.TenantID, &u.Name, &u.Email); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return echo.NewHTTPError(http.StatusNotFound, "user not found")
		}
		return echo.NewHTTPError(http.StatusInternalServerError, "database error")
	}

	// Populate cache for next request.
	if encoded, err := json.Marshal(u); err == nil {
		_ = h.Cache.Set(ctx, key, string(encoded), 5*time.Minute)
	}

	c.Response().Header().Set("X-Cache", "MISS")
	return c.JSON(http.StatusOK, u)
}

// CreateUser handles POST /users.
// It inserts a new user row into the database and returns the created
// resource with its auto-assigned ID.
func (h *UserHandler) CreateUser(c echo.Context) error {
	var req createUserRequest
	if err := c.Bind(&req); err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid request body")
	}

	if req.Name == "" || req.Email == "" {
		return echo.NewHTTPError(http.StatusBadRequest, "name and email are required")
	}

	ctx := c.Request().Context()

	result, err := h.DB.ExecContext(ctx,
		"INSERT INTO users (tenant_id, name, email) VALUES (?, ?, ?)",
		req.TenantID, req.Name, req.Email,
	)
	if err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to create user")
	}

	lastID, err := result.LastInsertId()
	if err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to retrieve new user id")
	}

	created := user{
		ID:       lastID,
		TenantID: req.TenantID,
		Name:     req.Name,
		Email:    req.Email,
	}

	return c.JSON(http.StatusCreated, created)
}
