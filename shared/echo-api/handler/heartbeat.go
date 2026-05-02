package handler

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"time"

	"github.com/labstack/echo/v4"
)

// HeartbeatHandler holds dependencies for heartbeat and event handlers.
type HeartbeatHandler struct {
	DB *sql.DB
}

// heartbeatRequest is the body expected by POST /heartbeat.
type heartbeatRequest struct {
	DeviceID  string `json:"device_id"`
	Status    string `json:"status"`
	Timestamp string `json:"timestamp"`
}

// eventRequest is the body expected by POST /events.
type eventRequest struct {
	DeviceID  string `json:"device_id"`
	EventType string `json:"event_type"`
	Payload   any    `json:"payload"`
}

// PostHeartbeat handles POST /heartbeat.
// It validates the request body and inserts a row into the heartbeats table.
func (h *HeartbeatHandler) PostHeartbeat(c echo.Context) error {
	var req heartbeatRequest
	if err := c.Bind(&req); err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid request body")
	}

	if req.DeviceID == "" {
		return echo.NewHTTPError(http.StatusBadRequest, "device_id is required")
	}
	if req.Status == "" {
		return echo.NewHTTPError(http.StatusBadRequest, "status is required")
	}

	// Parse the provided timestamp, falling back to now if absent or invalid.
	ts := time.Now().UTC()
	if req.Timestamp != "" {
		if parsed, err := time.Parse(time.RFC3339, req.Timestamp); err == nil {
			ts = parsed.UTC()
		}
	}

	ctx := c.Request().Context()
	_, err := h.DB.ExecContext(ctx,
		"INSERT INTO heartbeats (device_id, status, created_at) VALUES (?, ?, ?)",
		req.DeviceID, req.Status, ts.Format("2006-01-02 15:04:05"),
	)
	if err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to store heartbeat")
	}

	return c.JSON(http.StatusAccepted, map[string]string{
		"result": "accepted",
	})
}

// PostEvent handles POST /events.
// It validates the request body and inserts a row into the events table.
func (h *HeartbeatHandler) PostEvent(c echo.Context) error {
	var req eventRequest
	if err := c.Bind(&req); err != nil {
		return echo.NewHTTPError(http.StatusBadRequest, "invalid request body")
	}

	if req.DeviceID == "" {
		return echo.NewHTTPError(http.StatusBadRequest, "device_id is required")
	}
	if req.EventType == "" {
		return echo.NewHTTPError(http.StatusBadRequest, "event_type is required")
	}

	payloadJSON := encodedPayload(req.Payload)

	ctx := c.Request().Context()
	_, err := h.DB.ExecContext(ctx,
		"INSERT INTO events (device_id, event_type, payload, created_at) VALUES (?, ?, ?, ?)",
		req.DeviceID, req.EventType, payloadJSON,
		time.Now().UTC().Format("2006-01-02 15:04:05"),
	)
	if err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "failed to store event")
	}

	return c.JSON(http.StatusAccepted, map[string]string{
		"result": "accepted",
	})
}

// encodedPayload converts an arbitrary value to a compact JSON string.
// It returns "{}" when marshalling fails rather than propagating the error,
// because a missing or un-serialisable payload should not abort the request.
func encodedPayload(v any) string {
	if v == nil {
		return "{}"
	}
	b, err := json.Marshal(v)
	if err != nil {
		return "{}"
	}
	return string(b)
}
