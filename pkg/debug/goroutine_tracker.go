//go:build !release

package debug

import (
	"fmt"
	"log"
	"runtime"
	"sort"
	"strings"
	"sync"
)

// GoroutineTracker tracks goroutine creation/destruction and prints diffs.
// Only compiled in debug builds (!release).
type GoroutineTracker struct {
	prevGoroutines map[string]int
	prevStacks     map[string]string // Stores the full stack trace for a key
	mu             sync.Mutex
	callCount      int
	// FullDumpInterval controls how often a full dump is printed (every N calls)
	FullDumpInterval int
	// Tag is prepended to log messages for identification
	Tag string
	// PrintFullStack controls whether to print the full stack trace for changed goroutines
	PrintFullStack bool
}

// NewGoroutineTracker creates a new GoroutineTracker
func NewGoroutineTracker() *GoroutineTracker {
	return &GoroutineTracker{
		prevGoroutines:   make(map[string]int),
		prevStacks:       make(map[string]string),
		FullDumpInterval: 10,
		Tag:              "GR-DIFF",
	}
}

// DefaultTracker is a shared singleton instance
var DefaultTracker = NewGoroutineTracker()

// PrintDiff captures current goroutines and prints diff from previous call.
func (t *GoroutineTracker) PrintDiff() {
	t.mu.Lock()
	t.callCount++
	shouldPrintAll := t.FullDumpInterval > 0 && t.callCount%t.FullDumpInterval == 0
	t.mu.Unlock()

	// Get all goroutine stacks
	buf := make([]byte, 1<<20) // 1MB buffer
	n := runtime.Stack(buf, true)
	stacks := string(buf[:n])

	// Parse goroutine stacks - extract a short identifier for each
	current := make(map[string]int)
	currentStacks := make(map[string]string)

	for _, block := range strings.Split(stacks, "\n\n") {
		if block == "" {
			continue
		}
		// Extract first line (goroutine id and state) and first frame
		lines := strings.Split(block, "\n")
		if len(lines) < 3 {
			continue
		}

		// Line 0: "goroutine N [state]:"
		firstLine := lines[0]
		state := "unknown"
		if start := strings.Index(firstLine, "["); start >= 0 {
			if end := strings.Index(firstLine[start:], "]"); end >= 0 {
				state = firstLine[start+1 : start+end]
			}
		}

		// Find the most relevant function frame
		var funcName, fileLine string

		// Look for "created by" at the end
		var createdBy string
		for i := len(lines) - 1; i >= 0; i-- {
			if strings.HasPrefix(lines[i], "created by ") {
				createdBy = strings.TrimPrefix(lines[i], "created by ")
				if idx := strings.Index(createdBy, " "); idx > 0 {
					createdBy = createdBy[:idx]
				}
				if idx := strings.LastIndex(createdBy, "/"); idx >= 0 {
					createdBy = createdBy[idx+1:]
				}
				break
			}
		}

		// Scan frames (starting from line 1, jumping by 2: func line, file line)
		foundFrame := false
		for i := 1; i < len(lines)-1; i += 2 {
			if strings.HasPrefix(lines[i], "created by ") {
				break
			}

			fName := strings.TrimSpace(lines[i])
			if idx := strings.Index(fName, "("); idx > 0 {
				fName = fName[:idx]
			}

			// Skip runtime.goexit if possible
			if strings.Contains(fName, "runtime.goexit") && i+2 < len(lines) {
				continue
			}

			funcName = fName
			if idx := strings.LastIndex(funcName, "/"); idx >= 0 {
				funcName = funcName[idx+1:]
			}

			// Get file line
			fLine := strings.TrimSpace(lines[i+1])
			if idx := strings.LastIndex(fLine, " +"); idx > 0 {
				fLine = fLine[:idx]
			}
			if idx := strings.LastIndex(fLine, "/"); idx >= 0 {
				fLine = fLine[idx+1:]
			}
			fileLine = fLine
			foundFrame = true
			break
		}

		if !foundFrame {
			funcName = strings.TrimSpace(lines[1])
			if idx := strings.Index(funcName, "("); idx > 0 {
				funcName = funcName[:idx]
			}
			if idx := strings.LastIndex(funcName, "/"); idx >= 0 {
				funcName = funcName[idx+1:]
			}
			fileLine = "?"
			if len(lines) > 2 {
				fileLine = strings.TrimSpace(lines[2])
				if idx := strings.LastIndex(fileLine, " +"); idx > 0 {
					fileLine = fileLine[:idx]
				}
				if idx := strings.LastIndex(fileLine, "/"); idx >= 0 {
					fileLine = fileLine[idx+1:]
				}
			}
		}

		// Create key: function (file:line)@state [created by ...]
		key := fmt.Sprintf("%s (%s)@%s", funcName, fileLine, state)
		if createdBy != "" {
			key += fmt.Sprintf(" [created by %s]", createdBy)
		}
		current[key]++
		// Just overwrite with the latest stack for this key.
		// If there are multiple identical keys (same func/state), any stack is representative.
		currentStacks[key] = block
	}

	t.mu.Lock()
	defer t.mu.Unlock()

	if len(t.prevGoroutines) == 0 {
		// First call, just record
		t.prevGoroutines = current
		t.prevStacks = currentStacks
		log.Printf("[%s] Initial: %d goroutines", t.Tag, len(current))
		return
	}

	// Find diffs
	var added, removed []string
	addedStacks := make(map[string]string)
	removedStacks := make(map[string]string)

	for key, count := range current {
		prevCount := t.prevGoroutines[key]
		if count > prevCount {
			diffStr := t.formatDiff(key, count-prevCount)
			added = append(added, diffStr)
			// Keep stack for printing
			addedStacks[diffStr] = currentStacks[key]
		}
	}

	for key, prevCount := range t.prevGoroutines {
		count := current[key]
		if prevCount > count {
			diffStr := t.formatDiff(key, prevCount-count)
			removed = append(removed, diffStr)
			// Keep stack for printing
			removedStacks[diffStr] = t.prevStacks[key]
		}
	}

	t.prevGoroutines = current
	t.prevStacks = currentStacks

	if len(added) > 0 || len(removed) > 0 {
		sort.Strings(added)
		sort.Strings(removed)

		for _, s := range added {
			log.Printf("[%s] + %s", t.Tag, s)
			// Print full stack for added goroutine
			if t.PrintFullStack {
				if stack, ok := addedStacks[s]; ok {
					log.Println(strings.TrimSpace(stack))
				}
			}
		}
		for _, s := range removed {
			log.Printf("[%s] - %s", t.Tag, s)
			// Print full stack for removed goroutine
			if t.PrintFullStack {
				if stack, ok := removedStacks[s]; ok {
					log.Println(strings.TrimSpace(stack))
				}
			}
		}
		log.Printf("[%s] Total: %d", t.Tag, runtime.NumGoroutine())
	}

	if shouldPrintAll {
		var all []string
		for key, count := range current {
			all = append(all, fmt.Sprintf("%s×%d", key, count))
		}
		sort.Strings(all)
		log.Printf("=== [%s-ALL] Full Dump (%d types) ===", t.Tag, len(all))
		for _, s := range all {
			log.Printf("[%s-ALL] %s", t.Tag, s)
		}
	}
}

func (t *GoroutineTracker) formatDiff(key string, count int) string {
	if count > 1 {
		return fmt.Sprintf("%s×%d", key, count)
	}
	return key
}

// Reset clears the previous goroutine state
func (t *GoroutineTracker) Reset() {
	t.mu.Lock()
	t.prevGoroutines = make(map[string]int)
	t.prevStacks = make(map[string]string)
	t.callCount = 0
	t.mu.Unlock()
}

// GetCount returns the current goroutine count
func (t *GoroutineTracker) GetCount() int {
	return runtime.NumGoroutine()
}
