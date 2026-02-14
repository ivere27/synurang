package synurang_test

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"os"
	"os/exec"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	pb "github.com/ivere27/synurang/example/pkg/api"
	"github.com/ivere27/synurang/pkg/synurang"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type bruteProcess struct {
	conn     *grpc.ClientConn
	cmd      *exec.Cmd
	waitCh   chan error
	mu       sync.Mutex
	waited   bool
	waitErr  error
	stopping bool
}

type resourceSnapshot struct {
	goroutines int
	rssBytes   uint64
	fdCount    int
	hasRSS     bool
	hasFD      bool
}

func TestProcessRandomBruteforce(t *testing.T) {
	if os.Getenv("SYNURANG_BRUTE") != "1" {
		t.Skip("set SYNURANG_BRUTE=1 to run the brute-force process stress test")
	}

	totalDuration := parseBruteDuration(t, "SYNURANG_BRUTE_DURATION", 2*time.Minute)
	if totalDuration > 10*time.Minute {
		t.Fatalf("SYNURANG_BRUTE_DURATION must be <= 10m (got %s)", totalDuration)
	}
	phaseDuration := parseBruteDuration(t, "SYNURANG_BRUTE_PHASE", 45*time.Second)
	workers := parseBruteInt(t, "SYNURANG_BRUTE_WORKERS", 32)
	maxGoroutineDelta := parseBruteInt(t, "SYNURANG_BRUTE_MAX_G_DELTA", 64)
	maxFDDelta := parseBruteInt(t, "SYNURANG_BRUTE_MAX_FD_DELTA", 48)
	maxRSSMBDelta := parseBruteInt(t, "SYNURANG_BRUTE_MAX_RSS_MB_DELTA", 256)

	start := time.Now()
	deadline := start.Add(totalDuration)

	stabilizeRuntime()
	baseline := captureResourceSnapshot()

	var totalOps int64
	var totalExpectedErrs int64
	var totalUnexpectedErrs int64
	round := 0

	for time.Now().Before(deadline) {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			break
		}
		round++
		currentPhase := phaseDuration
		if remaining < currentPhase {
			currentPhase = remaining
		}
		if currentPhase < time.Second {
			break
		}

		proc := startBruteProcess(t)
		ops, expectedErrs, unexpectedErrs := runBrutePhase(t, proc, currentPhase, workers, int64(round))
		stopBruteProcess(t, proc)
		stabilizeRuntime()

		totalOps += ops
		totalExpectedErrs += expectedErrs
		totalUnexpectedErrs += int64(unexpectedErrs)
		if unexpectedErrs > 0 {
			t.Fatalf("brute-force round %d had %d unexpected errors", round, unexpectedErrs)
		}
	}

	elapsed := time.Since(start)
	if totalOps == 0 {
		t.Fatal("brute-force test completed with zero successful operations")
	}

	stabilizeRuntime()
	final := captureResourceSnapshot()
	assertNoResourceLeaks(t, baseline, final, maxGoroutineDelta, maxFDDelta, maxRSSMBDelta)

	t.Logf(
		"bruteforce done: duration=%s rounds=%d ops=%d expected_errors=%d unexpected_errors=%d ops_per_sec=%.1f baseline(g=%d fd=%d rss_mb=%d) final(g=%d fd=%d rss_mb=%d)",
		elapsed.Truncate(time.Millisecond),
		round,
		totalOps,
		totalExpectedErrs,
		totalUnexpectedErrs,
		float64(totalOps)/elapsed.Seconds(),
		baseline.goroutines,
		baseline.fdCount,
		int(baseline.rssBytes/(1024*1024)),
		final.goroutines,
		final.fdCount,
		int(final.rssBytes/(1024*1024)),
	)
}

func startBruteProcess(t *testing.T) *bruteProcess {
	t.Helper()

	var cmd *exec.Cmd
	childBin := os.Getenv("SYNURANG_BRUTE_CHILD_BIN")
	if childBin != "" {
		cmd = exec.Command(childBin)
	} else {
		cmd = exec.Command(os.Args[0], "-test.run=TestHelperProcess", "--")
		cmd.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")
	}

	startCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	conn, err := synurang.StartProcess(startCtx, cmd, grpc.WithBlock())
	if err != nil {
		t.Fatalf("StartProcess failed in brute-force test: %v", err)
	}

	proc := &bruteProcess{
		conn:   conn,
		cmd:    cmd,
		waitCh: make(chan error, 1),
	}
	go func() {
		proc.waitCh <- cmd.Wait()
	}()
	return proc
}

func stopBruteProcess(t *testing.T, proc *bruteProcess) {
	t.Helper()
	if proc == nil {
		return
	}

	proc.mu.Lock()
	proc.stopping = true
	proc.mu.Unlock()

	if proc.conn != nil {
		_ = proc.conn.Close()
	}
	if proc.cmd != nil && proc.cmd.Process != nil {
		_ = proc.cmd.Process.Kill()
	}
	exited, waitErr := proc.pollExit(2 * time.Second)
	if !exited {
		t.Fatalf("child process did not exit within timeout during cleanup")
	}
	if waitErr != nil && !errors.Is(waitErr, os.ErrProcessDone) && !isExpectedKilledWaitErr(waitErr) {
		// Non-zero exit is expected after Kill in stress cleanup, so keep as log.
		t.Logf("child exit after cleanup: %v", waitErr)
	}
}

func (p *bruteProcess) pollExit(timeout time.Duration) (bool, error) {
	p.mu.Lock()
	if p.waited {
		err := p.waitErr
		p.mu.Unlock()
		return true, err
	}
	p.mu.Unlock()

	if timeout <= 0 {
		select {
		case err := <-p.waitCh:
			p.mu.Lock()
			p.waited = true
			p.waitErr = err
			p.mu.Unlock()
			return true, err
		default:
			return false, nil
		}
	}

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case err := <-p.waitCh:
		p.mu.Lock()
		p.waited = true
		p.waitErr = err
		p.mu.Unlock()
		return true, err
	case <-timer.C:
		return false, nil
	}
}

func runBrutePhase(t *testing.T, proc *bruteProcess, duration time.Duration, workers int, seedBase int64) (int64, int64, int) {
	t.Helper()

	client := pb.NewGoGreeterServiceClient(proc.conn)
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
			seed := time.Now().UnixNano() + int64(workerID)*100_003 + seedBase*7_919
			r := rand.New(rand.NewSource(seed))

			for phaseCtx.Err() == nil {
				if exited, waitErr := proc.pollExit(0); exited {
					proc.mu.Lock()
					stopping := proc.stopping
					proc.mu.Unlock()
					if !stopping {
						atomic.AddInt64(&unexpectedErrs, 1)
						select {
						case errCh <- fmt.Errorf("child process exited unexpectedly: %v", waitErr):
						default:
						}
						phaseCancel()
						return
					}
					return
				}

				err := runRandomOperation(phaseCtx, client, r, workerID)
				if err == nil {
					atomic.AddInt64(&ops, 1)
					continue
				}
				if isExpectedBruteError(err) {
					atomic.AddInt64(&expectedErrs, 1)
					continue
				}
				atomic.AddInt64(&unexpectedErrs, 1)
				select {
				case errCh <- fmt.Errorf("worker %d: %w", workerID, err):
				default:
				}
				return
			}
		}(w)
	}

	wg.Wait()
	close(errCh)

	for err := range errCh {
		t.Logf("unexpected brute-force error: %v", err)
	}

	return atomic.LoadInt64(&ops), atomic.LoadInt64(&expectedErrs), int(atomic.LoadInt64(&unexpectedErrs))
}

func runRandomOperation(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
) error {
	switch x := r.Intn(100); {
	case x < 35:
		return runRandomUnary(parent, client, r, workerID)
	case x < 57:
		return runRandomServerStream(parent, client, r, workerID)
	case x < 75:
		return runRandomClientStream(parent, client, r, workerID)
	case x < 88:
		return runRandomBidiStream(parent, client, r, workerID)
	default:
		return runProcessChaosOperation(parent, client, r, workerID)
	}
}

func runRandomUnary(parent context.Context, client pb.GoGreeterServiceClient, r *rand.Rand, workerID int) error {
	ctx, cancel := context.WithTimeout(parent, randomTimeout(r))
	defer cancel()

	name := fmt.Sprintf("u-%d-%d", workerID, r.Int63())
	resp, err := client.Bar(ctx, &pb.HelloRequest{Name: name})
	if err != nil {
		return err
	}

	if !strings.Contains(resp.Message, name) {
		return fmt.Errorf("unary message mismatch: expected marker %q in %q", name, resp.Message)
	}
	return nil
}

func runRandomServerStream(parent context.Context, client pb.GoGreeterServiceClient, r *rand.Rand, workerID int) error {
	ctx, cancel := context.WithTimeout(parent, randomTimeout(r))
	defer cancel()

	name := fmt.Sprintf("ss-%d-%d", workerID, r.Int63())
	stream, err := client.BarServerStream(ctx, &pb.HelloRequest{Name: name})
	if err != nil {
		return err
	}

	// Occasionally abort early to stress cancellation paths.
	maxRecv := 3
	if r.Intn(100) < 20 {
		maxRecv = 1 + r.Intn(2)
	}

	for i := 0; i < maxRecv; i++ {
		resp, recvErr := stream.Recv()
		if recvErr != nil {
			return recvErr
		}
		if !strings.Contains(resp.Message, name) {
			return fmt.Errorf("server-stream mismatch: expected marker %q in %q", name, resp.Message)
		}
	}

	if maxRecv < 3 {
		cancel()
		return nil
	}

	_, err = stream.Recv()
	if err != io.EOF {
		return fmt.Errorf("server-stream expected EOF, got %w", err)
	}
	return nil
}

func runRandomClientStream(parent context.Context, client pb.GoGreeterServiceClient, r *rand.Rand, workerID int) error {
	ctx, cancel := context.WithTimeout(parent, randomTimeout(r))
	defer cancel()

	stream, err := client.BarClientStream(ctx)
	if err != nil {
		return err
	}

	count := 1 + r.Intn(25)
	for i := 0; i < count; i++ {
		name := fmt.Sprintf("cs-%d-%d-%d", workerID, i, r.Int63())
		if sendErr := stream.Send(&pb.HelloRequest{Name: name}); sendErr != nil {
			return sendErr
		}
		if r.Intn(100) < 5 {
			time.Sleep(time.Duration(1+r.Intn(4)) * time.Millisecond)
		}
	}

	resp, err := stream.CloseAndRecv()
	if err != nil {
		return err
	}

	if !strings.Contains(resp.Message, strconv.Itoa(count)) {
		return fmt.Errorf("client-stream mismatch: expected count %d in %q", count, resp.Message)
	}
	return nil
}

func runRandomBidiStream(parent context.Context, client pb.GoGreeterServiceClient, r *rand.Rand, workerID int) error {
	ctx, cancel := context.WithTimeout(parent, randomTimeout(r))
	defer cancel()

	stream, err := client.BarBidiStream(ctx)
	if err != nil {
		return err
	}
	defer stream.CloseSend()

	count := 1 + r.Intn(20)
	for i := 0; i < count; i++ {
		name := fmt.Sprintf("bs-%d-%d-%d", workerID, i, r.Int63())
		if sendErr := stream.Send(&pb.HelloRequest{Name: name}); sendErr != nil {
			return sendErr
		}

		resp, recvErr := stream.Recv()
		if recvErr != nil {
			return recvErr
		}
		if !strings.Contains(resp.Message, name) {
			return fmt.Errorf("bidi mismatch: expected marker %q in %q", name, resp.Message)
		}

		if r.Intn(100) < 8 {
			cancel()
			return nil
		}
	}
	return nil
}

// runProcessChaosOperation dispatches one of 8 chaos sub-operations
// designed to stress edge-case abuse paths over gRPC process transport.
func runProcessChaosOperation(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
) error {
	switch x := r.Intn(100); {
	case x < 15:
		return processChaosOpenAndAbandon(parent, client, r)
	case x < 30:
		return processChaosDoubleClose(parent, client, r)
	case x < 43:
		return processChaosSendAfterCloseSend(parent, client, r, workerID)
	case x < 56:
		return processChaosRecvAfterClose(parent, client, r)
	case x < 70:
		return processChaosConcurrentSendRecv(parent, client, r, workerID)
	case x < 82:
		return processChaosBoundaryPayloads(parent, client, r, workerID)
	case x < 92:
		return processChaosMismatchedBidi(parent, client, r, workerID)
	case x < 97:
		return processChaosSlowConsumer(parent, client, r, workerID)
	default:
		return processChaosImmediateCancel(parent, client, r)
	}
}

// processChaosOpenAndAbandon opens a stream, never sends/receives, and lets
// the context expire. Tests cleanup of abandoned streams.
func processChaosOpenAndAbandon(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
) error {
	ctx, cancel := context.WithTimeout(parent, time.Duration(20+r.Intn(80))*time.Millisecond)
	defer cancel()

	stream, err := client.BarBidiStream(ctx)
	if err != nil {
		return processExpectedOrNil(err)
	}
	_ = stream
	<-ctx.Done()
	return nil
}

// processChaosDoubleClose opens a stream, then concurrently calls CloseSend
// and cancels the context.
func processChaosDoubleClose(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
) error {
	ctx, cancel := context.WithTimeout(parent, randomTimeout(r))

	stream, err := client.BarBidiStream(ctx)
	if err != nil {
		cancel()
		return processExpectedOrNil(err)
	}

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

	_ = stream.CloseSend()
	return nil
}

// processChaosSendAfterCloseSend sends on a stream after CloseSend.
func processChaosSendAfterCloseSend(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
) error {
	ctx, cancel := context.WithTimeout(parent, randomTimeout(r))
	defer cancel()

	stream, err := client.BarClientStream(ctx)
	if err != nil {
		return processExpectedOrNil(err)
	}

	name := fmt.Sprintf("chaos-sac-%d-%d", workerID, r.Int63())
	_ = stream.Send(&pb.HelloRequest{Name: name})
	_ = stream.CloseSend()

	sendErr := stream.Send(&pb.HelloRequest{Name: "after-close"})
	if sendErr == nil {
		return nil
	}
	return processExpectedOrNil(sendErr)
}

// processChaosRecvAfterClose cancels a stream, then attempts Recv.
func processChaosRecvAfterClose(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
) error {
	ctx, cancel := context.WithTimeout(parent, randomTimeout(r))

	stream, err := client.BarServerStream(ctx, &pb.HelloRequest{Name: "chaos-rac"})
	if err != nil {
		cancel()
		return processExpectedOrNil(err)
	}

	_, _ = stream.Recv()
	cancel()

	_, recvErr := stream.Recv()
	if recvErr == nil {
		return nil
	}
	return processExpectedOrNil(recvErr)
}

// processChaosConcurrentSendRecv opens a bidi stream with one sender goroutine
// and one receiver goroutine operating concurrently. gRPC allows Send and Recv
// to be concurrent, but not multiple concurrent Sends or multiple concurrent Recvs.
func processChaosConcurrentSendRecv(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
) error {
	ctx, cancel := context.WithTimeout(parent, randomTimeout(r))
	defer cancel()

	stream, err := client.BarBidiStream(ctx)
	if err != nil {
		return processExpectedOrNil(err)
	}

	count := 3 + r.Intn(5)

	// Sender goroutine.
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < count; i++ {
			name := fmt.Sprintf("chaos-csr-%d-%d", workerID, i)
			if sendErr := stream.Send(&pb.HelloRequest{Name: name}); sendErr != nil {
				return
			}
		}
		_ = stream.CloseSend()
	}()

	// Receiver in main goroutine.
	for i := 0; i < count; i++ {
		if _, recvErr := stream.Recv(); recvErr != nil {
			break
		}
	}

	wg.Wait()
	return nil
}

// processChaosBoundaryPayloads sends boundary-case payloads through unary:
// empty string, single char, and large (64-256KB) strings.
func processChaosBoundaryPayloads(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
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
		return processExpectedOrNil(err)
	}
	if resp == nil {
		return fmt.Errorf("boundary payload: nil response")
	}
	return nil
}

// processChaosMismatchedBidi sends N messages but only receives M < N,
// then abandons the stream.
func processChaosMismatchedBidi(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
) error {
	ctx, cancel := context.WithTimeout(parent, randomTimeout(r))
	defer cancel()

	stream, err := client.BarBidiStream(ctx)
	if err != nil {
		return processExpectedOrNil(err)
	}

	sendCount := 3 + r.Intn(8)
	for i := 0; i < sendCount; i++ {
		name := fmt.Sprintf("chaos-mm-%d-%d", workerID, i)
		if sendErr := stream.Send(&pb.HelloRequest{Name: name}); sendErr != nil {
			return processExpectedOrNil(sendErr)
		}
	}

	recvCount := 1 + r.Intn(sendCount-1)
	for i := 0; i < recvCount; i++ {
		if _, recvErr := stream.Recv(); recvErr != nil {
			return processExpectedOrNil(recvErr)
		}
	}

	return nil
}

// processChaosSlowConsumer sends many messages quickly from the child,
// while the parent intentionally delays consumption.
func processChaosSlowConsumer(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
	workerID int,
) error {
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	defer cancel()

	// BarServerStream in example logic sends 3 messages.
	// We'll use a larger one if available, but even 3 with delay tests the path.
	stream, err := client.BarServerStream(ctx, &pb.HelloRequest{Name: "chaos-slow-consumer"})
	if err != nil {
		return processExpectedOrNil(err)
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
			return processExpectedOrNil(err)
		}
		// Occasional mid-stream delay
		if r.Intn(100) < 20 {
			time.Sleep(10 * time.Millisecond)
		}
	}
	return nil
}

// processChaosImmediateCancel cancels context *before* first Send/Recv.
func processChaosImmediateCancel(
	parent context.Context,
	client pb.GoGreeterServiceClient,
	r *rand.Rand,
) error {
	ctx, cancel := context.WithTimeout(parent, randomTimeout(r))
	cancel()

	_, err := client.BarBidiStream(ctx)
	if err != nil {
		return processExpectedOrNil(err)
	}
	return nil
}

// processExpectedOrNil returns nil if the error is an expected brute-force error,
// otherwise returns the error unchanged.
func processExpectedOrNil(err error) error {
	if err == nil {
		return nil
	}
	if isExpectedBruteError(err) {
		return nil
	}
	return err
}

func randomTimeout(r *rand.Rand) time.Duration {
	n := r.Intn(100)
	switch {
	case n < 15:
		return time.Duration(2+r.Intn(4)) * time.Millisecond
	case n < 65:
		return time.Duration(20+r.Intn(80)) * time.Millisecond
	default:
		return time.Duration(100+r.Intn(350)) * time.Millisecond
	}
}

func isExpectedBruteError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) || errors.Is(err, io.EOF) {
		return true
	}
	if errors.Is(err, synurang.ErrStreamClosed) || errors.Is(err, synurang.ErrPluginClosed) {
		return true
	}

	switch status.Code(err) {
	case codes.Canceled, codes.DeadlineExceeded, codes.Unavailable, codes.Internal, codes.Unknown, codes.Aborted:
		return true
	}

	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "context deadline exceeded") ||
		strings.Contains(msg, "context canceled") ||
		strings.Contains(msg, "deadline exceeded") ||
		strings.Contains(msg, "canceled") ||
		strings.Contains(msg, "stream is closed") ||
		strings.Contains(msg, "plugin is closed") ||
		strings.Contains(msg, "transport is closing") ||
		strings.Contains(msg, "connection closing") ||
		strings.Contains(msg, "stream send failed") ||
		strings.Contains(msg, "empty stream response") ||
		strings.Contains(msg, "malformed header") ||
		strings.Contains(msg, "sendmsg called after closesend") ||
		strings.Contains(msg, "broken pipe") ||
		strings.Contains(msg, "connection refused") ||
		strings.Contains(msg, "protocol error") ||
		strings.Contains(msg, "http2 error") ||
		strings.Contains(msg, "connection reset")
}

func parseBruteDuration(t *testing.T, key string, fallback time.Duration) time.Duration {
	t.Helper()
	raw := os.Getenv(key)
	if raw == "" {
		return fallback
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		t.Fatalf("invalid %s=%q: %v", key, raw, err)
	}
	if d <= 0 {
		t.Fatalf("%s must be > 0 (got %s)", key, d)
	}
	return d
}

func parseBruteInt(t *testing.T, key string, fallback int) int {
	t.Helper()
	raw := os.Getenv(key)
	if raw == "" {
		return fallback
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		t.Fatalf("invalid %s=%q: %v", key, raw, err)
	}
	if v <= 0 {
		t.Fatalf("%s must be > 0 (got %d)", key, v)
	}
	return v
}

func stabilizeRuntime() {
	runtime.GC()
	debug.FreeOSMemory()
	time.Sleep(80 * time.Millisecond)
}

func captureResourceSnapshot() resourceSnapshot {
	s := resourceSnapshot{
		goroutines: runtime.NumGoroutine(),
	}

	if fdCount, err := readFDCount(); err == nil {
		s.fdCount = fdCount
		s.hasFD = true
	}
	if rssBytes, err := readRSSBytes(); err == nil {
		s.rssBytes = rssBytes
		s.hasRSS = true
	}
	return s
}

func readFDCount() (int, error) {
	if runtime.GOOS != "linux" {
		return 0, fmt.Errorf("FD count not implemented for %s", runtime.GOOS)
	}
	entries, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		return 0, err
	}
	return len(entries), nil
}

func readRSSBytes() (uint64, error) {
	if runtime.GOOS != "linux" {
		// Fallback to runtime.MemStats for non-linux (approximates RSS)
		var ms runtime.MemStats
		runtime.ReadMemStats(&ms)
		return ms.Sys, nil
	}
	data, err := os.ReadFile("/proc/self/statm")
	if err != nil {
		return 0, err
	}
	fields := strings.Fields(string(data))
	if len(fields) < 2 {
		return 0, fmt.Errorf("unexpected /proc/self/statm format")
	}
	pages, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		return 0, err
	}
	return pages * uint64(os.Getpagesize()), nil
}

func assertNoResourceLeaks(t *testing.T, baseline, final resourceSnapshot, maxGDelta, maxFDDelta, maxRSSMBDelta int) {
	t.Helper()

	gDelta := final.goroutines - baseline.goroutines
	if gDelta > maxGDelta {
		t.Fatalf("goroutine leak suspected: baseline=%d final=%d delta=%d allowed=%d", baseline.goroutines, final.goroutines, gDelta, maxGDelta)
	}

	if baseline.hasFD && final.hasFD {
		fdDelta := final.fdCount - baseline.fdCount
		if fdDelta > maxFDDelta {
			t.Fatalf("file-descriptor leak suspected: baseline=%d final=%d delta=%d allowed=%d", baseline.fdCount, final.fdCount, fdDelta, maxFDDelta)
		}
	}

	if baseline.hasRSS && final.hasRSS {
		rssDeltaMB := int((int64(final.rssBytes) - int64(baseline.rssBytes)) / (1024 * 1024))
		if rssDeltaMB > maxRSSMBDelta {
			t.Fatalf("RSS leak suspected: baseline_mb=%d final_mb=%d delta_mb=%d allowed_mb=%d",
				int(baseline.rssBytes/(1024*1024)),
				int(final.rssBytes/(1024*1024)),
				rssDeltaMB,
				maxRSSMBDelta,
			)
		}
	}
}

func isExpectedKilledWaitErr(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "signal: killed") || strings.Contains(msg, "killed")
}
