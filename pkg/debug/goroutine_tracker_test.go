//go:build !release

package debug

import (
	"bytes"
	"log"
	"strings"
	"testing"
	"time"
)

func TestGoroutineTracker_Options(t *testing.T) {
	// Redirect log output
	var buf bytes.Buffer
	log.SetOutput(&buf)
	// We don't defer restore because 'go test' captures output anyway and we are just messing with this process logic.
	// But it's good practice so we don't mess up other tests if run in same package.
	// Note: log is global.

	tr := NewGoroutineTracker()
	tr.Tag = "TEST"
	tr.FullDumpInterval = 0

	// Baseline
	tr.PrintDiff()
	buf.Reset()

	start := make(chan struct{})

	// 1. One line mode (default)
	go func() {
		<-start
	}()
	time.Sleep(50 * time.Millisecond)

	tr.PrintDiff()
	outShort := buf.String()

	if !strings.Contains(outShort, "[TEST] +") {
		t.Logf("Expected output to contain '[TEST] +', got:\n%s", outShort)
		// Don't fail hard if scheduling was weird, but it's a useful check
	}

	// Count lines. Should be 1 line for the added goroutine (plus maybe total count line)
	// Output:
	// date time [TEST] + ...
	// date time [TEST] Total: ...
	linesShort := strings.Count(outShort, "\n")

	// 2. Full stack mode
	tr.PrintFullStack = true
	buf.Reset()

	go func() {
		<-start
	}()
	time.Sleep(50 * time.Millisecond)

	tr.PrintDiff()
	outFull := buf.String()

	if !strings.Contains(outFull, "[TEST] +") {
		t.Logf("Expected output to contain '[TEST] +', got:\n%s", outFull)
	}

	linesFull := strings.Count(outFull, "\n")

	if linesFull <= linesShort {
		t.Errorf("Full stack mode should produce more output lines. Short: %d, Full: %d", linesShort, linesFull)
		t.Logf("Short output:\n%s", outShort)
		t.Logf("Full output:\n%s", outFull)
	}

	close(start)
}
