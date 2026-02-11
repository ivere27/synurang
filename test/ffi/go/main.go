// FFI API Test (Go) — No gRPC dependency
//
// Tests all 4 RPC types using synurang.LoadPlugin() directly with
// proto.Marshal/proto.Unmarshal. No gRPC stubs or ClientConn used.
//
// Build & Run (from project root):
//   go run ./test/ffi/go/ [plugin-path]
//
// Default plugin: bin/libplugin_go.so

package main

import (
	"fmt"
	"io"
	"log"
	"os"
	"sync"
	"time"

	"google.golang.org/protobuf/proto"

	"github.com/ivere27/synurang/pkg/synurang"
	pb "github.com/ivere27/synurang/test/plugin/api"
)

func main() {
	pluginPath := "bin/libplugin_go.so"
	if len(os.Args) > 1 {
		pluginPath = os.Args[1]
	}

	fmt.Println("═══════════════════════════════════════════════════════════════")
	fmt.Println("  Go FFI API Test (No gRPC — all 4 RPC types)")
	fmt.Println("═══════════════════════════════════════════════════════════════")

	plugin, err := synurang.LoadPlugin(pluginPath)
	if err != nil {
		log.Fatalf("Failed to load plugin: %v", err)
	}
	defer plugin.Close()

	passed := 0
	failed := 0

	run := func(name string, fn func() error) {
		fmt.Printf("  %s... ", name)
		if err := fn(); err != nil {
			fmt.Printf("FAIL: %v\n", err)
			failed++
		} else {
			fmt.Println("OK")
			passed++
		}
	}

	run("[1/4] Unary RPC", func() error {
		return testUnary(plugin)
	})
	run("[2/4] Server Streaming", func() error {
		return testServerStream(plugin)
	})
	run("[3/4] Client Streaming", func() error {
		return testClientStream(plugin)
	})
	run("[4/4] Bidi Streaming", func() error {
		return testBidiStream(plugin)
	})

	fmt.Println()
	fmt.Println("═══════════════════════════════════════════════════════════════")
	fmt.Printf("  Results: %d passed, %d failed\n", passed, failed)
	fmt.Println("═══════════════════════════════════════════════════════════════")

	if failed > 0 {
		os.Exit(1)
	}
}

// testUnary: marshal request → plugin.Invoke → unmarshal response
func testUnary(plugin *synurang.Plugin) error {
	reqBytes, err := proto.Marshal(&pb.HelloRequest{Name: "GoFFI"})
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}

	respBytes, err := plugin.Invoke(
		"GoGreeterService",
		"/example.v1.GoGreeterService/Bar",
		reqBytes,
	)
	if err != nil {
		return fmt.Errorf("invoke: %w", err)
	}

	resp := &pb.HelloResponse{}
	if err := proto.Unmarshal(respBytes, resp); err != nil {
		return fmt.Errorf("unmarshal: %w", err)
	}

	if resp.Message == "" {
		return fmt.Errorf("empty response message")
	}
	return nil
}

// testServerStream: open stream → send request → closeSend → recv loop
func testServerStream(plugin *synurang.Plugin) error {
	stream, err := plugin.OpenStream(
		"GoGreeterService",
		"/example.v1.GoGreeterService/BarServerStream",
	)
	if err != nil {
		return fmt.Errorf("open: %w", err)
	}
	defer stream.Close()

	reqBytes, _ := proto.Marshal(&pb.HelloRequest{Name: "StreamTest"})
	if err := stream.Send(reqBytes); err != nil {
		return fmt.Errorf("send: %w", err)
	}
	stream.CloseSend()

	count := 0
	for {
		data, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("recv: %w", err)
		}
		resp := &pb.HelloResponse{}
		if err := proto.Unmarshal(data, resp); err != nil {
			return fmt.Errorf("unmarshal[%d]: %w", count, err)
		}
		count++
	}

	if count == 0 {
		return fmt.Errorf("received 0 messages")
	}
	return nil
}

// testClientStream: open stream → send multiple → closeSend → recv one
func testClientStream(plugin *synurang.Plugin) error {
	stream, err := plugin.OpenStream(
		"GoGreeterService",
		"/example.v1.GoGreeterService/BarClientStream",
	)
	if err != nil {
		return fmt.Errorf("open: %w", err)
	}
	defer stream.Close()

	for i := 0; i < 3; i++ {
		data, _ := proto.Marshal(&pb.HelloRequest{Name: fmt.Sprintf("Msg%d", i)})
		if err := stream.Send(data); err != nil {
			return fmt.Errorf("send[%d]: %w", i, err)
		}
	}
	stream.CloseSend()

	respBytes, err := stream.Recv()
	if err != nil {
		return fmt.Errorf("recv: %w", err)
	}

	resp := &pb.HelloResponse{}
	if err := proto.Unmarshal(respBytes, resp); err != nil {
		return fmt.Errorf("unmarshal: %w", err)
	}

	if resp.Message == "" {
		return fmt.Errorf("empty response message")
	}
	return nil
}

// testBidiStream: open stream → send+recv concurrently
func testBidiStream(plugin *synurang.Plugin) error {
	stream, err := plugin.OpenStream(
		"GoGreeterService",
		"/example.v1.GoGreeterService/BarBidiStream",
	)
	if err != nil {
		return fmt.Errorf("open: %w", err)
	}
	defer stream.Close()

	var wg sync.WaitGroup
	errCh := make(chan error, 2)

	// Sender goroutine
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 3; i++ {
			data, _ := proto.Marshal(&pb.HelloRequest{Name: fmt.Sprintf("Ping%d", i)})
			if err := stream.Send(data); err != nil {
				errCh <- fmt.Errorf("send[%d]: %w", i, err)
				return
			}
		}
		stream.CloseSend()
	}()

	// Receiver goroutine
	wg.Add(1)
	go func() {
		defer wg.Done()
		count := 0
		for {
			data, err := stream.Recv()
			if err == io.EOF {
				break
			}
			if err != nil {
				errCh <- fmt.Errorf("recv: %w", err)
				return
			}
			resp := &pb.HelloResponse{}
			if err := proto.Unmarshal(data, resp); err != nil {
				errCh <- fmt.Errorf("unmarshal[%d]: %w", count, err)
				return
			}
			count++
		}
		if count == 0 {
			errCh <- fmt.Errorf("received 0 messages")
		}
	}()

	// Wait with timeout
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		return fmt.Errorf("timeout")
	}

	close(errCh)
	for e := range errCh {
		return e
	}
	return nil
}
