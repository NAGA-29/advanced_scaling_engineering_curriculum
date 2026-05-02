// Package main implements a DB shard resolver for tenant-based sharding.
// The resolver abstracts the sharding strategy from application code,
// allowing the sharding algorithm to be changed without modifying business logic.
package main

import (
	"database/sql"
	"fmt"
	"sync"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

// ─── Interface ────────────────────────────────────────────────────────────────

// DBResolver resolves which database shard to use for a given tenant.
// Application code should depend on this interface, not on concrete implementations.
type DBResolver interface {
	// ResolveByTenantID returns the *sql.DB for the given tenant.
	// The tenant is always routed to the same shard for data consistency.
	ResolveByTenantID(tenantID int64) (*sql.DB, error)

	// AllShards returns all shard connections, in shard index order.
	// Used for operations that must touch every shard (e.g., cross-shard queries).
	AllShards() []*sql.DB
}

// ─── TenantIDResolver ─────────────────────────────────────────────────────────

// TenantIDResolver distributes tenants across shards using modulo arithmetic:
//
//	shardIndex = tenantID % len(shards)
//
// This is simple and deterministic but requires careful consideration when
// changing the number of shards (all data must be re-distributed).
type TenantIDResolver struct {
	shards []*sql.DB
	mu     sync.RWMutex
}

// NewTenantIDResolver creates a TenantIDResolver from a list of DSNs.
// Each DSN corresponds to one shard.
//
// Example DSNs:
//
//	["root:pass@tcp(127.0.0.1:3307)/appdb?parseTime=true",
//	 "root:pass@tcp(127.0.0.1:3308)/appdb?parseTime=true"]
func NewTenantIDResolver(dsns []string) (*TenantIDResolver, error) {
	if len(dsns) == 0 {
		return nil, fmt.Errorf("NewTenantIDResolver: at least one DSN required")
	}

	shards := make([]*sql.DB, 0, len(dsns))
	for i, dsn := range dsns {
		db, err := sql.Open("mysql", dsn)
		if err != nil {
			return nil, fmt.Errorf("shard %d: sql.Open(%q): %w", i, dsn, err)
		}

		// Connection pool configuration
		db.SetMaxOpenConns(25)
		db.SetMaxIdleConns(5)
		db.SetConnMaxLifetime(5 * time.Minute)
		db.SetConnMaxIdleTime(2 * time.Minute)

		// Verify connectivity
		if err := db.Ping(); err != nil {
			db.Close()
			return nil, fmt.Errorf("shard %d: ping failed: %w", i, err)
		}

		shards = append(shards, db)
	}

	return &TenantIDResolver{shards: shards}, nil
}

// ResolveByTenantID returns the shard DB for the given tenant ID.
// Shard assignment: shards[tenantID % len(shards)]
func (r *TenantIDResolver) ResolveByTenantID(tenantID int64) (*sql.DB, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	if len(r.shards) == 0 {
		return nil, fmt.Errorf("ResolveByTenantID: no shards configured")
	}
	if tenantID < 0 {
		return nil, fmt.Errorf("ResolveByTenantID: tenantID must be >= 0, got %d", tenantID)
	}

	idx := tenantID % int64(len(r.shards))
	return r.shards[idx], nil
}

// ShardIndexFor returns the shard index for a tenant ID (useful for debugging).
func (r *TenantIDResolver) ShardIndexFor(tenantID int64) int {
	return int(tenantID % int64(len(r.shards)))
}

// AllShards returns all shard connections, in shard index order.
func (r *TenantIDResolver) AllShards() []*sql.DB {
	r.mu.RLock()
	defer r.mu.RUnlock()

	result := make([]*sql.DB, len(r.shards))
	copy(result, r.shards)
	return result
}

// ShardCount returns the number of shards.
func (r *TenantIDResolver) ShardCount() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.shards)
}

// Close closes all shard connections.
func (r *TenantIDResolver) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()

	var errs []error
	for i, shard := range r.shards {
		if err := shard.Close(); err != nil {
			errs = append(errs, fmt.Errorf("shard %d close: %w", i, err))
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("TenantIDResolver.Close: %v", errs)
	}
	return nil
}

// ─── RangeResolver ────────────────────────────────────────────────────────────

// ShardRange maps a range of tenant IDs to a specific shard.
type ShardRange struct {
	MinTenantID int64 // inclusive
	MaxTenantID int64 // inclusive (-1 means no upper bound)
	ShardIndex  int
}

// RangeResolver resolves shards using range-based assignment.
// Useful when tenant IDs are not uniformly distributed, or when
// large tenants need dedicated shards.
//
// Example:
//
//	ranges = [
//	  {Min: 1,    Max: 1000,  ShardIndex: 0},  // small tenants
//	  {Min: 1001, Max: 5000,  ShardIndex: 1},  // medium tenants
//	  {Min: 5001, Max: -1,    ShardIndex: 2},  // large tenants
//	]
type RangeResolver struct {
	shards []*sql.DB
	ranges []ShardRange
	mu     sync.RWMutex
}

// NewRangeResolver creates a RangeResolver.
func NewRangeResolver(shards []*sql.DB, ranges []ShardRange) (*RangeResolver, error) {
	if len(shards) == 0 {
		return nil, fmt.Errorf("NewRangeResolver: at least one shard required")
	}
	if len(ranges) == 0 {
		return nil, fmt.Errorf("NewRangeResolver: at least one range required")
	}
	for _, r := range ranges {
		if r.ShardIndex < 0 || r.ShardIndex >= len(shards) {
			return nil, fmt.Errorf("NewRangeResolver: range %+v references invalid shard index %d", r, r.ShardIndex)
		}
	}
	return &RangeResolver{shards: shards, ranges: ranges}, nil
}

// ResolveByTenantID finds the shard for the given tenant based on configured ranges.
func (r *RangeResolver) ResolveByTenantID(tenantID int64) (*sql.DB, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	for _, rng := range r.ranges {
		if tenantID >= rng.MinTenantID {
			if rng.MaxTenantID < 0 || tenantID <= rng.MaxTenantID {
				return r.shards[rng.ShardIndex], nil
			}
		}
	}
	return nil, fmt.Errorf("RangeResolver: no range found for tenantID %d", tenantID)
}

// AllShards returns all shard connections.
func (r *RangeResolver) AllShards() []*sql.DB {
	r.mu.RLock()
	defer r.mu.RUnlock()

	result := make([]*sql.DB, len(r.shards))
	copy(result, r.shards)
	return result
}

// ─── DirectoryResolver ────────────────────────────────────────────────────────

// DirectoryResolver uses a lookup table (tenant_id -> shard_index) for routing.
// This allows arbitrary assignment and easy migration of individual tenants.
// The directory is typically stored in a fast DB or cache.
type DirectoryResolver struct {
	shards    []*sql.DB
	directory map[int64]int // tenantID -> shardIndex
	mu        sync.RWMutex
}

// NewDirectoryResolver creates a DirectoryResolver.
func NewDirectoryResolver(shards []*sql.DB, directory map[int64]int) (*DirectoryResolver, error) {
	if len(shards) == 0 {
		return nil, fmt.Errorf("NewDirectoryResolver: at least one shard required")
	}
	return &DirectoryResolver{shards: shards, directory: directory}, nil
}

// ResolveByTenantID looks up the shard for the tenant in the directory.
func (r *DirectoryResolver) ResolveByTenantID(tenantID int64) (*sql.DB, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	shardIdx, ok := r.directory[tenantID]
	if !ok {
		return nil, fmt.Errorf("DirectoryResolver: tenantID %d not found in directory", tenantID)
	}
	if shardIdx < 0 || shardIdx >= len(r.shards) {
		return nil, fmt.Errorf("DirectoryResolver: invalid shard index %d for tenantID %d", shardIdx, tenantID)
	}
	return r.shards[shardIdx], nil
}

// AssignTenant assigns a tenant to a specific shard in the directory.
func (r *DirectoryResolver) AssignTenant(tenantID int64, shardIndex int) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if shardIndex < 0 || shardIndex >= len(r.shards) {
		return fmt.Errorf("DirectoryResolver.AssignTenant: invalid shard index %d", shardIndex)
	}
	r.directory[tenantID] = shardIndex
	return nil
}

// AllShards returns all shard connections.
func (r *DirectoryResolver) AllShards() []*sql.DB {
	r.mu.RLock()
	defer r.mu.RUnlock()

	result := make([]*sql.DB, len(r.shards))
	copy(result, r.shards)
	return result
}
