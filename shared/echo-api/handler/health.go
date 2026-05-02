package handler

import (
	"net/http"
	"os"
	"time"

	"github.com/labstack/echo/v4"
)

// GetHealth handles GET /health.
// Returns a JSON object containing the application status, the hostname of
// the server that handled the request, and the current UTC time.
func GetHealth(c echo.Context) error {
	hostname, err := os.Hostname()
	if err != nil {
		hostname = "unknown"
	}

	return c.JSON(http.StatusOK, map[string]string{
		"status":   "ok",
		"hostname": hostname,
		"time":     time.Now().UTC().Format(time.RFC3339),
	})
}
