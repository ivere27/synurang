package module

import (
	"context"
	"fmt"
	"github.com/ivere27/synurang/pkg/ffierror"
	"io"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestReleaseClearsCompletedQueuesWithoutPolling(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	call := &Call{ctx: ctx, cancel: cancel, changed: make(chan struct{}), finished: true,
		input: [][]byte{{1}}, output: [][]byte{{2}}}
	instance := New()
	instance.calls[1] = call
	instance.release(1)
	if call.input != nil || call.output != nil {
		t.Fatal("release retained completed buffers")
	}
	if len(instance.retired) != 0 {
		t.Fatal("completed call still required a cleanup poll")
	}
}

func TestRequestViolationDiscardsQueuedResponses(t *testing.T) {
	for _, duplicate := range []bool{false, true} {
		t.Run(fmt.Sprintf("duplicate=%t", duplicate), func(t *testing.T) {
			instance := New()
			ready := make(chan struct{})
			if err := instance.Register("/test/Server", false, true, func(call *Call) error {
				if err := call.SendBytes([]byte{1}); err != nil {
					return err
				}
				close(ready)
				<-call.Context().Done()
				return call.Context().Err()
			}); err != nil {
				t.Fatal(err)
			}
			defer func() {
				for instance.destroy() == 3 {
					time.Sleep(time.Millisecond)
				}
			}()
			id := instance.open("/test/Server", false, true, ^uint64(0), true)
			if duplicate && instance.send(id, nil) != 0 {
				t.Fatal("first send failed")
			}
			<-ready
			status := 0
			if duplicate {
				status = instance.send(id, nil)
			} else {
				status = instance.halfClose(id)
			}
			if status != -3 {
				t.Fatalf("invalid request accepted: %d", status)
			}
			if kind, code, _, _ := instance.receive(id); kind != 2 || code != 3 {
				t.Fatalf("queued output survived protocol failure: kind=%d code=%d", kind, code)
			}
		})
	}
}

func TestHandlerErrorAfterDeadline(t *testing.T) {
	for _, test := range []struct {
		name string
		err  error
		code int
	}{
		{"application", ffierror.New(42, "Denied", 7), 7},
		{"wrapped deadline", fmt.Errorf("operation: %w", context.DeadlineExceeded), 4},
	} {
		t.Run(test.name, func(t *testing.T) {
			instance := New()
			if err := instance.Register("/test/Fail", false, false, func(call *Call) error {
				<-call.Context().Done()
				return test.err
			}); err != nil {
				t.Fatal(err)
			}
			defer func() {
				for instance.destroy() == 3 {
					time.Sleep(time.Millisecond)
				}
			}()
			id := instance.open("/test/Fail", false, false, 1, true)
			deadline := time.Now().Add(time.Second)
			for {
				kind, code, _, _ := instance.receive(id)
				if kind == 2 {
					if code != test.code {
						t.Fatalf("handler error replaced: code=%d want=%d", code, test.code)
					}
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("handler did not complete")
				}
				time.Sleep(time.Millisecond)
			}
		})
	}
}

func TestTerminalErrorSurvivesDeadline(t *testing.T) {
	instance := New()
	if err := instance.Register("/test/Fail", false, false, func(call *Call) error {
		return ffierror.New(42, "Denied", 7)
	}); err != nil {
		t.Fatal(err)
	}
	id := instance.open("/test/Fail", false, false, 100, true)
	for {
		kind, code, _, _ := instance.receive(id)
		if kind == 2 {
			if code != 7 {
				t.Fatalf("initial terminal = %d", code)
			}
			break
		}
		time.Sleep(time.Millisecond)
	}
	time.Sleep(110 * time.Millisecond)
	instance.cancel(id, 1)
	if kind, code, _, _ := instance.receive(id); kind != 2 || code != 7 {
		t.Fatalf("terminal changed to %d/%d", kind, code)
	}
	for instance.destroy() == 3 {
		time.Sleep(time.Millisecond)
	}
}

func TestDestroyWaitsForRetainedProducer(t *testing.T) {
	instance := New()
	destroyed := 0
	if err := instance.OnClose(func() { destroyed++ }); err != nil {
		t.Fatal(err)
	}
	release := make(chan func(), 1)
	stopped := make(chan struct{})
	if err := instance.Register("/test/Wait", false, false, func(call *Call) error {
		release <- call.Retain()
		<-call.Context().Done()
		close(stopped)
		return call.Context().Err()
	}); err != nil {
		t.Fatal(err)
	}
	id := instance.open("/test/Wait", false, false, ^uint64(0), true)
	if id == 0 {
		t.Fatal("open failed")
	}
	cleanup := <-release
	if status := instance.destroy(); status != 3 {
		t.Fatalf("destroy = %d", status)
	}
	if destroyed != 0 {
		t.Fatal("service destroyed while producer retained")
	}
	<-stopped
	if status := instance.destroy(); status != 3 {
		t.Fatalf("retained destroy = %d", status)
	}
	cleanup()
	cleanup() // Completion can race cancellation, but releases only once.
	deadline := time.Now().Add(time.Second)
	for instance.destroy() == 3 {
		if time.Now().After(deadline) {
			t.Fatal("producer cleanup was not observed")
		}
		time.Sleep(time.Millisecond)
	}
	if destroyed != 1 {
		t.Fatal("service cleanup missing")
	}
	instance.destroy()
	if destroyed != 1 {
		t.Fatal("service cleanup ran twice")
	}
}

func TestCancellationUnblocksProducerAndPreservesDeadline(t *testing.T) {
	instance := New()
	entered := make(chan struct{})
	finished := make(chan error, 1)
	if err := instance.Register("/test/Blocked", false, true, func(call *Call) error {
		// More output than capacity: producer must be suspended until cancelled.
		for n := 0; n < 16; n++ {
			if err := call.SendBytes(nil); err != nil {
				return err
			}
		}
		close(entered)
		err := call.SendBytes(nil)
		finished <- err
		return err
	}); err != nil {
		t.Fatal(err)
	}
	id := instance.open("/test/Blocked", false, true, ^uint64(0), true)
	<-entered
	instance.cancel(id, 4)
	select {
	case err := <-finished:
		if err != context.Canceled {
			t.Fatalf("send = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("blocked producer did not stop")
	}
	kind, code, _, status := instance.receive(id)
	if status != 0 || kind != 2 || code != 4 {
		t.Fatalf("terminal = %d/%d/%d", status, kind, code)
	}
	for instance.destroy() == 3 {
		time.Sleep(time.Millisecond)
	}
}

func TestConcurrentRetention(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	call := &Call{ctx: ctx, cancel: cancel, changed: make(chan struct{})}
	var workers sync.WaitGroup
	for n := 0; n < 100; n++ {
		release := call.Retain()
		workers.Add(1)
		go func() { defer workers.Done(); release(); release() }()
	}
	workers.Wait()
	if call.retained != 0 {
		t.Fatal("retained references leaked")
	}
}

func closeTestInstance(t *testing.T, instance *Instance) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for instance.destroy() == 3 {
		if time.Now().After(deadline) {
			t.Fatal("instance cleanup did not finish")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestNotificationsCoalesceAcrossCallsAndRearmAfterPoll(t *testing.T) {
	instance := New()
	t.Cleanup(func() { closeTestInstance(t, instance) })
	var notifications atomic.Int32
	instance.wakeup = func() { notifications.Add(1) }
	ready := make(chan struct{}, 2)
	proceed := make(chan struct{})
	if err := instance.Register("/test/Notify", false, true, func(call *Call) error {
		if err := call.SendBytes([]byte{1}); err != nil {
			return err
		}
		ready <- struct{}{}
		select {
		case <-proceed:
		case <-call.Context().Done():
			return call.Context().Err()
		}
		if err := call.SendBytes([]byte{2}); err != nil {
			return err
		}
		ready <- struct{}{}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	ids := []uint64{
		instance.open("/test/Notify", false, true, ^uint64(0), true),
		instance.open("/test/Notify", false, true, ^uint64(0), true),
	}
	for round := 1; round <= 2; round++ {
		for range ids {
			select {
			case <-ready:
			case <-time.After(time.Second):
				t.Fatal("producer did not publish")
			}
		}
		if got := notifications.Load(); got != int32(round) {
			t.Fatalf("round %d: notifications = %d", round, got)
		}
		for _, id := range ids {
			kind, _, data, status := instance.receive(id)
			if status != 0 || kind != 1 || len(data) != 1 || data[0] != byte(round) {
				t.Fatalf("response = %d/%d/%v", status, kind, data)
			}
		}
		if round == 1 {
			instance.poll()
			close(proceed)
		}
	}
}

func TestOutputNotificationReleasesCallLockAndKeepsProducerAlive(t *testing.T) {
	instance := New()
	t.Cleanup(func() { closeTestInstance(t, instance) })
	entered, resume := make(chan struct{}), make(chan struct{})
	defer close(resume)
	var notifications atomic.Int32
	instance.wakeup = func() {
		if notifications.Add(1) == 1 {
			close(entered)
			<-resume
		}
	}
	if err := instance.Register("/test/Notify", false, true, func(call *Call) error {
		return call.SendBytes([]byte{42})
	}); err != nil {
		t.Fatal(err)
	}
	id := instance.open("/test/Notify", false, true, ^uint64(0), true)
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("notification did not start")
	}
	received := make(chan bool, 1)
	go func() {
		kind, _, data, status := instance.receive(id)
		received <- status == 0 && kind == 1 && len(data) == 1 && data[0] == 42
	}()
	select {
	case ok := <-received:
		if !ok {
			t.Fatal("response was not available during notification")
		}
	case <-time.After(time.Second):
		t.Fatal("notification held the call lock")
	}
	if status := instance.destroy(); status != 3 {
		t.Fatalf("destroy freed a producer inside its callback: %d", status)
	}
}

func TestInputCapacityNotificationAndHalfCloseWakeProducer(t *testing.T) {
	instance := New()
	instance.capacityIn = 1
	t.Cleanup(func() { closeTestInstance(t, instance) })
	wakeup := make(chan struct{}, 4)
	instance.wakeup = func() { wakeup <- struct{}{} }
	consume, done := make(chan struct{}), make(chan error, 1)
	if err := instance.Register("/test/Input", true, true, func(call *Call) error {
		select {
		case <-consume:
		case <-call.Context().Done():
			return call.Context().Err()
		}
		for n := 0; n < 2; n++ {
			if _, err := call.RecvBytes(); err != nil {
				return err
			}
		}
		_, err := call.RecvBytes()
		done <- err
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	id := instance.open("/test/Input", true, true, ^uint64(0), true)
	if instance.send(id, nil) != 0 || instance.send(id, nil) != -4 {
		t.Fatal("input queue did not apply backpressure")
	}
	select {
	case <-wakeup:
		t.Fatal("host input generated an unnecessary host notification")
	default:
	}
	close(consume)
	select {
	case <-wakeup:
	case <-time.After(time.Second):
		t.Fatal("freed input capacity did not notify the host")
	}
	instance.poll()
	if instance.send(id, nil) != 0 || instance.halfClose(id) != 0 {
		t.Fatal("input did not resume")
	}
	select {
	case err := <-done:
		if err != io.EOF {
			t.Fatalf("request end = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("half-close did not wake the producer")
	}
}

func TestRetainedProducerNotifiesAfterPendingDestroy(t *testing.T) {
	instance := New()
	t.Cleanup(func() { closeTestInstance(t, instance) })
	wakeup := make(chan struct{}, 4)
	instance.wakeup = func() { wakeup <- struct{}{} }
	retained := make(chan func(), 1)
	if err := instance.Register("/test/Retain", false, true, func(call *Call) error {
		retained <- call.Retain()
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	instance.open("/test/Retain", false, true, ^uint64(0), true)
	release := <-retained
	defer release()
	select {
	case <-wakeup:
	case <-time.After(time.Second):
		t.Fatal("handler completion did not notify")
	}
	if status := instance.destroy(); status != 3 {
		t.Fatalf("destroy ignored retention: %d", status)
	}
	release()
	select {
	case <-wakeup:
	case <-time.After(time.Second):
		t.Fatal("last retained producer did not notify")
	}
	if status := instance.destroy(); status != 0 {
		t.Fatalf("destroy after producer completion = %d", status)
	}
}
