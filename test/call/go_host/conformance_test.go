//go:build synurang_call_conformance

package go_host_test

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	api "github.com/ivere27/synurang/pkg/api"
	"github.com/ivere27/synurang/pkg/call"
	"github.com/ivere27/synurang/pkg/callgrpc"
	pb "github.com/ivere27/synurang/test/call/pb"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func path(method string) string { return "/synurang.test.Calls/" + method }
func wire(value int32) []byte   { data, _ := proto.Marshal(&pb.Value{Value: value}); return data }
func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
func same(t *testing.T, actual, expected []byte) {
	t.Helper()
	if !bytes.Equal(actual, expected) {
		t.Fatalf("%x != %x", actual, expected)
	}
}
func moduleError(t *testing.T, code int, err error) *call.Error {
	t.Helper()
	var failure *call.Error
	if !errors.As(err, &failure) || failure.Code != code {
		t.Fatalf("expected module status %d, got %v", code, err)
	}
	return failure
}

func TestModules(t *testing.T) {
	modules := filepath.SplitList(os.Getenv("SYNURANG_TEST_MODULES"))
	if len(modules) == 0 {
		t.Fatal("SYNURANG_TEST_MODULES must list built native providers")
	}
	for _, module := range modules {
		t.Run(filepath.Base(module), func(t *testing.T) {
			t.Run("native", func(t *testing.T) { native(t, module) })
			t.Run("grpc", func(t *testing.T) { grpcClient(t, module) })
		})
	}
}

func TestEarlyResponseSurvivesRequestEOF(t *testing.T) {
	module := os.Getenv("SYNURANG_TEST_EARLY_MODULE")
	if module == "" {
		t.Fatal("SYNURANG_TEST_EARLY_MODULE is required")
	}
	host, err := call.Load(module, 16)
	must(t, err)
	defer host.Close()
	for _, method := range []string{"Client", "Fail"} {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		stream, err := callgrpc.New(host).NewStream(ctx, &grpc.StreamDesc{ClientStreams: true}, "/early.Service/"+method)
		must(t, err)
		must(t, stream.SendMsg(&pb.Value{Value: 42}))
		time.Sleep(30 * time.Millisecond)
		if err := stream.SendMsg(&pb.Value{Value: 43}); err != io.EOF {
			t.Fatalf("Expected send EOF, got %v", err)
		}
		must(t, stream.CloseSend())
		response := &pb.Value{}
		err = stream.RecvMsg(response)
		if method == "Client" {
			must(t, err)
			if response.Value != 42 {
				t.Fatalf("Lost early reply: %v", response)
			}
		} else if status.Code(err) != codes.PermissionDenied {
			t.Fatalf("Lost terminal error: %v", err)
		}
	}
}

func TestReleaseDrainsWithoutAnotherCall(t *testing.T) {
	module := os.Getenv("SYNURANG_TEST_RELEASE_MODULE")
	if module == "" {
		t.Fatal("SYNURANG_TEST_RELEASE_MODULE is required")
	}
	host, err := call.Load(module, 16)
	must(t, err)
	defer host.Close()
	marker := filepath.Join(t.TempDir(), "cleanup")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var calls []*call.Call
	for i := 0; i < 96; i++ {
		stream, err := host.Open(ctx, call.Method{Path: "/test.Release/Watch", ResponseStream: true})
		must(t, err)
		calls = append(calls, stream)
		must(t, stream.Send([]byte(marker)))
		_, err = stream.Recv() // Confirms that the provider saved the marker path.
		must(t, err)
	}
	for _, stream := range calls {
		must(t, stream.Close())
	}
	for deadline := time.Now().Add(2 * time.Second); ; {
		data, _ := os.ReadFile(marker)
		if bytes.Count(data, []byte("C")) == len(calls) && bytes.Count(data, []byte("D")) == len(calls) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("release cleanup stopped with host still open: %q", data)
		}
		time.Sleep(time.Millisecond)
	}
}

func native(t *testing.T, module string) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	host, err := call.Load(module, 2)
	must(t, err)
	defer host.Close()
	other, err := call.Load(module, 2)
	must(t, err)
	defer other.Close()
	data, err := host.Unary(ctx, path("Unary"), nil)
	must(t, err)
	same(t, data, nil)
	data, err = other.Unary(ctx, path("Unary"), wire(42))
	must(t, err)
	same(t, data, wire(42))
	var concurrent sync.WaitGroup
	for index := int32(0); index < 40; index++ {
		concurrent.Add(1)
		go func(value int32) {
			defer concurrent.Done()
			data, err := host.Unary(ctx, path("Unary"), wire(value))
			if err != nil || !bytes.Equal(data, wire(value)) {
				t.Errorf("Concurrent unary: %x, %v", data, err)
			}
		}(index)
	}
	concurrent.Wait()
	server, err := host.Open(ctx, call.Method{Path: path("Server"), ResponseStream: true})
	must(t, err)
	must(t, server.Send(wire(100)))
	must(t, server.HalfClose())
	for index := int32(0); index < 100; index++ {
		data, err := server.Recv()
		must(t, err)
		same(t, data, wire(index))
	}
	_, err = server.Recv()
	if err != io.EOF {
		t.Fatalf("Server EOF: %v", err)
	}
	must(t, server.Close())
	client, err := host.Open(ctx, call.Method{Path: path("Client"), RequestStream: true})
	must(t, err)
	for index := 0; index < 100; index++ {
		must(t, client.Send(wire(1)))
	}
	must(t, client.HalfClose())
	data, err = client.Recv()
	must(t, err)
	same(t, data, wire(100))
	_, err = client.Recv()
	if err != io.EOF {
		t.Fatalf("Client EOF: %v", err)
	}
	must(t, client.Close())
	bidi, err := host.Open(ctx, call.Method{Path: path("Bidi"), RequestStream: true, ResponseStream: true})
	must(t, err)
	for index := int32(0); index < 40; index++ {
		must(t, bidi.Send(wire(index)))
		data, err := bidi.Recv()
		must(t, err)
		same(t, data, wire(index))
	}
	must(t, bidi.HalfClose())
	_, err = bidi.Recv()
	if err != io.EOF {
		t.Fatalf("Bidi EOF: %v", err)
	}
	must(t, bidi.Close())
	_, err = host.Unary(ctx, path("Fail"), nil)
	failure := moduleError(t, 7, err)
	detail := &api.Error{}
	must(t, proto.Unmarshal(failure.Details, detail))
	if detail.Code != 42 {
		t.Fatal("Lost application code")
	}
	_, err = host.Unary(ctx, path("Unary"), wire(-1))
	moduleError(t, 7, err)
	_, err = host.Unary(ctx, path("Missing"), nil)
	moduleError(t, 12, err)
	timeout, stop := context.WithTimeout(ctx, 10*time.Millisecond)
	_, err = host.Unary(timeout, path("Wait"), nil)
	stop()
	moduleError(t, 4, err)
	waitCtx, stopWait := context.WithCancel(ctx)
	waiting, err := host.Open(waitCtx, call.Method{Path: path("Wait")})
	must(t, err)
	must(t, waiting.Send(nil))
	must(t, waiting.HalfClose())
	finished := make(chan error, 1)
	go func() { _, err := waiting.Recv(); finished <- err }()
	stopWait()
	moduleError(t, 1, <-finished)
	must(t, waiting.Close())
	pending, err := host.Open(ctx, call.Method{Path: path("Wait")})
	must(t, err)
	must(t, pending.Send(nil))
	must(t, host.Close())
	_, err = pending.Recv()
	moduleError(t, 1, err)
	must(t, pending.Close())
}

func grpcClient(t *testing.T, module string) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	host, err := call.Load(module, 2)
	must(t, err)
	defer host.Close()
	conn := callgrpc.New(host)
	client := pb.NewCallsClient(conn)
	var headers, trailers metadata.MD
	var done atomic.Int32
	response, err := client.Unary(ctx, &pb.Value{}, grpc.Header(&headers), grpc.Trailer(&trailers), grpc.OnFinish(func(err error) { done.Add(1) }))
	must(t, err)
	if response.Value != 0 || done.Load() != 1 || len(headers) != 0 || len(trailers) != 0 {
		t.Fatal("Unary lifecycle")
	}
	server, err := client.Server(ctx, &pb.Value{Value: 100})
	must(t, err)
	for index := int32(0); index < 100; index++ {
		response, err := server.Recv()
		must(t, err)
		if response.Value != index {
			t.Fatal("Server order")
		}
	}
	_, err = server.Recv()
	if err != io.EOF {
		t.Fatalf("Server EOF: %v", err)
	}
	sum, err := client.Client(ctx)
	must(t, err)
	for index := 0; index < 100; index++ {
		must(t, sum.Send(&pb.Value{Value: 1}))
	}
	response, err = sum.CloseAndRecv()
	must(t, err)
	if response.Value != 100 {
		t.Fatal("Client sum")
	}
	bidi, err := client.Bidi(ctx)
	must(t, err)
	for index := int32(0); index < 40; index++ {
		must(t, bidi.Send(&pb.Value{Value: index}))
		response, err := bidi.Recv()
		must(t, err)
		if response.Value != index {
			t.Fatal("Bidi response before half-close")
		}
	}
	must(t, bidi.CloseSend())
	_, err = bidi.Recv()
	if err != io.EOF {
		t.Fatalf("Bidi EOF: %v", err)
	}
	_, err = client.Fail(ctx, &pb.Value{}, grpc.Trailer(&trailers))
	if status.Code(err) != codes.PermissionDenied || !strings.Contains(status.Convert(err).Message(), "Permission denied") {
		t.Fatalf("Error status: %v", err)
	}
	details := status.Convert(err).Details()
	if len(details) != 1 || details[0].(*api.Error).Code != 42 || len(trailers.Get("synurang-error-bin")) != 1 {
		t.Fatal("Error details")
	}
	_, err = client.Unary(ctx, &pb.Value{Value: -1})
	if status.Code(err) != codes.PermissionDenied {
		t.Fatalf("Response then error: %v", err)
	}
	err = conn.Invoke(ctx, path("Missing"), &pb.Value{}, &pb.Value{})
	if status.Code(err) != codes.Unimplemented {
		t.Fatalf("Unknown method: %v", err)
	}
	timeout, stop := context.WithTimeout(ctx, 10*time.Millisecond)
	_, err = client.Wait(timeout, &pb.Value{})
	stop()
	if status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("Deadline: %v", err)
	}
	_, err = client.Unary(metadata.NewOutgoingContext(ctx, metadata.Pairs("x-test", "unsupported")), &pb.Value{})
	if status.Code(err) != codes.Unimplemented {
		t.Fatalf("Metadata accepted: %v", err)
	}
	_, err = client.Unary(ctx, &pb.Value{Value: 42}, grpc.MaxCallSendMsgSize(0))
	if status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("Send limit: %v", err)
	}
	_, err = client.Unary(ctx, &pb.Value{Value: 42}, grpc.MaxCallRecvMsgSize(0))
	if status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("Receive limit: %v", err)
	}
	streamCtx, stopStream := context.WithCancel(ctx)
	waiting, err := conn.NewStream(streamCtx, &grpc.StreamDesc{}, path("Wait"))
	must(t, err)
	must(t, waiting.SendMsg(&pb.Value{}))
	must(t, waiting.CloseSend())
	stopStream()
	err = waiting.RecvMsg(&pb.Value{})
	if status.Code(err) != codes.Canceled {
		t.Fatalf("Stream cancellation: %v", err)
	}
}
