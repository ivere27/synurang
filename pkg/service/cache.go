package service

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	pb "github.com/ivere27/synurang/pkg/api"

	_ "github.com/mattn/go-sqlite3"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

// SQLite constants
const (
	SQLiteCacheSize = -20000 // 20MB
	SQLiteMmapSize  = 30000  // 30MB
)

// accessUpdate represents a deferred LRU timestamp update.
type accessUpdate struct {
	storeName  string
	key        string
	accessedAt int64
}

// CacheServiceServer implements a high-performance SQLite-backed cache.
//
// Architecture:
//   - Single database (cache.db) for all stores: bookmarks, history, metadata, etc.
//   - NOTE: Thumbnails are now handled by Flutter's ThumbnailFileCache (file-based)
//
// Design principles:
//   - Store-name partitioned: All logical stores share one DB with store_name column
//   - Batched LRU updates: Amortizes write cost across many Get() calls
//   - Graceful shutdown: All goroutines properly terminated via WaitGroup
type CacheServiceServer struct {
	pb.UnimplementedCacheServiceServer
	db *sql.DB // cache.db - for text/metadata

	// maxEntries tracks per-store capacity limits
	maxEntries sync.Map // map[string]int64
	maxBytes   sync.Map // map[string]int64

	// Batched access updates
	accessChan chan accessUpdate

	// Graceful shutdown
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup

	// Shutdown state
	closed atomic.Bool

	// Lifecycle pause state (skips cleanup when app is backgrounded)
	paused atomic.Bool
	// pauseMu protects pauseTimer for delayed pause logic
	pauseMu    sync.Mutex
	pauseTimer *time.Timer

	// maintenanceMu protects against concurrent maintenance operations (cleanup vs compact)
	maintenanceMu sync.Mutex

	// Prepared statements to reduce SQLite overhead
	stmts struct {
		get          *sql.Stmt
		put          *sql.Stmt
		del          *sql.Stmt
		clear        *sql.Stmt
		contains     *sql.Stmt
		cleanup      *sql.Stmt
		updateAccess *sql.Stmt
		count        *sql.Stmt
		evictCount   *sql.Stmt
		sumSize      *sql.Stmt
		oldestRows   *sql.Stmt
		stats        *sql.Stmt
	}
}

// prepareStatements compiles all SQL queries once at startup.
func (s *CacheServiceServer) prepareStatements() error {
	var err error

	if s.stmts.get, err = s.db.Prepare("SELECT value, expires_at, accessed_at FROM cache_entries WHERE store_name = ? AND key = ?"); err != nil {
		return err
	}
	if s.stmts.put, err = s.db.Prepare(`
		INSERT INTO cache_entries (store_name, key, value, expires_at, accessed_at, size) 
		VALUES (?, ?, ?, ?, ?, ?) 
		ON CONFLICT(store_name, key) DO UPDATE SET 
			value=excluded.value, 
			expires_at=excluded.expires_at,
			accessed_at=excluded.accessed_at,
			size=excluded.size
	`); err != nil {
		return err
	}
	if s.stmts.del, err = s.db.Prepare("DELETE FROM cache_entries WHERE store_name = ? AND key = ?"); err != nil {
		return err
	}
	if s.stmts.clear, err = s.db.Prepare("DELETE FROM cache_entries WHERE store_name = ?"); err != nil {
		return err
	}
	if s.stmts.contains, err = s.db.Prepare("SELECT EXISTS(SELECT 1 FROM cache_entries WHERE store_name = ? AND key = ? AND (expires_at = 0 OR expires_at > ?))"); err != nil {
		return err
	}
	if s.stmts.cleanup, err = s.db.Prepare("DELETE FROM cache_entries WHERE expires_at > 0 AND expires_at < ?"); err != nil {
		return err
	}
	if s.stmts.updateAccess, err = s.db.Prepare("UPDATE cache_entries SET accessed_at = ? WHERE store_name = ? AND key = ?"); err != nil {
		return err
	}
	if s.stmts.count, err = s.db.Prepare("SELECT COUNT(*) FROM cache_entries WHERE store_name = ?"); err != nil {
		return err
	}
	if s.stmts.evictCount, err = s.db.Prepare(`
		DELETE FROM cache_entries 
		WHERE store_name = ? AND rowid IN (
			SELECT rowid FROM cache_entries 
			WHERE store_name = ? 
			ORDER BY accessed_at ASC 
			LIMIT ?
		)
	`); err != nil {
		return err
	}
	if s.stmts.sumSize, err = s.db.Prepare("SELECT COALESCE(SUM(size), 0) FROM cache_entries WHERE store_name = ?"); err != nil {
		return err
	}
	if s.stmts.oldestRows, err = s.db.Prepare(`
		SELECT rowid, size FROM cache_entries 
		WHERE store_name = ? 
		ORDER BY accessed_at ASC 
		LIMIT 50
	`); err != nil {
		return err
	}
	if s.stmts.stats, err = s.db.Prepare("SELECT COUNT(*), COALESCE(SUM(size), 0) FROM cache_entries WHERE store_name = ?"); err != nil {
		return err
	}

	return nil
}

// closeStatements closes all prepared statements.
func (s *CacheServiceServer) closeStatements() {
	if s.stmts.get != nil {
		s.stmts.get.Close()
	}
	if s.stmts.put != nil {
		s.stmts.put.Close()
	}
	if s.stmts.del != nil {
		s.stmts.del.Close()
	}
	if s.stmts.clear != nil {
		s.stmts.clear.Close()
	}
	if s.stmts.contains != nil {
		s.stmts.contains.Close()
	}
	if s.stmts.cleanup != nil {
		s.stmts.cleanup.Close()
	}
	if s.stmts.updateAccess != nil {
		s.stmts.updateAccess.Close()
	}
	if s.stmts.count != nil {
		s.stmts.count.Close()
	}
	if s.stmts.evictCount != nil {
		s.stmts.evictCount.Close()
	}
	if s.stmts.sumSize != nil {
		s.stmts.sumSize.Close()
	}
	if s.stmts.oldestRows != nil {
		s.stmts.oldestRows.Close()
	}
	if s.stmts.stats != nil {
		s.stmts.stats.Close()
	}
}

// openDB creates the cache database with store_name partitioning.
func openDB(dbPath string) (*sql.DB, error) {
	connStr := dbPath + "?_busy_timeout=5000&_journal_mode=WAL&_synchronous=NORMAL"
	db, err := sql.Open("sqlite3", connStr)
	if err != nil {
		return nil, fmt.Errorf("failed to open database %s: %w", dbPath, err)
	}

	db.SetMaxOpenConns(2)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(0)
	db.SetConnMaxIdleTime(0)

	// Note: Auto-vacuum is set to INCREMENTAL to allow space reclamation without full VACUUM.
	// This requires VACUUM to be run once if changing from default (NONE).
	pragmas := []string{
		fmt.Sprintf("PRAGMA cache_size=%d", SQLiteCacheSize),
		"PRAGMA temp_store=MEMORY",
		fmt.Sprintf("PRAGMA mmap_size=%d", SQLiteMmapSize),
		"PRAGMA auto_vacuum=2", // INCREMENTAL
	}
	for _, pragma := range pragmas {
		_, _ = db.Exec(pragma)
	}

	schema := `
	CREATE TABLE IF NOT EXISTS cache_entries (
		store_name TEXT NOT NULL,
		key TEXT NOT NULL,
		value BLOB,
		expires_at INTEGER DEFAULT 0,
		accessed_at INTEGER DEFAULT 0,
		size INTEGER DEFAULT 0,
		PRIMARY KEY (store_name, key)
	);
	CREATE INDEX IF NOT EXISTS idx_expires ON cache_entries(expires_at) WHERE expires_at > 0;
	CREATE INDEX IF NOT EXISTS idx_accessed ON cache_entries(store_name, accessed_at);
	`
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("failed to create schema in %s: %w", dbPath, err)
	}

	return db, nil
}

// NewCacheService creates a new cache service with single-database architecture.
func NewCacheService(storagePath string) (*CacheServiceServer, error) {
	db, err := openDB(filepath.Join(storagePath, "cache.db"))
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithCancel(context.Background())

	s := &CacheServiceServer{
		db:         db,
		accessChan: make(chan accessUpdate, 4096),
		ctx:        ctx,
		cancel:     cancel,
	}

	if err := s.prepareStatements(); err != nil {
		db.Close()
		return nil, fmt.Errorf("failed to prepare statements: %w", err)
	}

	// Start background workers
	s.wg.Add(2)
	go s.cleanupLoop()
	go s.accessUpdateLoop()

	return s, nil
}

// cleanupLoop periodically removes expired entries and enforces capacity.
func (s *CacheServiceServer) cleanupLoop() {
	defer s.wg.Done()

	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()

	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			// Skip cleanup when app is paused (backgrounded)
			if s.paused.Load() {
				continue
			}
			s.maintenanceMu.Lock()
			s.cleanupExpired()
			s.evictOverCapacity()
			// Reclaim free pages from deletion
			_, _ = s.db.Exec("PRAGMA incremental_vacuum;")
			s.maintenanceMu.Unlock()
		}
	}
}

// accessUpdateLoop batches LRU timestamp updates for efficiency.
func (s *CacheServiceServer) accessUpdateLoop() {
	defer s.wg.Done()

	// Use a timer for lazy flushing.
	// We create a timer but stop it immediately so it's ready to be Reset.
	timer := time.NewTimer(2000 * time.Millisecond)
	if !timer.Stop() {
		select {
		case <-timer.C:
		default:
		}
	}
	var timerCh <-chan time.Time

	pending := make(map[string]accessUpdate, 128)

	for {
		select {
		case <-s.ctx.Done():
			// Final flush before shutdown
			s.flushAccessUpdates(pending)
			return

		case update := <-s.accessChan:
			// Use composite key (store|key) for deduplication
			compositeKey := update.storeName + "|" + update.key
			pending[compositeKey] = update

			// Start timer if not running
			if timerCh == nil {
				timer.Reset(2000 * time.Millisecond)
				timerCh = timer.C
			}

			// Flush if we've accumulated many updates
			if len(pending) >= 250 {
				if !timer.Stop() {
					select {
					case <-timer.C:
					default:
					}
				}
				s.flushAccessUpdates(pending)
				pending = make(map[string]accessUpdate, 128)
				timerCh = nil // Timer stopped
			}

		case <-timerCh:
			// Timer fired
			if len(pending) > 0 {
				s.flushAccessUpdates(pending)
				pending = make(map[string]accessUpdate, 128)
			}
			timerCh = nil
		}
	}
}

// flushAccessUpdates writes batched LRU updates to the database.
func (s *CacheServiceServer) flushAccessUpdates(pending map[string]accessUpdate) {
	if len(pending) == 0 {
		return
	}

	// Note: We deliberately avoid a transaction (db.Begin/Commit) here because
	// wrapping the prepared statement (tx.Stmt) often causes the driver to
	// re-prepare and finalize the statement, causing unnecessary CPU/log churn.
	// Since we are in WAL mode with synchronous=NORMAL, individual Execs are fast enough.
	for _, update := range pending {
		_, _ = s.stmts.updateAccess.Exec(update.accessedAt, update.storeName, update.key)
	}
}

// cleanupExpired removes all entries past their TTL.
func (s *CacheServiceServer) cleanupExpired() {
	now := time.Now().Unix()
	_, _ = s.stmts.cleanup.Exec(now)
}

// evictOverCapacity removes least-recently-used entries when stores exceed their limits.
func (s *CacheServiceServer) evictOverCapacity() {
	// 1. Enforce Max Entries
	s.maxEntries.Range(func(key, value any) bool {
		storeName := key.(string)
		maxEntries := value.(int64)

		if maxEntries <= 0 {
			return true
		}

		var count int64
		err := s.stmts.count.QueryRow(storeName).Scan(&count)
		if err != nil || count <= maxEntries {
			return true
		}
		toRemove := count - maxEntries
		_, _ = s.stmts.evictCount.Exec(storeName, storeName, toRemove)

		return true
	})

	// 2. Enforce Max Bytes
	s.maxBytes.Range(func(key, value any) bool {
		storeName := key.(string)
		maxBytes := value.(int64)

		if maxBytes <= 0 {
			return true
		}

		var totalSize int64
		err := s.stmts.sumSize.QueryRow(storeName).Scan(&totalSize)
		if err != nil || totalSize <= maxBytes {
			return true
		}

		// Delete oldest items until under limit
		// We do this in a loop to avoid complex SQL for "running sum"
		// A more efficient way is to delete batch of oldest items
		for totalSize > maxBytes {
			// Find oldest item(s)
			rows, err := s.stmts.oldestRows.Query(storeName)
			if err != nil {
				return true
			}

			var ids []any
			idsArg := ""
			var batchSize int64

			for rows.Next() {
				var id int64
				var size int64
				if err := rows.Scan(&id, &size); err == nil {
					ids = append(ids, id)
					if idsArg != "" {
						idsArg += ","
					}
					idsArg += "?"
					batchSize += size
				}
			}
			rows.Close()

			if len(ids) == 0 {
				break
			}

			// Delete them (Dynamic SQL still needed for IN clause with variable args)
			query := fmt.Sprintf("DELETE FROM cache_entries WHERE rowid IN (%s)", idsArg)
			if _, err := s.db.Exec(query, ids...); err != nil {
				break
			}
			totalSize -= batchSize
		}

		return true
	})
}

// Get retrieves a cached value. Returns empty response if not found or expired.
func (s *CacheServiceServer) Get(ctx context.Context, req *pb.GetCacheRequest) (*pb.GetCacheResponse, error) {
	if s.closed.Load() {
		return &pb.GetCacheResponse{}, nil
	}

	var value []byte
	var expiresAt int64
	var accessedAt int64

	err := s.stmts.get.QueryRowContext(ctx, req.StoreName, req.Key).Scan(&value, &expiresAt, &accessedAt)

	if err == sql.ErrNoRows {
		return &pb.GetCacheResponse{}, nil
	}
	if err != nil {
		return nil, err
	}

	// Check expiration
	if expiresAt > 0 && expiresAt < time.Now().Unix() {
		return &pb.GetCacheResponse{}, nil
	}

	// Lazy access update (throttle to once per minute)
	now := time.Now().UnixNano()
	if now-accessedAt > int64(time.Minute) {
		select {
		case s.accessChan <- accessUpdate{
			storeName:  req.StoreName,
			key:        req.Key,
			accessedAt: now,
		}:
		default:
			// Channel full - skip this LRU update
		}
	}

	return &pb.GetCacheResponse{Value: value}, nil
}

// Put stores a value with optional TTL (0 = infinite).
func (s *CacheServiceServer) Put(ctx context.Context, req *pb.PutCacheRequest) (*emptypb.Empty, error) {
	if s.closed.Load() {
		return &emptypb.Empty{}, nil
	}

	var expiresAt int64
	if req.TtlSeconds > 0 {
		expiresAt = time.Now().Unix() + req.TtlSeconds
	}

	now := time.Now().UnixNano()
	size := int64(len(req.Value))
	if req.Cost > 0 {
		size = req.Cost
	}

	_, err := s.stmts.put.ExecContext(ctx, req.StoreName, req.Key, req.Value, expiresAt, now, size)

	return &emptypb.Empty{}, err
}

// Delete removes a specific cache entry.
func (s *CacheServiceServer) Delete(ctx context.Context, req *pb.DeleteCacheRequest) (*emptypb.Empty, error) {
	if s.closed.Load() {
		return &emptypb.Empty{}, nil
	}

	_, err := s.stmts.del.ExecContext(ctx, req.StoreName, req.Key)
	return &emptypb.Empty{}, err
}

// Clear removes all entries from a specific store.
func (s *CacheServiceServer) Clear(ctx context.Context, req *pb.ClearCacheRequest) (*emptypb.Empty, error) {
	if s.closed.Load() {
		return &emptypb.Empty{}, nil
	}

	_, err := s.stmts.clear.ExecContext(ctx, req.StoreName)
	return &emptypb.Empty{}, err
}

// Contains checks if a non-expired entry exists.
func (s *CacheServiceServer) Contains(ctx context.Context, req *pb.GetCacheRequest) (*wrapperspb.BoolValue, error) {
	if s.closed.Load() {
		return &wrapperspb.BoolValue{Value: false}, nil
	}

	var exists bool
	now := time.Now().Unix()

	err := s.stmts.contains.QueryRowContext(ctx, req.StoreName, req.Key, now).Scan(&exists)

	if err != nil {
		return nil, err
	}
	return &wrapperspb.BoolValue{Value: exists}, nil
}

// Keys returns all non-expired keys in a store.
func (s *CacheServiceServer) Keys(ctx context.Context, req *pb.GetCacheRequest) (*pb.GetCacheKeysResponse, error) {
	if s.closed.Load() {
		return &pb.GetCacheKeysResponse{}, nil
	}

	now := time.Now().Unix()
	rows, err := s.db.QueryContext(ctx,
		"SELECT key FROM cache_entries WHERE store_name = ? AND (expires_at = 0 OR expires_at > ?)",
		req.StoreName, now,
	)

	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var keys []string
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			return nil, err
		}
		keys = append(keys, key)
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	return &pb.GetCacheKeysResponse{Keys: keys}, nil
}

// SetMaxEntries configures the maximum number of entries for a store.
func (s *CacheServiceServer) SetMaxEntries(ctx context.Context, req *pb.SetMaxEntriesRequest) (*emptypb.Empty, error) {
	s.maxEntries.Store(req.StoreName, req.MaxEntries)
	return &emptypb.Empty{}, nil
}

// SetMaxBytes configures the maximum total size in bytes for a store.
func (s *CacheServiceServer) SetMaxBytes(ctx context.Context, req *pb.SetMaxBytesRequest) (*emptypb.Empty, error) {
	s.maxBytes.Store(req.StoreName, req.MaxBytes)
	return &emptypb.Empty{}, nil
}

// GetStats returns cache statistics for monitoring.
func (s *CacheServiceServer) GetStats(ctx context.Context, req *pb.GetStatsRequest) (*pb.GetStatsResponse, error) {
	count, sizeBytes, err := s.getStatsHelper(req.StoreName)
	if err != nil {
		return nil, err
	}
	return &pb.GetStatsResponse{
		Count:     count,
		SizeBytes: sizeBytes,
	}, nil
}

// getStatsHelper queries the database for stats.
func (s *CacheServiceServer) getStatsHelper(storeName string) (count int64, sizeBytes int64, err error) {
	if s.closed.Load() {
		return 0, 0, nil
	}

	err = s.stmts.stats.QueryRow(storeName).Scan(&count, &sizeBytes)
	return
}

// Compact triggers a manual VACUUM on both databases to reclaim disk space.
// This is a potentially slow blocking operation.
func (s *CacheServiceServer) Compact(ctx context.Context, _ *emptypb.Empty) (*emptypb.Empty, error) {
	s.maintenanceMu.Lock()
	defer s.maintenanceMu.Unlock()

	log.Println("CacheService: Starting manual database compaction...")

	// 1. Compact cache.db
	// Ensure auto_vacuum is enabled first
	if _, err := s.db.Exec("PRAGMA auto_vacuum = 2;"); err != nil {
		return nil, fmt.Errorf("failed to set auto_vacuum on cache.db: %w", err)
	}
	// Run VACUUM (this performs the compaction)
	if _, err := s.db.Exec("VACUUM;"); err != nil {
		return nil, fmt.Errorf("failed to vacuum cache.db: %w", err)
	}

	// 2. Compact synura.db (removed in core version as it is app specific)

	log.Println("CacheService: Manual compaction completed successfully.")
	return &emptypb.Empty{}, nil
}

// Close gracefully shuts down the cache service.
func (s *CacheServiceServer) Close() {
	if s.closed.Swap(true) {
		return // Already closed
	}

	// Cancel any pending pause timer
	s.pauseMu.Lock()
	if s.pauseTimer != nil {
		s.pauseTimer.Stop()
		s.pauseTimer = nil
	}
	s.pauseMu.Unlock()

	// Signal background workers to stop
	s.cancel()
	log.Println("CacheService: signaled workers to stop")

	// Wait for goroutines to finish synchronously (blocking, but okay in FFI mode)
	// Use a done channel with select to implement timeout without spawning extra goroutine
	done := make(chan struct{})
	go func() {
		s.wg.Wait()
		close(done)
	}()

	timer := time.NewTimer(5 * time.Second)
	select {
	case <-done:
		timer.Stop() // Stop timer to prevent goroutine leak
		log.Println("CacheService: workers stopped cleanly")
	case <-timer.C:
		log.Println("warning: cache service shutdown timed out, proceeding anyway")
	}

	// Close statements
	s.closeStatements()

	// Close database
	log.Println("CacheService: closing database")
	s.db.Close()
	log.Println("CacheService: shutdown complete")
}

// Pause schedules a delayed pause of background cleanup loops.
// The pause takes effect after 3 seconds, allowing Resume to cancel it
// if the app is foregrounded quickly (e.g., notification shade pull).
func (s *CacheServiceServer) Pause() {
	s.pauseMu.Lock()
	defer s.pauseMu.Unlock()

	// If already paused or timer already pending, nothing to do
	if s.paused.Load() || s.pauseTimer != nil {
		return
	}

	// Schedule delayed pause
	s.pauseTimer = time.AfterFunc(3*time.Second, func() {
		s.pauseMu.Lock()
		s.pauseTimer = nil
		s.pauseMu.Unlock()

		if s.paused.Swap(true) {
			return // Already paused by another path
		}
		log.Println("CacheService: paused (app backgrounded)")
	})
	log.Println("CacheService: pause scheduled in 3s")
}

// Resume resumes background cleanup loops (for when app is foregrounded).
// Also cancels any pending delayed pause.
func (s *CacheServiceServer) Resume() {
	s.pauseMu.Lock()
	// Cancel pending pause timer if any
	if s.pauseTimer != nil {
		s.pauseTimer.Stop()
		s.pauseTimer = nil
		log.Println("CacheService: pause cancelled (resumed quickly)")
	}
	s.pauseMu.Unlock()

	if !s.paused.Swap(false) {
		return // Already resumed
	}
	log.Println("CacheService: resumed (app foregrounded)")
}
