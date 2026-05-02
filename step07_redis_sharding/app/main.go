// main.go — Step 07 Redis Sharding demo entry point
//
// Demonstrates CRC32-based sharding and Consistent Hashing across 3 Redis instances.
//
// Usage:
//   go run . --action=write --shards=3 --count=1000
//   go run . --action=read  --shards=3 --count=1000
//   go run . --action=stats
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"time"
)

func main() {
	var (
		action     = flag.String("action", "stats", "Action: write, read, stats, demo")
		shardCount = flag.Int("shards", 3, "Number of Redis shards")
		count      = flag.Int("count", 100, "Number of keys for write/read")
		key        = flag.String("key", "", "Specific key to look up (for read action)")
	)
	flag.Parse()

	// Build addresses based on shard count
	addrs := make([]string, 0, *shardCount)
	for i := 0; i < *shardCount; i++ {
		addrs = append(addrs, fmt.Sprintf("localhost:%d", 6379+i))
	}

	ctx := context.Background()

	switch *action {
	case "write":
		store, err := NewShardedRedisStore(addrs)
		if err != nil {
			log.Fatalf("NewShardedRedisStore: %v", err)
		}
		defer store.Close()

		log.Printf("Writing %d keys across %d shards...", *count, *shardCount)
		for i := 0; i < *count; i++ {
			k := fmt.Sprintf("user:%d", i)
			v := fmt.Sprintf(`{"id":%d,"name":"User %d"}`, i, i)
			if err := store.Set(ctx, k, v, 10*time.Minute); err != nil {
				log.Printf("Set(%s): %v", k, err)
			}
		}
		log.Printf("Done. Run --action=stats to see distribution.")

	case "read":
		store, err := NewShardedRedisStore(addrs)
		if err != nil {
			log.Fatalf("NewShardedRedisStore: %v", err)
		}
		defer store.Close()

		if *key != "" {
			// Single key lookup
			val, err := store.Get(ctx, *key)
			shard := store.ShardIndexFor(*key)
			log.Printf("Key: %s  Shard: %d  Value: %q  Err: %v", *key, shard, val, err)
			return
		}

		log.Printf("Reading %d keys from %d shards...", *count, *shardCount)
		hits, misses := 0, 0
		for i := 0; i < *count; i++ {
			k := fmt.Sprintf("user:%d", i)
			val, err := store.Get(ctx, k)
			if err != nil {
				log.Printf("Get(%s): %v", k, err)
				continue
			}
			if val == "" {
				misses++
			} else {
				hits++
			}
		}
		total := hits + misses
		log.Printf("Results: hits=%d (%d%%) misses=%d (%d%%)",
			hits, hits*100/total,
			misses, misses*100/total)

	case "stats":
		store, err := NewShardedRedisStore(addrs)
		if err != nil {
			log.Fatalf("NewShardedRedisStore: %v", err)
		}
		defer store.Close()

		counts, err := store.KeyspaceStats(ctx)
		if err != nil {
			log.Fatalf("KeyspaceStats: %v", err)
		}
		fmt.Println("=== Redis Shard Distribution ===")
		total := int64(0)
		for _, c := range counts {
			total += c
		}
		for i, c := range counts {
			pct := 0.0
			if total > 0 {
				pct = float64(c) / float64(total) * 100
			}
			bar := ""
			for b := 0; b < int(pct/2); b++ {
				bar += "#"
			}
			fmt.Printf("  shard %d (:%d): %6d keys (%5.1f%%) |%-25s|\n",
				i, 6379+i, c, pct, bar)
		}
		fmt.Printf("  Total: %d keys across %d shards\n", total, len(counts))
		fmt.Println("================================")

	case "demo":
		// Demo: show shard assignment for sample keys
		fmt.Println("=== CRC32 Shard Assignment Demo ===")
		sampleKeys := []string{
			"user:1", "user:2", "user:3", "user:100", "user:12345",
			"session:abc123", "product:999", "tenant:42",
		}
		for _, k := range sampleKeys {
			shard := PickShard(k, *shardCount)
			fmt.Printf("  %-25s -> shard %d\n", k, shard)
		}
		fmt.Println("")

		// Show consistent hash assignment for same keys
		fmt.Println("=== Consistent Hash Assignment Demo ===")
		ch := NewConsistentHash(100)
		for _, addr := range addrs {
			ch.Add(addr)
		}
		for _, k := range sampleKeys {
			node := ch.Get(k)
			fmt.Printf("  %-25s -> %s\n", k, node)
		}
		fmt.Println("========================================")

	default:
		fmt.Fprintf(os.Stderr, "Unknown action: %s\n", *action)
		flag.Usage()
		os.Exit(1)
	}
}
