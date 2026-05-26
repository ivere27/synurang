//go:build debug

package main

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// debugHangMethod is a test-only RPC path. The Dart test suite invokes this
// to provoke a real call that exceeds the per-call timeout, so we can verify
// the recovery cascade end-to-end without resorting to internal test seams.
//
// Wire format:
//   - data: ASCII decimal digits representing milliseconds to sleep
//   - response on success: empty bytes (status byte handling lives in the
//     callers; tryDebugHang itself just returns the payload).
const debugHangMethod = "/core.v1.DebugService/HangFor"

// tryDebugHang intercepts debug-only RPC paths. Returns handled=false for
// any normal method so the caller falls through to the production dispatch.
func tryDebugHang(method string, data []byte) (handled bool, response []byte, err error) {
	if method != debugHangMethod {
		return false, nil, nil
	}

	raw := strings.TrimSpace(string(data))
	if raw == "" {
		return true, nil, fmt.Errorf("debug hang: empty duration")
	}
	ms, parseErr := strconv.ParseInt(raw, 10, 64)
	if parseErr != nil {
		return true, nil, fmt.Errorf("debug hang: invalid duration %q: %w", raw, parseErr)
	}
	if ms < 0 {
		return true, nil, fmt.Errorf("debug hang: negative duration %d", ms)
	}

	time.Sleep(time.Duration(ms) * time.Millisecond)
	return true, []byte{}, nil
}
