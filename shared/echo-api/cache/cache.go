package cache

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

// ErrCacheMiss is returned by Get when a key does not exist in the cache.
var ErrCacheMiss = errors.New("cache: miss")

// CacheStore is a minimal key/value cache abstraction.
type CacheStore interface {
	Get(ctx context.Context, key string) (string, error)
	Set(ctx context.Context, key string, value string, ttl time.Duration) error
	Del(ctx context.Context, key string) error
}

// RedisStore is a CacheStore backed by a Redis server.
type RedisStore struct {
	client *redis.Client
}

// NewRedisStore creates a RedisStore connected to addr (e.g. "localhost:6379").
func NewRedisStore(addr string) (*RedisStore, error) {
	client := redis.NewClient(&redis.Options{
		Addr: addr,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	if err := client.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("cache: redis ping: %w", err)
	}

	return &RedisStore{client: client}, nil
}

// Get retrieves a value from Redis. Returns ErrCacheMiss when the key is absent.
func (r *RedisStore) Get(ctx context.Context, key string) (string, error) {
	val, err := r.client.Get(ctx, key).Result()
	if errors.Is(err, redis.Nil) {
		return "", ErrCacheMiss
	}
	if err != nil {
		return "", fmt.Errorf("cache: redis get %q: %w", key, err)
	}
	return val, nil
}

// Set stores a value in Redis with the given TTL.
func (r *RedisStore) Set(ctx context.Context, key string, value string, ttl time.Duration) error {
	if err := r.client.Set(ctx, key, value, ttl).Err(); err != nil {
		return fmt.Errorf("cache: redis set %q: %w", key, err)
	}
	return nil
}

// Del removes a key from Redis.
func (r *RedisStore) Del(ctx context.Context, key string) error {
	if err := r.client.Del(ctx, key).Err(); err != nil {
		return fmt.Errorf("cache: redis del %q: %w", key, err)
	}
	return nil
}

// NoopStore is a CacheStore that does nothing. It is used when Redis is
// disabled so that the rest of the application does not need to branch on
// whether caching is available.
type NoopStore struct{}

// Get always returns ErrCacheMiss, indicating that every key is a miss.
func (n *NoopStore) Get(_ context.Context, _ string) (string, error) {
	return "", ErrCacheMiss
}

// Set is a no-op.
func (n *NoopStore) Set(_ context.Context, _ string, _ string, _ time.Duration) error {
	return nil
}

// Del is a no-op.
func (n *NoopStore) Del(_ context.Context, _ string) error {
	return nil
}
