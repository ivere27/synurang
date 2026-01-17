package service

import (
	"testing"
	"time"
)

func TestWaitForReady_Timeout(t *testing.T) {
	// Set a short timeout for testing
	SetDefaultStreamTimeout(100 * time.Millisecond)
	defer SetDefaultStreamTimeout(0) // Reset after test

	session := NewStreamSession("test.Method", StreamTypeServerStream)
	defer CloseStreamSession(session.ID)

	start := time.Now()
	result := session.WaitForReady()
	elapsed := time.Since(start)

	if result {
		t.Error("WaitForReady should have returned false on timeout")
	}

	// Should have timed out around 100ms (allow some tolerance)
	if elapsed < 80*time.Millisecond || elapsed > 200*time.Millisecond {
		t.Errorf("Timeout duration unexpected: got %v, want ~100ms", elapsed)
	}
}

func TestWaitForReady_Success(t *testing.T) {
	// Set a reasonable timeout
	SetDefaultStreamTimeout(5 * time.Second)
	defer SetDefaultStreamTimeout(0) // Reset after test

	session := NewStreamSession("test.Method", StreamTypeServerStream)
	defer CloseStreamSession(session.ID)

	// Signal ready from another goroutine
	go func() {
		time.Sleep(50 * time.Millisecond)
		SignalStreamReady(session.ID)
	}()

	start := time.Now()
	result := session.WaitForReady()
	elapsed := time.Since(start)

	if !result {
		t.Error("WaitForReady should have returned true when signaled")
	}

	// Should have returned quickly after signal (not waited for full timeout)
	if elapsed > 500*time.Millisecond {
		t.Errorf("WaitForReady took too long: %v", elapsed)
	}
}

func TestWaitForReady_NoTimeout(t *testing.T) {
	// Set timeout to 0 (wait forever)
	SetDefaultStreamTimeout(0)

	session := NewStreamSession("test.Method", StreamTypeServerStream)
	defer CloseStreamSession(session.ID)

	// Signal ready from another goroutine
	go func() {
		time.Sleep(50 * time.Millisecond)
		SignalStreamReady(session.ID)
	}()

	start := time.Now()
	result := session.WaitForReady()
	elapsed := time.Since(start)

	if !result {
		t.Error("WaitForReady should have returned true when signaled")
	}

	// Should have returned after signal, not instantly
	if elapsed < 40*time.Millisecond {
		t.Errorf("WaitForReady returned too quickly: %v", elapsed)
	}
}

func TestWaitForReady_DoneChan(t *testing.T) {
	SetDefaultStreamTimeout(5 * time.Second)
	defer SetDefaultStreamTimeout(0)

	session := NewStreamSession("test.Method", StreamTypeServerStream)

	// Close the session from another goroutine
	go func() {
		time.Sleep(50 * time.Millisecond)
		CloseStreamSession(session.ID)
	}()

	start := time.Now()
	result := session.WaitForReady()
	elapsed := time.Since(start)

	if result {
		t.Error("WaitForReady should have returned false when session closed")
	}

	// Should have returned quickly after close
	if elapsed > 500*time.Millisecond {
		t.Errorf("WaitForReady took too long after close: %v", elapsed)
	}
}
