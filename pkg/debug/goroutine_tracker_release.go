//go:build release

package debug

// GoroutineTracker is a no-op in release builds
type GoroutineTracker struct{}

// NewGoroutineTracker creates a no-op tracker in release builds
func NewGoroutineTracker() *GoroutineTracker {
	return &GoroutineTracker{}
}

// DefaultTracker is a no-op in release builds
var DefaultTracker = NewGoroutineTracker()

// PrintDiff is a no-op in release builds
func (t *GoroutineTracker) PrintDiff() {}

// Reset is a no-op in release builds
func (t *GoroutineTracker) Reset() {}

// GetCount returns 0 in release builds
func (t *GoroutineTracker) GetCount() int { return 0 }
