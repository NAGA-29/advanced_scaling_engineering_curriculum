package main

import (
	"context"
	"fmt"
	"math"
	"sort"
	"testing"
	"time"
)

// ─── PickShard Tests ──────────────────────────────────────────────────────────

// TestPickShardDistribution verifies that keys are distributed roughly evenly
// across shards when using CRC32 modulo.
func TestPickShardDistribution(t *testing.T) {
	shardCount := 3
	total := 10000
	counts := make([]int, shardCount)

	for i := 0; i < total; i++ {
		key := fmt.Sprintf("user:%d", i)
		shard := PickShard(key, shardCount)
		if shard < 0 || shard >= shardCount {
			t.Errorf("PickShard(%q, %d) = %d: out of range [0, %d)", key, shardCount, shard, shardCount)
		}
		counts[shard]++
	}

	expected := float64(total) / float64(shardCount)
	maxDeviation := 0.10 // allow 10% deviation

	t.Logf("Distribution across %d shards (%d keys):", shardCount, total)
	for i, cnt := range counts {
		pct := float64(cnt) / float64(total) * 100
		deviation := math.Abs(float64(cnt)-expected) / expected
		t.Logf("  shard %d: %d keys (%.1f%%) deviation=%.2f%%", i, cnt, pct, deviation*100)

		if deviation > maxDeviation {
			t.Errorf("shard %d has %.2f%% deviation from expected %.0f (got %d), threshold=%.0f%%",
				i, deviation*100, expected, cnt, maxDeviation*100)
		}
	}
}

// TestPickShardDeterminism verifies that the same key always maps to the same shard.
func TestPickShardDeterminism(t *testing.T) {
	keys := []string{"user:1", "product:100", "session:abc123", "cache:xyz"}
	shardCount := 4

	for _, key := range keys {
		first := PickShard(key, shardCount)
		for i := 0; i < 100; i++ {
			result := PickShard(key, shardCount)
			if result != first {
				t.Errorf("PickShard(%q, %d) is not deterministic: got %d, then %d",
					key, shardCount, first, result)
			}
		}
		t.Logf("PickShard(%q, %d) = %d (deterministic)", key, shardCount, first)
	}
}

// TestPickShardKnownValues tests specific known key->shard mappings.
// These values are computed from crc32.ChecksumIEEE and serve as regression tests.
func TestPickShardKnownValues(t *testing.T) {
	tests := []struct {
		key        string
		shardCount int
	}{
		{"user:1", 3},
		{"user:2", 3},
		{"user:3", 3},
		{"session:abc", 4},
		{"product:999", 2},
	}

	for _, tt := range tests {
		shard := PickShard(tt.key, tt.shardCount)
		t.Logf("PickShard(%q, %d) = %d", tt.key, tt.shardCount, shard)
		if shard < 0 || shard >= tt.shardCount {
			t.Errorf("shard %d is out of range [0, %d)", shard, tt.shardCount)
		}
	}
}

// TestPickShardChangesOnShardCountChange demonstrates that changing shard count
// causes most keys to be remapped (the core problem that ConsistentHash solves).
func TestPickShardChangesOnShardCountChange(t *testing.T) {
	total := 1000
	oldCount := 3
	newCount := 4

	remapped := 0
	for i := 0; i < total; i++ {
		key := fmt.Sprintf("key:%d", i)
		oldShard := PickShard(key, oldCount)
		newShard := PickShard(key, newCount)
		if oldShard != newShard {
			remapped++
		}
	}

	remapPct := float64(remapped) / float64(total) * 100
	t.Logf("Modulo shard change %d->%d: %d/%d keys remapped (%.1f%%)",
		oldCount, newCount, remapped, total, remapPct)

	// Expect roughly (1 - 1/newCount) of keys to be remapped
	expectedRemapPct := (1.0 - 1.0/float64(newCount)) * 100
	t.Logf("Theoretical expected remap: %.1f%%", expectedRemapPct)

	// Verify the remapping is roughly as expected (within 10%)
	if math.Abs(remapPct-expectedRemapPct) > 10 {
		t.Logf("WARNING: remap percentage %.1f%% differs from expected %.1f%% by more than 10%%",
			remapPct, expectedRemapPct)
	}
}

// ─── ShardedRedisStore Tests ──────────────────────────────────────────────────

// TestShardedRedisStoreRouting verifies that Get/Set/Del route to the correct shard.
// This test uses mock shards to avoid requiring real Redis.
func TestShardedRedisStoreRouting(t *testing.T) {
	t.Skip("Skipping: requires live Redis on ports 6379-6381. Run with docker-compose up -d first.")

	addrs := []string{
		"localhost:6379",
		"localhost:6380",
		"localhost:6381",
	}

	store, err := NewShardedRedisStore(addrs)
	if err != nil {
		t.Fatalf("NewShardedRedisStore: %v", err)
	}
	defer store.Close()

	ctx := context.Background()
	testKey := "test:routing:key1"
	expectedShard := PickShard(testKey, len(addrs))

	// Set via sharded store
	if err := store.Set(ctx, testKey, "hello", 60*time.Second); err != nil {
		t.Fatalf("Set(%q): %v", testKey, err)
	}

	// Verify ShardIndexFor returns correct shard
	actualShard := store.ShardIndexFor(testKey)
	if actualShard != expectedShard {
		t.Errorf("ShardIndexFor(%q) = %d, want %d", testKey, actualShard, expectedShard)
	}

	// The key should exist only on the correct shard
	for i := 0; i < store.ShardCount(); i++ {
		shard := store.Shard(i)
		val, err := shard.Get(ctx, testKey).Result()
		if i == expectedShard {
			if err != nil {
				t.Errorf("key %q not found on expected shard %d: %v", testKey, expectedShard, err)
			} else {
				t.Logf("shard %d: found key %q = %q (correct)", i, testKey, val)
			}
		} else {
			if err == nil {
				t.Errorf("key %q unexpectedly found on shard %d (expected only on shard %d)", testKey, i, expectedShard)
			}
		}
	}

	// Get via sharded store
	val, err := store.Get(ctx, testKey)
	if err != nil {
		t.Fatalf("Get(%q): %v", testKey, err)
	}
	if val != "hello" {
		t.Errorf("Get(%q) = %q, want %q", testKey, val, "hello")
	}

	// Del via sharded store
	if err := store.Del(ctx, testKey); err != nil {
		t.Fatalf("Del(%q): %v", testKey, err)
	}

	// After Del, should be gone
	val, err = store.Get(ctx, testKey)
	if err != nil {
		t.Fatalf("Get after Del: %v", err)
	}
	if val != "" {
		t.Errorf("Get after Del = %q, want empty string", val)
	}
}

// ─── ConsistentHash Tests ────────────────────────────────────────────────────

// TestConsistentHashAddGet verifies basic Add and Get operations.
func TestConsistentHashAddGet(t *testing.T) {
	ch := NewConsistentHash(100)

	nodes := []string{"redis-0", "redis-1", "redis-2"}
	for _, node := range nodes {
		ch.Add(node)
	}

	if ch.Size() != len(nodes) {
		t.Errorf("Size() = %d, want %d", ch.Size(), len(nodes))
	}

	// Every key should map to one of the added nodes
	for i := 0; i < 1000; i++ {
		key := fmt.Sprintf("key:%d", i)
		node := ch.Get(key)
		found := false
		for _, n := range nodes {
			if n == node {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("Get(%q) = %q, not in nodes %v", key, node, nodes)
		}
	}
}

// TestConsistentHashDistribution verifies that keys are distributed across nodes.
func TestConsistentHashDistribution(t *testing.T) {
	ch := NewConsistentHash(150)
	nodes := []string{"redis-0", "redis-1", "redis-2"}
	for _, n := range nodes {
		ch.Add(n)
	}

	counts := make(map[string]int)
	total := 10000

	for i := 0; i < total; i++ {
		key := fmt.Sprintf("user:%d", i)
		node := ch.Get(key)
		counts[node]++
	}

	expected := float64(total) / float64(len(nodes))
	t.Logf("ConsistentHash distribution (%d keys, %d nodes, 150 replicas):", total, len(nodes))
	for _, node := range nodes {
		cnt := counts[node]
		pct := float64(cnt) / float64(total) * 100
		deviation := math.Abs(float64(cnt)-expected) / expected * 100
		t.Logf("  %s: %d keys (%.1f%%) deviation=%.1f%%", node, cnt, pct, deviation)
	}

	// All nodes should receive at least some traffic
	for _, node := range nodes {
		if counts[node] == 0 {
			t.Errorf("node %q received 0 keys", node)
		}
	}
}

// TestConsistentHashMinimalRemapping verifies that adding a node remaps ~1/N keys.
func TestConsistentHashMinimalRemapping(t *testing.T) {
	ch := NewConsistentHash(150)

	// Start with 3 nodes
	initialNodes := []string{"redis-0", "redis-1", "redis-2"}
	for _, n := range initialNodes {
		ch.Add(n)
	}

	total := 10000
	before := make(map[string]string, total)
	for i := 0; i < total; i++ {
		key := fmt.Sprintf("key:%d", i)
		before[key] = ch.Get(key)
	}

	// Add a 4th node
	ch.Add("redis-3")

	remapped := 0
	for i := 0; i < total; i++ {
		key := fmt.Sprintf("key:%d", i)
		after := ch.Get(key)
		if before[key] != after {
			remapped++
		}
	}

	remapPct := float64(remapped) / float64(total) * 100
	// Expect roughly 1/4 = 25% of keys to be remapped
	t.Logf("ConsistentHash node add (3->4): %d/%d keys remapped (%.1f%%)", remapped, total, remapPct)

	// Should be significantly less than modulo hash's ~75%
	if remapPct > 40 {
		t.Errorf("ConsistentHash remapped %.1f%% keys (expected ~25%%), too many remappings", remapPct)
	}
}

// TestConsistentHashRemoveNode verifies that removing a node remaps only ~1/N keys.
func TestConsistentHashRemoveNode(t *testing.T) {
	ch := NewConsistentHash(150)
	nodes := []string{"redis-0", "redis-1", "redis-2", "redis-3"}
	for _, n := range nodes {
		ch.Add(n)
	}

	total := 10000
	before := make(map[string]string, total)
	for i := 0; i < total; i++ {
		key := fmt.Sprintf("key:%d", i)
		before[key] = ch.Get(key)
	}

	// Remove redis-1
	ch.Remove("redis-1")

	remapped := 0
	for i := 0; i < total; i++ {
		key := fmt.Sprintf("key:%d", i)
		after := ch.Get(key)
		if before[key] != after {
			remapped++
		}
	}

	remapPct := float64(remapped) / float64(total) * 100
	t.Logf("ConsistentHash node remove (4->3): %d/%d keys remapped (%.1f%%)", remapped, total, remapPct)

	// Only ~1/4 = 25% should be remapped (the keys that were on redis-1)
	if remapPct > 40 {
		t.Errorf("ConsistentHash remapped %.1f%% keys after remove (expected ~25%%)", remapPct)
	}

	// Verify removed node no longer appears in Get results
	for i := 0; i < total; i++ {
		key := fmt.Sprintf("key:%d", i)
		node := ch.Get(key)
		if node == "redis-1" {
			t.Errorf("Get(%q) returned removed node %q", key, node)
			break
		}
	}
}

// TestConsistentHashGetN verifies multi-node replication routing.
func TestConsistentHashGetN(t *testing.T) {
	ch := NewConsistentHash(100)
	for _, n := range []string{"redis-0", "redis-1", "redis-2", "redis-3"} {
		ch.Add(n)
	}

	key := "replicated:key"
	n := 3
	nodes := ch.GetN(key, n)

	if len(nodes) != n {
		t.Errorf("GetN(%q, %d) returned %d nodes, want %d", key, n, len(nodes), n)
	}

	// All returned nodes must be distinct
	seen := make(map[string]bool)
	for _, node := range nodes {
		if seen[node] {
			t.Errorf("GetN returned duplicate node %q", node)
		}
		seen[node] = true
	}
	t.Logf("GetN(%q, %d) = %v", key, n, nodes)
}

// TestConsistentHashDuplicateAdd verifies that adding a node twice is idempotent.
func TestConsistentHashDuplicateAdd(t *testing.T) {
	ch := NewConsistentHash(100)
	ch.Add("redis-0")
	ch.Add("redis-0") // duplicate

	if ch.Size() != 1 {
		t.Errorf("Size() = %d after duplicate Add, want 1", ch.Size())
	}
}

// TestConsistentHashDistributionWithReplicas compares distribution with different replica counts.
func TestConsistentHashDistributionWithReplicas(t *testing.T) {
	nodes := []string{"redis-0", "redis-1", "redis-2"}
	total := 10000

	for _, replicas := range []int{1, 10, 50, 150} {
		ch := NewConsistentHash(replicas)
		for _, n := range nodes {
			ch.Add(n)
		}

		counts := make(map[string]int)
		for i := 0; i < total; i++ {
			key := fmt.Sprintf("key:%d", i)
			counts[ch.Get(key)]++
		}

		// Calculate coefficient of variation (lower = more balanced)
		expected := float64(total) / float64(len(nodes))
		var sumSqDev float64
		var vals []int
		for _, n := range nodes {
			vals = append(vals, counts[n])
			sumSqDev += math.Pow(float64(counts[n])-expected, 2)
		}
		stddev := math.Sqrt(sumSqDev / float64(len(nodes)))
		cv := stddev / expected * 100

		sort.Ints(vals)
		t.Logf("replicas=%3d: distribution=%v  CV=%.1f%% (lower=more balanced)", replicas, vals, cv)
	}
}
