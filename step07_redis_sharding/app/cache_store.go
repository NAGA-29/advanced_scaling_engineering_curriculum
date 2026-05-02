// Package main implements a sharded Redis cache store.
// It demonstrates CRC32-based key routing across multiple Redis shards.
package main

import (
	"context"
	"errors"
	"fmt"
	"hash/crc32"
	"time"

	"github.com/redis/go-redis/v9"
)

// ─── Interface ────────────────────────────────────────────────────────────────

// CacheStore defines the interface for key-value cache operations.
type CacheStore interface {
	// Get retrieves a value by key. Returns ("", nil) on cache miss.
	Get(ctx context.Context, key string) (string, error)
	// Set stores a value with the given TTL. TTL=0 means no expiry.
	Set(ctx context.Context, key string, value string, ttl time.Duration) error
	// Del removes a key from the cache.
	Del(ctx context.Context, key string) error
}

// ─── PickShard ────────────────────────────────────────────────────────────────

// PickShard returns the shard index for the given key using CRC32 modulo.
// This is a simple, deterministic shard assignment.
//
// Limitation: changing shardCount causes ~(1 - 1/new_count) keys to be
// reassigned to different shards, causing cache misses.
// For production use with dynamic shard counts, use ConsistentHash instead.
func PickShard(key string, shardCount int) int {
	if shardCount <= 0 {
		panic("shardCount must be > 0")
	}
	checksum := crc32.ChecksumIEEE([]byte(key))
	return int(checksum) % shardCount
}

// ─── SingleRedisStore ────────────────────────────────────────────────────────

// SingleRedisStore is a CacheStore backed by a single Redis client.
// Use this for simple cases or as a baseline for comparison.
type SingleRedisStore struct {
	client *redis.Client
}

// NewSingleRedisStore creates a SingleRedisStore connected to the given address.
func NewSingleRedisStore(addr string) *SingleRedisStore {
	client := redis.NewClient(&redis.Options{
		Addr:         addr,
		DialTimeout:  5 * time.Second,
		ReadTimeout:  3 * time.Second,
		WriteTimeout: 3 * time.Second,
		PoolSize:     20,
		MinIdleConns: 5,
	})
	return &SingleRedisStore{client: client}
}

// Get retrieves a value. Returns ("", nil) on cache miss (redis.Nil).
func (s *SingleRedisStore) Get(ctx context.Context, key string) (string, error) {
	val, err := s.client.Get(ctx, key).Result()
	if errors.Is(err, redis.Nil) {
		return "", nil // cache miss is not an error
	}
	if err != nil {
		return "", fmt.Errorf("SingleRedisStore.Get %q: %w", key, err)
	}
	return val, nil
}

// Set stores a value with the given TTL.
func (s *SingleRedisStore) Set(ctx context.Context, key string, value string, ttl time.Duration) error {
	err := s.client.Set(ctx, key, value, ttl).Err()
	if err != nil {
		return fmt.Errorf("SingleRedisStore.Set %q: %w", key, err)
	}
	return nil
}

// Del removes a key.
func (s *SingleRedisStore) Del(ctx context.Context, key string) error {
	err := s.client.Del(ctx, key).Err()
	if err != nil {
		return fmt.Errorf("SingleRedisStore.Del %q: %w", key, err)
	}
	return nil
}

// Close releases the Redis connection pool.
func (s *SingleRedisStore) Close() error {
	return s.client.Close()
}

// ─── ShardedRedisStore ───────────────────────────────────────────────────────

// ShardedRedisStore distributes keys across multiple Redis shards using CRC32.
// The shard index is determined by: int(crc32(key)) % shardCount
type ShardedRedisStore struct {
	shards []*redis.Client
	count  int
}

// NewShardedRedisStore creates a ShardedRedisStore from a list of Redis addresses.
// Each address corresponds to one shard (e.g., ["localhost:6379", "localhost:6380", "localhost:6381"]).
func NewShardedRedisStore(addrs []string) (*ShardedRedisStore, error) {
	if len(addrs) == 0 {
		return nil, fmt.Errorf("NewShardedRedisStore: at least one address required")
	}

	shards := make([]*redis.Client, 0, len(addrs))
	for i, addr := range addrs {
		client := redis.NewClient(&redis.Options{
			Addr:         addr,
			DialTimeout:  5 * time.Second,
			ReadTimeout:  3 * time.Second,
			WriteTimeout: 3 * time.Second,
			PoolSize:     20,
			MinIdleConns: 5,
		})

		// Validate connectivity
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := client.Ping(ctx).Err(); err != nil {
			// Non-fatal: log and continue; the shard may become available later
			fmt.Printf("WARNING: shard %d (%s) ping failed: %v\n", i, addr, err)
		}

		shards = append(shards, client)
	}

	return &ShardedRedisStore{
		shards: shards,
		count:  len(shards),
	}, nil
}

// shardFor returns the Redis client for the given key.
func (s *ShardedRedisStore) shardFor(key string) *redis.Client {
	idx := PickShard(key, s.count)
	return s.shards[idx]
}

// ShardIndexFor returns the shard index for the given key (useful for debugging).
func (s *ShardedRedisStore) ShardIndexFor(key string) int {
	return PickShard(key, s.count)
}

// Get retrieves a value from the appropriate shard.
// Returns ("", nil) on cache miss.
func (s *ShardedRedisStore) Get(ctx context.Context, key string) (string, error) {
	shard := s.shardFor(key)
	val, err := shard.Get(ctx, key).Result()
	if errors.Is(err, redis.Nil) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("ShardedRedisStore.Get %q (shard %d): %w", key, s.ShardIndexFor(key), err)
	}
	return val, nil
}

// Set stores a value in the appropriate shard.
func (s *ShardedRedisStore) Set(ctx context.Context, key string, value string, ttl time.Duration) error {
	shard := s.shardFor(key)
	err := shard.Set(ctx, key, value, ttl).Err()
	if err != nil {
		return fmt.Errorf("ShardedRedisStore.Set %q (shard %d): %w", key, s.ShardIndexFor(key), err)
	}
	return nil
}

// Del removes a key from the appropriate shard.
func (s *ShardedRedisStore) Del(ctx context.Context, key string) error {
	shard := s.shardFor(key)
	err := shard.Del(ctx, key).Err()
	if err != nil {
		return fmt.Errorf("ShardedRedisStore.Del %q (shard %d): %w", key, s.ShardIndexFor(key), err)
	}
	return nil
}

// ShardCount returns the number of shards.
func (s *ShardedRedisStore) ShardCount() int {
	return s.count
}

// Shard returns the Redis client for shard i (for direct INFO queries etc.)
func (s *ShardedRedisStore) Shard(i int) *redis.Client {
	if i < 0 || i >= s.count {
		panic(fmt.Sprintf("shard index %d out of range [0, %d)", i, s.count))
	}
	return s.shards[i]
}

// Close releases all shard connection pools.
func (s *ShardedRedisStore) Close() error {
	var errs []error
	for i, shard := range s.shards {
		if err := shard.Close(); err != nil {
			errs = append(errs, fmt.Errorf("shard %d close: %w", i, err))
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("ShardedRedisStore.Close errors: %v", errs)
	}
	return nil
}

// KeyspaceStats returns the number of keys in each shard's DB 0.
func (s *ShardedRedisStore) KeyspaceStats(ctx context.Context) ([]int64, error) {
	counts := make([]int64, s.count)
	for i, shard := range s.shards {
		n, err := shard.DBSize(ctx).Result()
		if err != nil {
			return nil, fmt.Errorf("shard %d DBSize: %w", i, err)
		}
		counts[i] = n
	}
	return counts, nil
}
