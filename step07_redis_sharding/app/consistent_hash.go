// consistent_hash.go implements a consistent hashing ring for Redis shard selection.
//
// Consistent hashing minimizes cache key reassignment when nodes are added or removed.
// When a new node is added, only ~1/N of the total keys need to be moved,
// compared to ~(N-1)/N with simple modulo hashing.
//
// Algorithm:
//   1. Each node is placed on a hash ring at `replicas` virtual positions.
//   2. A key is assigned to the first node clockwise from the key's hash position.
//   3. When a node is added, only keys between the new node and its predecessor move.
package main

import (
	"fmt"
	"hash/crc32"
	"sort"
	"sync"
)

// ConsistentHash implements a consistent hashing ring.
// It is safe for concurrent use.
type ConsistentHash struct {
	mu       sync.RWMutex
	ring     map[uint32]string // hash -> node name
	sorted   []uint32          // sorted hash values for binary search
	replicas int               // number of virtual nodes per real node
	nodes    map[string]bool   // set of real node names
}

// NewConsistentHash creates a ConsistentHash ring.
// replicas controls how many virtual nodes each real node gets.
// Higher replicas = better distribution but more memory.
// Typical production values: 100–200.
func NewConsistentHash(replicas int) *ConsistentHash {
	if replicas <= 0 {
		replicas = 100
	}
	return &ConsistentHash{
		ring:     make(map[uint32]string),
		sorted:   []uint32{},
		replicas: replicas,
		nodes:    make(map[string]bool),
	}
}

// virtualKey generates the key for the i-th virtual node of nodeName.
func virtualKey(nodeName string, i int) string {
	return fmt.Sprintf("%s#vnode%d", nodeName, i)
}

// hashKey computes a uint32 hash for the given string using CRC32 IEEE.
func hashKey(s string) uint32 {
	return crc32.ChecksumIEEE([]byte(s))
}

// Add adds a node to the ring.
// If the node already exists, it is a no-op.
func (c *ConsistentHash) Add(node string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.nodes[node] {
		return // already present
	}

	for i := 0; i < c.replicas; i++ {
		vk := virtualKey(node, i)
		h := hashKey(vk)
		c.ring[h] = node
		c.sorted = append(c.sorted, h)
	}

	sort.Slice(c.sorted, func(i, j int) bool {
		return c.sorted[i] < c.sorted[j]
	})

	c.nodes[node] = true
}

// Remove removes a node from the ring.
// Keys previously assigned to this node will be reassigned to the next node.
func (c *ConsistentHash) Remove(node string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.nodes[node] {
		return // not present
	}

	// Remove all virtual nodes for this real node
	toRemove := make(map[uint32]bool, c.replicas)
	for i := 0; i < c.replicas; i++ {
		vk := virtualKey(node, i)
		h := hashKey(vk)
		toRemove[h] = true
		delete(c.ring, h)
	}

	// Rebuild sorted slice without removed hashes
	newSorted := c.sorted[:0]
	for _, h := range c.sorted {
		if !toRemove[h] {
			newSorted = append(newSorted, h)
		}
	}
	c.sorted = newSorted

	delete(c.nodes, node)
}

// Get returns the node responsible for the given key.
// Returns an empty string if the ring is empty.
func (c *ConsistentHash) Get(key string) string {
	c.mu.RLock()
	defer c.mu.RUnlock()

	if len(c.ring) == 0 {
		return ""
	}

	h := hashKey(key)

	// Binary search for the first virtual node with hash >= h
	idx := sort.Search(len(c.sorted), func(i int) bool {
		return c.sorted[i] >= h
	})

	// Wrap around to the first node if we're past the end
	if idx == len(c.sorted) {
		idx = 0
	}

	return c.ring[c.sorted[idx]]
}

// GetN returns up to n distinct nodes for the given key, in ring order.
// This is useful for replication (write to N nodes for redundancy).
func (c *ConsistentHash) GetN(key string, n int) []string {
	c.mu.RLock()
	defer c.mu.RUnlock()

	if len(c.ring) == 0 || n <= 0 {
		return nil
	}

	if n > len(c.nodes) {
		n = len(c.nodes)
	}

	h := hashKey(key)
	idx := sort.Search(len(c.sorted), func(i int) bool {
		return c.sorted[i] >= h
	})

	seen := make(map[string]bool, n)
	result := make([]string, 0, n)

	for i := 0; i < len(c.sorted) && len(result) < n; i++ {
		pos := (idx + i) % len(c.sorted)
		node := c.ring[c.sorted[pos]]
		if !seen[node] {
			seen[node] = true
			result = append(result, node)
		}
	}

	return result
}

// Nodes returns all real nodes currently in the ring.
func (c *ConsistentHash) Nodes() []string {
	c.mu.RLock()
	defer c.mu.RUnlock()

	nodes := make([]string, 0, len(c.nodes))
	for node := range c.nodes {
		nodes = append(nodes, node)
	}
	sort.Strings(nodes)
	return nodes
}

// Size returns the number of real nodes in the ring.
func (c *ConsistentHash) Size() int {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.nodes)
}

// Distribution returns how many virtual nodes each real node has in the ring.
// Useful for verifying balance.
func (c *ConsistentHash) Distribution() map[string]int {
	c.mu.RLock()
	defer c.mu.RUnlock()

	dist := make(map[string]int, len(c.nodes))
	for _, node := range c.ring {
		dist[node]++
	}
	return dist
}

// ─── ConsistentHashStore ──────────────────────────────────────────────────────

// ConsistentHashStore wraps ShardedRedisStore but uses ConsistentHash for routing
// instead of CRC32 modulo. This allows adding/removing shards with minimal
// cache key reassignment.
type ConsistentHashStore struct {
	ring   *ConsistentHash
	shards map[string]*SingleRedisStore // node name -> store
}

// NewConsistentHashStore creates a store using consistent hashing.
// addrs is a map of node name -> Redis address.
// Example: {"redis-0": "localhost:6379", "redis-1": "localhost:6380"}
func NewConsistentHashStore(addrs map[string]string, replicas int) (*ConsistentHashStore, error) {
	if len(addrs) == 0 {
		return nil, fmt.Errorf("NewConsistentHashStore: at least one address required")
	}

	ring := NewConsistentHash(replicas)
	shards := make(map[string]*SingleRedisStore, len(addrs))

	for name, addr := range addrs {
		store := NewSingleRedisStore(addr)
		shards[name] = store
		ring.Add(name)
	}

	return &ConsistentHashStore{
		ring:   ring,
		shards: shards,
	}, nil
}

// storeFor returns the SingleRedisStore for the given key.
func (c *ConsistentHashStore) storeFor(key string) (*SingleRedisStore, error) {
	node := c.ring.Get(key)
	if node == "" {
		return nil, fmt.Errorf("ConsistentHashStore: ring is empty")
	}
	store, ok := c.shards[node]
	if !ok {
		return nil, fmt.Errorf("ConsistentHashStore: no store for node %q", node)
	}
	return store, nil
}

// NodeFor returns the node name responsible for the given key.
func (c *ConsistentHashStore) NodeFor(key string) string {
	return c.ring.Get(key)
}

// Get retrieves a value using consistent hash routing.
func (c *ConsistentHashStore) Get(ctx context.Context, key string) (string, error) {
	store, err := c.storeFor(key)
	if err != nil {
		return "", err
	}
	return store.Get(ctx, key)
}

// Set stores a value using consistent hash routing.
func (c *ConsistentHashStore) Set(ctx context.Context, key string, value string, ttl time.Duration) error {
	store, err := c.storeFor(key)
	if err != nil {
		return err
	}
	return store.Set(ctx, key, value, ttl)
}

// Del removes a key using consistent hash routing.
func (c *ConsistentHashStore) Del(ctx context.Context, key string) error {
	store, err := c.storeFor(key)
	if err != nil {
		return err
	}
	return store.Del(ctx, key)
}
