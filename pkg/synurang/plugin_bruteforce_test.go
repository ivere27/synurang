package synurang_test

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	pb "github.com/ivere27/synurang/example/pkg/api"
	"github.com/ivere27/synurang/pkg/synurang"
)

type pluginBruteSpec struct {
	name string
	path string
}

type pluginBruteTarget struct {
	name   string
	plugin *synurang.Plugin
	client pb.GoGreeterServiceClient
}

func TestPluginRandomBruteforceAllLanguages(t *testing.T) {
	if os.Getenv("SYNURANG_BRUTE") != "1" {
		t.Skip("set SYNURANG_BRUTE=1 to run plugin brute-force tests")
	}

	perLangDuration := parseBruteDuration(t, "SYNURANG_BRUTE_DURATION", 1*time.Minute)
	if perLangDuration > 10*time.Minute {
		t.Fatalf("SYNURANG_BRUTE_DURATION must be <= 10m (got %s)", perLangDuration)
	}
	workers := parseBruteInt(t, "SYNURANG_BRUTE_WORKERS", 4)
	maxGoroutineDelta := parseBruteInt(t, "SYNURANG_BRUTE_MAX_G_DELTA", 64)
	maxFDDelta := parseBruteInt(t, "SYNURANG_BRUTE_MAX_FD_DELTA", 48)
	maxRSSMBDelta := parseBruteInt(t, "SYNURANG_BRUTE_MAX_RSS_MB_DELTA", 256)

	specs := pluginBruteSpecs()
	stabilizeRuntime()
	baseline := captureResourceSnapshot()

	var totalOps int64
	var totalExpectedErrs int64
	var totalUnexpectedErrs int64

	for i, spec := range specs {
		target := openPluginBruteTarget(t, spec)
		ops, expectedErrs, unexpectedErrs := runPluginBrutePhase(
			t,
			[]pluginBruteTarget{target},
			perLangDuration,
			workers,
			int64(i+1)*101,
			"single:"+spec.name,
		)
		closePluginBruteTarget(target)
		stabilizeRuntime()

		totalOps += ops
		totalExpectedErrs += expectedErrs
		totalUnexpectedErrs += int64(unexpectedErrs)
		if unexpectedErrs > 0 {
			t.Fatalf("plugin brute-force (single language %s) had %d unexpected errors", spec.name, unexpectedErrs)
		}
	}

	stabilizeRuntime()
	final := captureResourceSnapshot()
	assertNoResourceLeaks(t, baseline, final, maxGoroutineDelta, maxFDDelta, maxRSSMBDelta)

	if totalOps == 0 {
		t.Fatal("plugin brute-force all-languages completed with zero successful operations")
	}

	t.Logf(
		"plugin bruteforce all-languages done: per_lang_duration=%s ops=%d expected_errors=%d unexpected_errors=%d baseline(g=%d fd=%d rss_mb=%d) final(g=%d fd=%d rss_mb=%d)",
		perLangDuration,
		totalOps,
		totalExpectedErrs,
		totalUnexpectedErrs,
		baseline.goroutines,
		baseline.fdCount,
		int(baseline.rssBytes/(1024*1024)),
		final.goroutines,
		final.fdCount,
		int(final.rssBytes/(1024*1024)),
	)
}

func TestPluginRandomBruteforceMixed(t *testing.T) {
	if os.Getenv("SYNURANG_BRUTE") != "1" {
		t.Skip("set SYNURANG_BRUTE=1 to run plugin brute-force tests")
	}

	duration := parseBruteDuration(t, "SYNURANG_BRUTE_DURATION", 1*time.Minute)
	if duration > 10*time.Minute {
		t.Fatalf("SYNURANG_BRUTE_DURATION must be <= 10m (got %s)", duration)
	}
	workers := parseBruteInt(t, "SYNURANG_BRUTE_WORKERS", 4)
	maxGoroutineDelta := parseBruteInt(t, "SYNURANG_BRUTE_MAX_G_DELTA", 64)
	maxFDDelta := parseBruteInt(t, "SYNURANG_BRUTE_MAX_FD_DELTA", 48)
	maxRSSMBDelta := parseBruteInt(t, "SYNURANG_BRUTE_MAX_RSS_MB_DELTA", 256)

	specs := pluginBruteSpecs()
	targets := make([]pluginBruteTarget, 0, len(specs))
	for _, spec := range specs {
		targets = append(targets, openPluginBruteTarget(t, spec))
	}
	defer func() {
		for _, target := range targets {
			closePluginBruteTarget(target)
		}
	}()

	stabilizeRuntime()
	baseline := captureResourceSnapshot()
	ops, expectedErrs, unexpectedErrs := runPluginBrutePhase(t, targets, duration, workers, 9_999, "mixed")
	stabilizeRuntime()
	final := captureResourceSnapshot()
	assertNoResourceLeaks(t, baseline, final, maxGoroutineDelta, maxFDDelta, maxRSSMBDelta)

	if unexpectedErrs > 0 {
		t.Fatalf("plugin brute-force mixed had %d unexpected errors", unexpectedErrs)
	}
	if ops == 0 {
		t.Fatal("plugin brute-force mixed completed with zero successful operations")
	}

	t.Logf(
		"plugin bruteforce mixed done: duration=%s ops=%d expected_errors=%d unexpected_errors=%d baseline(g=%d fd=%d rss_mb=%d) final(g=%d fd=%d rss_mb=%d)",
		duration,
		ops,
		expectedErrs,
		unexpectedErrs,
		baseline.goroutines,
		baseline.fdCount,
		int(baseline.rssBytes/(1024*1024)),
		final.goroutines,
		final.fdCount,
		int(final.rssBytes/(1024*1024)),
	)
}

// TestPluginReloadUnderLoad tests closing and reopening a plugin while workers
// are actively using it. This is a separate test (not in the random mix) because
// reloading invalidates all workers' clients.
func TestPluginReloadUnderLoad(t *testing.T) {
	if os.Getenv("SYNURANG_BRUTE") != "1" {
		t.Skip("set SYNURANG_BRUTE=1 to run plugin reload-under-load test")
	}

	duration := parseBruteDuration(t, "SYNURANG_BRUTE_DURATION", 30*time.Second)
	if duration > 10*time.Minute {
		t.Fatalf("SYNURANG_BRUTE_DURATION must be <= 10m (got %s)", duration)
	}
	workers := parseBruteInt(t, "SYNURANG_BRUTE_WORKERS", 4)
	maxGoroutineDelta := parseBruteInt(t, "SYNURANG_BRUTE_MAX_G_DELTA", 64)
	maxFDDelta := parseBruteInt(t, "SYNURANG_BRUTE_MAX_FD_DELTA", 48)
	maxRSSMBDelta := parseBruteInt(t, "SYNURANG_BRUTE_MAX_RSS_MB_DELTA", 256)

	// Use Go plugin for reload test — it's the fastest to load/unload.
	spec := pluginBruteSpec{name: "Go", path: "bin/libplugin_go.so"}
	resolvedPath, err := resolvePluginPath(spec.path)
	if err != nil {
		t.Fatalf("failed to resolve plugin path: %v", err)
	}
	if _, err := os.Stat(resolvedPath); err != nil {
		t.Fatalf("plugin not found at %s (run `make build_plugin_all` first): %v", resolvedPath, err)
	}

	type reloadTarget struct {
		mu     sync.RWMutex
		plugin *synurang.Plugin
		client pb.GoGreeterServiceClient
	}

	plugin, err := synurang.LoadPlugin(resolvedPath)
	if err != nil {
		t.Fatalf("failed to load plugin: %v", err)
	}
	conn := synurang.NewPluginClientConn(plugin, "GoGreeterService")

	target := &reloadTarget{
		plugin: plugin,
		client: pb.NewGoGreeterServiceClient(conn),
	}

	stabilizeRuntime()
	baseline := captureResourceSnapshot()

	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()

	var ops int64
	var expectedErrs int64
	var unexpectedErrs int64
	var reloads int64

	var wg sync.WaitGroup

	// Worker goroutines: run normal ops holding RLock.
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			seed := time.Now().UnixNano() + int64(workerID)*100_103
			r := rand.New(rand.NewSource(seed))

			for ctx.Err() == nil {
				target.mu.RLock()
				client := target.client
				target.mu.RUnlock()

				opErr := runPluginRandomOperation(ctx, client, r, workerID, "Go-reload")
				if opErr == nil {
					atomic.AddInt64(&ops, 1)
					time.Sleep(time.Duration(1+r.Intn(4)) * time.Millisecond)
					continue
				}
				if isExpectedBruteError(opErr) || errors.Is(opErr, synurang.ErrPluginClosed) || errors.Is(opErr, synurang.ErrStreamClosed) {
					atomic.AddInt64(&expectedErrs, 1)
					time.Sleep(time.Duration(1+r.Intn(3)) * time.Millisecond)
					continue
				}
				atomic.AddInt64(&unexpectedErrs, 1)
				t.Logf("reload worker %d unexpected error: %v", workerID, opErr)
				return
			}
		}(w)
	}

	// Reloader goroutine: periodically close and reopen the plugin.
	var reloadFailures int64
	wg.Add(1)
	go func() {
		defer wg.Done()
		r := rand.New(rand.NewSource(time.Now().UnixNano() + 999_983))

		for ctx.Err() == nil {
			// Increase delay between reloads to allow cleanup to finish
			delay := time.Duration(1000+r.Intn(2000)) * time.Millisecond
			select {
			case <-ctx.Done():
				return
			case <-time.After(delay):
			}

			// Load new plugin BEFORE closing old one
			newPlugin, loadErr := synurang.LoadPlugin(resolvedPath)
			if loadErr != nil {
				atomic.AddInt64(&reloadFailures, 1)
				t.Logf("reload failed (%d so far): %v", atomic.LoadInt64(&reloadFailures), loadErr)
				continue
			}
			newConn := synurang.NewPluginClientConn(newPlugin, "GoGreeterService")

			target.mu.Lock()
			oldPlugin := target.plugin
			target.plugin = newPlugin
			target.client = pb.NewGoGreeterServiceClient(newConn)
			target.mu.Unlock()

			// Give workers a tiny bit of time to transition to the new client
			time.Sleep(10 * time.Millisecond)

			// Close old plugin after swapping
			_ = oldPlugin.Close()

			atomic.AddInt64(&reloads, 1)
		}
	}()

	wg.Wait()

	// Final cleanup — close whatever plugin is current.
	target.mu.Lock()
	if target.plugin != nil {
		_ = target.plugin.Close()
	}
	target.mu.Unlock()

	stabilizeRuntime()
	final := captureResourceSnapshot()
	assertNoResourceLeaks(t, baseline, final, maxGoroutineDelta, maxFDDelta, maxRSSMBDelta)

	if atomic.LoadInt64(&unexpectedErrs) > 0 {
		t.Fatalf("plugin reload-under-load had %d unexpected errors", atomic.LoadInt64(&unexpectedErrs))
	}
	if atomic.LoadInt64(&reloads) == 0 {
		t.Fatalf("plugin reload-under-load completed with zero successful reloads (failures=%d)", atomic.LoadInt64(&reloadFailures))
	}
	if atomic.LoadInt64(&ops) == 0 {
		t.Fatal("plugin reload-under-load completed with zero successful operations")
	}

	t.Logf(
		"plugin reload-under-load done: duration=%s ops=%d reloads=%d reload_failures=%d expected_errors=%d unexpected_errors=%d baseline(g=%d fd=%d rss_mb=%d) final(g=%d fd=%d rss_mb=%d)",
		duration,
		atomic.LoadInt64(&ops),
		atomic.LoadInt64(&reloads),
		atomic.LoadInt64(&reloadFailures),
		atomic.LoadInt64(&expectedErrs),
		atomic.LoadInt64(&unexpectedErrs),
		baseline.goroutines,
		baseline.fdCount,
		int(baseline.rssBytes/(1024*1024)),
		final.goroutines,
		final.fdCount,
		int(final.rssBytes/(1024*1024)),
	)
}

func pluginBruteSpecs() []pluginBruteSpec {
	return []pluginBruteSpec{
		{name: "Go", path: "bin/libplugin_go.so"},
		{name: "C++", path: "bin/libplugin_cpp.so"},
		{name: "Rust", path: "bin/libplugin_rust.so"},
	}
}

func openPluginBruteTarget(t *testing.T, spec pluginBruteSpec) pluginBruteTarget {
	t.Helper()

	resolvedPath, err := resolvePluginPath(spec.path)
	if err != nil {
		t.Fatalf("failed to resolve plugin path for %s (%s): %v", spec.name, spec.path, err)
	}
	if _, err := os.Stat(resolvedPath); err != nil {
		t.Fatalf("plugin %s not found at %s (run `make build_plugin_all` first): %v", spec.name, resolvedPath, err)
	}

	plugin, err := synurang.LoadPlugin(resolvedPath)
	if err != nil {
		t.Fatalf("failed to load %s plugin (%s): %v", spec.name, resolvedPath, err)
	}
	conn := synurang.NewPluginClientConn(plugin, "GoGreeterService")
	client := pb.NewGoGreeterServiceClient(conn)

	return pluginBruteTarget{
		name:   spec.name,
		plugin: plugin,
		client: client,
	}
}

func closePluginBruteTarget(target pluginBruteTarget) {
	if target.plugin != nil {
		_ = target.plugin.Close()
	}
}

func runPluginBrutePhase(
	t *testing.T,
	targets []pluginBruteTarget,
	duration time.Duration,
	workers int,
	seedBase int64,
	label string,
) (int64, int64, int) {
	t.Helper()

	if len(targets) == 0 {
		t.Fatalf("runPluginBrutePhase called with no targets")
	}

	phaseCtx, phaseCancel := context.WithTimeout(context.Background(), duration)
	defer phaseCancel()

	var ops int64
	var expectedErrs int64
	var unexpectedErrs int64

	var wg sync.WaitGroup
	errCh := make(chan error, workers*8)

	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			seed := time.Now().UnixNano() + int64(workerID)*100_103 + seedBase*9_973
			r := rand.New(rand.NewSource(seed))

			for phaseCtx.Err() == nil {
				target := targets[r.Intn(len(targets))]
				err := runPluginRandomOperation(phaseCtx, target.client, r, workerID, target.name)
				if err == nil {
					atomic.AddInt64(&ops, 1)
					time.Sleep(time.Duration(3+r.Intn(6)) * time.Millisecond)
					continue
				}
				if isExpectedBruteError(err) {
					atomic.AddInt64(&expectedErrs, 1)
					time.Sleep(time.Duration(2+r.Intn(4)) * time.Millisecond)
					continue
				}
				atomic.AddInt64(&unexpectedErrs, 1)
				select {
				case errCh <- fmt.Errorf("%s worker %d target=%s: %w", label, workerID, target.name, err):
				default:
				}
				return
			}
		}(w)
	}

	wg.Wait()
	close(errCh)

	for err := range errCh {
		t.Logf("unexpected plugin brute-force error: %v", err)
	}

	return atomic.LoadInt64(&ops), atomic.LoadInt64(&expectedErrs), int(atomic.LoadInt64(&unexpectedErrs))
}

func runPluginRandomOperation(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
	pluginName string,
) error {
	switch x := r.Intn(100); {
	case x < 40:
		return runPluginRandomUnary(parent, client, r, workerID, pluginName)
	case x < 62:
		return runPluginRandomServerStream(parent, client, r, workerID, pluginName)
	case x < 78:
		return runPluginRandomClientStream(parent, client, r, workerID, pluginName)
	case x < 88:
		return runPluginRandomBidiStream(parent, client, r, workerID, pluginName)
	default:
		return runPluginChaosOperation(parent, client, r, workerID, pluginName)
	}
}

func runPluginRandomUnary(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
	pluginName string,
) error {
	ctx, cancel := context.WithTimeout(parent, pluginTimeout(r))
	defer cancel()

	name := fmt.Sprintf("u-%s-%d-%d", pluginName, workerID, r.Int63())
	resp, err := client.Bar(ctx, &pb.HelloRequest{Name: name})
	if err != nil {
		return err
	}
	if resp.Message == "" {
		return fmt.Errorf("unary empty response message for %s", pluginName)
	}
	if !strings.Contains(resp.Message, name) {
		return fmt.Errorf("unary response does not include request marker: msg=%q marker=%q", resp.Message, name)
	}
	return nil
}

func runPluginRandomServerStream(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
	pluginName string,
) error {
	ctx, cancel := context.WithTimeout(parent, pluginTimeout(r))
	defer cancel()

	name := fmt.Sprintf("ss-%s-%d-%d", pluginName, workerID, r.Int63())
	stream, err := client.BarServerStream(ctx, &pb.HelloRequest{Name: name})
	if err != nil {
		return err
	}

	targetReads := 1 + r.Intn(5)
	received := 0

	for i := 0; i < targetReads; i++ {
		_, recvErr := stream.Recv()
		if recvErr == io.EOF {
			break
		}
		if recvErr != nil {
			return recvErr
		}
		received++
	}

	if received == 0 {
		return fmt.Errorf("server-stream returned zero messages for %s", pluginName)
	}

	if r.Intn(100) < 40 {
		for {
			_, recvErr := stream.Recv()
			if recvErr == io.EOF {
				break
			}
			if recvErr != nil {
				return recvErr
			}
			received++
		}
	}

	return nil
}

func runPluginRandomClientStream(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
	pluginName string,
) error {
	ctx, cancel := context.WithTimeout(parent, pluginTimeout(r))
	defer cancel()

	stream, err := client.BarClientStream(ctx)
	if err != nil {
		return err
	}

	count := 1 + r.Intn(20)
	for i := 0; i < count; i++ {
		name := fmt.Sprintf("cs-%s-%d-%d-%d", pluginName, workerID, i, r.Int63())
		if sendErr := stream.Send(&pb.HelloRequest{Name: name}); sendErr != nil {
			return sendErr
		}
	}

	resp, err := stream.CloseAndRecv()
	if err != nil {
		return err
	}
	if resp.Message == "" {
		return fmt.Errorf("client-stream empty response for %s", pluginName)
	}
	return nil
}

func runPluginRandomBidiStream(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
	pluginName string,
) error {
	ctx, cancel := context.WithTimeout(parent, pluginTimeout(r))
	defer cancel()

	stream, err := client.BarBidiStream(ctx)
	if err != nil {
		return err
	}
	defer stream.CloseSend()

	count := 1 + r.Intn(12)
	received := 0
	for i := 0; i < count; i++ {
		name := fmt.Sprintf("bs-%s-%d-%d-%d", pluginName, workerID, i, r.Int63())
		if sendErr := stream.Send(&pb.HelloRequest{Name: name}); sendErr != nil {
			return sendErr
		}

		recv, recvErr := stream.Recv()
		if recvErr != nil {
			return recvErr
		}
		if recv.Message == "" {
			return fmt.Errorf("bidi empty response for %s", pluginName)
		}
		received++
	}

	if received == 0 {
		return fmt.Errorf("bidi received zero responses for %s", pluginName)
	}
	return nil
}

// runPluginChaosOperation dispatches one of 8 chaos sub-operations
// designed to stress edge-case abuse paths.
func runPluginChaosOperation(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
	pluginName string,
) error {
	switch x := r.Intn(100); {
	case x < 15:
		return pluginChaosOpenAndAbandon(parent, client, r, pluginName)
	case x < 30:
		return pluginChaosDoubleClose(parent, client, r, pluginName)
	case x < 43:
		return pluginChaosSendAfterCloseSend(parent, client, r, workerID, pluginName)
	case x < 56:
		return pluginChaosRecvAfterClose(parent, client, r, pluginName)
	case x < 70:
		return pluginChaosConcurrentSendRecv(parent, client, r, workerID, pluginName)
	case x < 82:
		return pluginChaosBoundaryPayloads(parent, client, r, workerID, pluginName)
	case x < 92:
		return pluginChaosMismatchedBidi(parent, client, r, workerID, pluginName)
	case x < 97:
		return pluginChaosSlowConsumer(parent, client, r, workerID, pluginName)
	default:
		return pluginChaosImmediateCancel(parent, client, r, pluginName)
	}
}

// pluginChaosOpenAndAbandon opens a stream, never sends/receives, and lets
// the context expire. Tests watchdog cleanup of abandoned native streams.
func pluginChaosOpenAndAbandon(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	pluginName string,
) error {
	ctx, cancel := context.WithTimeout(parent, time.Duration(20+r.Intn(80))*time.Millisecond)
	defer cancel()

	// Open a bidi stream and immediately abandon it.
	stream, err := client.BarBidiStream(ctx)
	if err != nil {
		return expectedOrNil(err)
	}
	_ = stream
	// Let context expire — watchdog should clean up the native stream.
	<-ctx.Done()
	return nil
}

// pluginChaosDoubleClose opens a stream, then concurrently calls CloseSend
// and cancels the context. Tests sync.Once / atomic.Swap idempotency.
func pluginChaosDoubleClose(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	pluginName string,
) error {
	ctx, cancel := context.WithTimeout(parent, pluginTimeout(r))

	stream, err := client.BarBidiStream(ctx)
	if err != nil {
		cancel()
		return expectedOrNil(err)
	}

	// Send at least one message so stream is active.
	_ = stream.Send(&pb.HelloRequest{Name: "chaos-double-close"})

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_ = stream.CloseSend()
	}()
	go func() {
		defer wg.Done()
		cancel()
	}()
	wg.Wait()

	// Extra CloseSend on already-closed stream should be safe.
	_ = stream.CloseSend()
	return nil
}

// pluginChaosSendAfterCloseSend sends on a stream after CloseSend.
// Must get a clean error, not a panic.
func pluginChaosSendAfterCloseSend(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
	pluginName string,
) error {
	ctx, cancel := context.WithTimeout(parent, pluginTimeout(r))
	defer cancel()

	stream, err := client.BarClientStream(ctx)
	if err != nil {
		return expectedOrNil(err)
	}

	// Send one valid message.
	name := fmt.Sprintf("chaos-sac-%s-%d-%d", pluginName, workerID, r.Int63())
	_ = stream.Send(&pb.HelloRequest{Name: name})

	// Close send side, then try to send again.
	_ = stream.CloseSend()

	sendErr := stream.Send(&pb.HelloRequest{Name: "after-close"})
	if sendErr == nil {
		// Some transports may buffer — not necessarily an error.
		return nil
	}
	return expectedOrNil(sendErr)
}

// pluginChaosRecvAfterClose cancels a stream, then attempts Recv.
// Must get EOF/error, not a panic.
func pluginChaosRecvAfterClose(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	pluginName string,
) error {
	ctx, cancel := context.WithTimeout(parent, pluginTimeout(r))

	stream, err := client.BarServerStream(ctx, &pb.HelloRequest{Name: "chaos-rac"})
	if err != nil {
		cancel()
		return expectedOrNil(err)
	}

	// Read one message, then cancel and try to recv again.
	_, _ = stream.Recv()
	cancel()

	_, recvErr := stream.Recv()
	if recvErr == nil {
		return nil
	}
	return expectedOrNil(recvErr)
}

// pluginChaosConcurrentSendRecv opens a bidi stream and has multiple goroutines
// hitting Send and Recv simultaneously. Tests sendMu/recvMu protection.
func pluginChaosConcurrentSendRecv(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
	pluginName string,
) error {
	ctx, cancel := context.WithTimeout(parent, pluginTimeout(r))
	defer cancel()

	stream, err := client.BarBidiStream(ctx)
	if err != nil {
		return expectedOrNil(err)
	}

	var wg sync.WaitGroup
	goroutines := 2 + r.Intn(3)

	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func(gID int) {
			defer wg.Done()
			for i := 0; i < 3; i++ {
				name := fmt.Sprintf("chaos-csr-%s-%d-%d-%d", pluginName, workerID, gID, i)
				if sendErr := stream.Send(&pb.HelloRequest{Name: name}); sendErr != nil {
					return
				}
				if _, recvErr := stream.Recv(); recvErr != nil {
					return
				}
			}
		}(g)
	}

	wg.Wait()
	_ = stream.CloseSend()
	return nil
}

// pluginChaosBoundaryPayloads sends boundary-case payloads through unary:
// empty string, single char, and large (64-256KB) strings.
func pluginChaosBoundaryPayloads(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
	pluginName string,
) error {
	ctx, cancel := context.WithTimeout(parent, time.Duration(500+r.Intn(1500))*time.Millisecond)
	defer cancel()

	var name string
	switch r.Intn(3) {
	case 0:
		name = ""
	case 1:
		name = "x"
	case 2:
		size := 64*1024 + r.Intn(192*1024)
		name = strings.Repeat("B", size)
	}

	resp, err := client.Bar(ctx, &pb.HelloRequest{Name: name})
	if err != nil {
		return expectedOrNil(err)
	}
	if resp == nil {
		return fmt.Errorf("boundary payload: nil response for %s", pluginName)
	}
	return nil
}

// pluginChaosMismatchedBidi sends N messages but only receives M < N,
// then abandons the stream. Tests partial-drain cleanup.
func pluginChaosMismatchedBidi(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
	pluginName string,
) error {
	ctx, cancel := context.WithTimeout(parent, pluginTimeout(r))
	defer cancel()

	stream, err := client.BarBidiStream(ctx)
	if err != nil {
		return expectedOrNil(err)
	}

	sendCount := 3 + r.Intn(8)
	for i := 0; i < sendCount; i++ {
		name := fmt.Sprintf("chaos-mm-%s-%d-%d", pluginName, workerID, i)
		if sendErr := stream.Send(&pb.HelloRequest{Name: name}); sendErr != nil {
			return expectedOrNil(sendErr)
		}
	}

	// Receive fewer than sent, then abandon.
	recvCount := 1 + r.Intn(sendCount-1)
	for i := 0; i < recvCount; i++ {
		if _, recvErr := stream.Recv(); recvErr != nil {
			return expectedOrNil(recvErr)
		}
	}

	// Abandon without draining — context cancel will clean up.
	return nil
}

// pluginChaosSlowConsumer tests host backpressure by delaying Recv
// from a plugin that is producing messages.
func pluginChaosSlowConsumer(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
	pluginName string,
) error {
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	defer cancel()

	stream, err := client.BarServerStream(ctx, &pb.HelloRequest{Name: "chaos-slow-consumer"})
	if err != nil {
		return expectedOrNil(err)
	}

	// Intentionally wait before starting to receive
	select {
	case <-ctx.Done():
		return nil
	case <-time.After(time.Duration(100+r.Intn(300)) * time.Millisecond):
	}

	for {
		_, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return expectedOrNil(err)
		}
	}
	return nil
}

// pluginChaosImmediateCancel cancels context *before* first Send/Recv.
// Tests the pre-canceled path.
func pluginChaosImmediateCancel(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	pluginName string,
) error {
	ctx, cancel := context.WithTimeout(parent, pluginTimeout(r))
	cancel() // Cancel immediately before any I/O.

	_, err := client.BarBidiStream(ctx)
	if err != nil {
		return expectedOrNil(err)
	}
	// If stream opened despite cancelled context, that's fine — watchdog will clean up.
	return nil
}

// expectedOrNil returns nil if the error is an expected brute-force error,
// otherwise returns the error unchanged (to be counted as unexpected).
func expectedOrNil(err error) error {
	if err == nil {
		return nil
	}
	if isExpectedBruteError(err) {
		return nil
	}
	// Also accept plugin/stream closed errors directly for chaos ops.
	if errors.Is(err, synurang.ErrStreamClosed) || errors.Is(err, synurang.ErrPluginClosed) {
		return nil
	}
	msg := strings.ToLower(err.Error())
	if strings.Contains(msg, "plugin is closed") || strings.Contains(msg, "stream is closed") {
		return nil
	}
	return err
}

func resolvePluginPath(rel string) (string, error) {
	if filepath.IsAbs(rel) {
		return rel, nil
	}

	wd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	dir := wd
	for {
		candidate := filepath.Join(dir, rel)
		if _, statErr := os.Stat(candidate); statErr == nil {
			return candidate, nil
		}
		if _, statErr := os.Stat(filepath.Join(dir, "go.mod")); statErr == nil {
			// Stop at repo root once discovered.
			return candidate, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return filepath.Join(wd, rel), nil
}

func pluginTimeout(r *rand.Rand) time.Duration {
	return time.Duration(200+r.Intn(600)) * time.Millisecond
}
