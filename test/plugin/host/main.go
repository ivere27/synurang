package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"math/rand"
	"sync"
	"time"

	"google.golang.org/protobuf/proto"

	"github.com/ivere27/synurang/pkg/synurang"
	pb "github.com/ivere27/synurang/test/plugin/api"
)

// randomSleep adds a small random delay (0-2ms) to increase race condition chances
func randomSleep() {
	time.Sleep(time.Duration(rand.Intn(2000)) * time.Microsecond)
}

// testContextTimeout verifies that context cancellation works for all 4 RPC types
func testContextTimeout(plugin *synurang.Plugin) {
	conn := synurang.NewPluginClientConn(plugin, "GoGreeterService")
	client := pb.NewGoGreeterServiceClient(conn)

	// Helper to create cancelled context
	cancelledCtx := func() context.Context {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		return ctx
	}

	// ===================
	// 1. UNARY
	// ===================
	fmt.Println("[Unary] Testing cancelled context...")
	_, err := client.Bar(cancelledCtx(), &pb.HelloRequest{Name: "Test"})
	if err == nil {
		log.Fatalf("Unary: Expected error with cancelled context")
	}
	fmt.Printf("  OK: Unary with cancelled ctx returns: %v\n", err)

	// ===================
	// 2. SERVER STREAMING
	// ===================
	fmt.Println("[ServerStream] Testing cancelled context...")
	_, err = client.BarServerStream(cancelledCtx(), &pb.HelloRequest{Name: "Test"})
	if err == nil {
		log.Fatalf("ServerStream: Expected error opening with cancelled context")
	}
	fmt.Printf("  OK: ServerStream open with cancelled ctx returns: %v\n", err)

	// Test RecvMsg with cancel mid-stream
	fmt.Println("[ServerStream] Testing cancel during Recv...")
	ctx, cancel := context.WithCancel(context.Background())
	stream, err := client.BarServerStream(ctx, &pb.HelloRequest{Name: "CancelTest"})
	if err != nil {
		log.Fatalf("ServerStream: Failed to open: %v", err)
	}
	// Receive one message successfully
	_, err = stream.Recv()
	if err != nil {
		log.Fatalf("ServerStream: First Recv failed: %v", err)
	}
	// Cancel and try to receive
	cancel()
	_, err = stream.Recv()
	if err == nil {
		log.Fatalf("ServerStream: Expected error after cancel")
	}
	fmt.Printf("  OK: ServerStream Recv after cancel returns: %v\n", err)

	// ===================
	// 3. CLIENT STREAMING
	// ===================
	fmt.Println("[ClientStream] Testing cancelled context...")
	_, err = client.BarClientStream(cancelledCtx())
	if err == nil {
		log.Fatalf("ClientStream: Expected error opening with cancelled context")
	}
	fmt.Printf("  OK: ClientStream open with cancelled ctx returns: %v\n", err)

	// Test SendMsg with cancel
	fmt.Println("[ClientStream] Testing cancel during Send...")
	ctx2, cancel2 := context.WithCancel(context.Background())
	cstream, err := client.BarClientStream(ctx2)
	if err != nil {
		log.Fatalf("ClientStream: Failed to open: %v", err)
	}
	// Send one message successfully
	err = cstream.Send(&pb.HelloRequest{Name: "Msg1"})
	if err != nil {
		log.Fatalf("ClientStream: First Send failed: %v", err)
	}
	// Cancel and try to send
	cancel2()
	err = cstream.Send(&pb.HelloRequest{Name: "Msg2"})
	if err == nil {
		log.Fatalf("ClientStream: Expected error after cancel")
	}
	fmt.Printf("  OK: ClientStream Send after cancel returns: %v\n", err)

	// ===================
	// 4. BIDI STREAMING
	// ===================
	fmt.Println("[BidiStream] Testing cancelled context...")
	_, err = client.BarBidiStream(cancelledCtx())
	if err == nil {
		log.Fatalf("BidiStream: Expected error opening with cancelled context")
	}
	fmt.Printf("  OK: BidiStream open with cancelled ctx returns: %v\n", err)

	// Test Send/Recv with cancel
	fmt.Println("[BidiStream] Testing cancel during operation...")
	ctx3, cancel3 := context.WithCancel(context.Background())
	bstream, err := client.BarBidiStream(ctx3)
	if err != nil {
		log.Fatalf("BidiStream: Failed to open: %v", err)
	}
	// Send one message
	err = bstream.Send(&pb.HelloRequest{Name: "Ping"})
	if err != nil {
		log.Fatalf("BidiStream: Send failed: %v", err)
	}
	// Receive response
	_, err = bstream.Recv()
	if err != nil {
		log.Fatalf("BidiStream: Recv failed: %v", err)
	}
	// Cancel and verify both Send and Recv fail
	cancel3()
	err = bstream.Send(&pb.HelloRequest{Name: "Ping2"})
	if err == nil {
		log.Fatalf("BidiStream: Expected Send error after cancel")
	}
	fmt.Printf("  OK: BidiStream Send after cancel returns: %v\n", err)

	_, err = bstream.Recv()
	if err == nil {
		log.Fatalf("BidiStream: Expected Recv error after cancel")
	}
	fmt.Printf("  OK: BidiStream Recv after cancel returns: %v\n", err)

	fmt.Println("  All 4 RPC types respect context cancellation!")
}

func main() {
	// Load the plugin using synurang's PluginLoader
	plugin, err := synurang.LoadPlugin("../impl/plugin.so")
	if err != nil {
		log.Fatalf("Failed to load plugin: %v", err)
	}
	defer plugin.Close()

	fmt.Println("=== Test 1: Unary RPC (Raw Invoke) ===")
	testRawInvoke(plugin)

	fmt.Println("\n=== Test 2: Unary RPC (gRPC Client) ===")
	testUnary(plugin)

	fmt.Println("\n=== Test 3: Server Streaming RPC ===")
	testServerStreaming(plugin)

	fmt.Println("\n=== Test 4: Client Streaming RPC ===")
	testClientStreaming(plugin)

	fmt.Println("\n=== Test 5: Bidirectional Streaming RPC ===")
	testBidiStreaming(plugin)

	fmt.Println("\n=== Test 6: Safety Check (Send after CloseSend) ===")
	testSafeSendAfterClose(plugin)

	fmt.Println("\n=== Test 7: Concurrent Send/Recv (Bidi) ===")
	testConcurrentBidi(plugin)

	fmt.Println("\n=== Test 8: Stress Test (All RPC types concurrent) ===")
	testConcurrentAllTypes(plugin)

	fmt.Println("\n=== Test 9: Context Timeout ===")
	testContextTimeout(plugin)

	fmt.Println("\n=== All tests passed! ===")
}

// testSafeSendAfterClose ensures no panic when sending after CloseSend
func testSafeSendAfterClose(plugin *synurang.Plugin) {
	conn := synurang.NewPluginClientConn(plugin, "GoGreeterService")
	client := pb.NewGoGreeterServiceClient(conn)

	fmt.Println("Calling BarBidiStream (Safety Check)...")
	stream, err := client.BarBidiStream(context.Background())
	if err != nil {
		log.Fatalf("Failed to open stream: %v", err)
	}

	// Send one message
	if err := stream.Send(&pb.HelloRequest{Name: "Ping 1"}); err != nil {
		log.Fatalf("Failed to send: %v", err)
	}

	// Close send side
	if err := stream.CloseSend(); err != nil {
		log.Fatalf("CloseSend failed: %v", err)
	}
	fmt.Println("  CloseSend called.")

	// Try to send again - SHOULD FAIL GRACEFULLY (return error), NOT PANIC
	fmt.Println("  Attempting Send after CloseSend...")
	err = stream.Send(&pb.HelloRequest{Name: "Ping 2"})
	if err == nil {
		fmt.Println("  WARNING: Send succeeded after CloseSend (should probably fail)")
	} else {
		fmt.Printf("  OK: Send failed as expected: %v\n", err)
	}
}

// testRawInvoke demonstrates low-level plugin invocation
func testRawInvoke(plugin *synurang.Plugin) {
	req := &pb.HelloRequest{Name: "Host Application (Raw)"}
	reqBytes, err := proto.Marshal(req)
	if err != nil {
		log.Fatalf("Failed to marshal request: %v", err)
	}

	fmt.Println("Calling plugin via raw Invoke...")
	respBytes, err := plugin.Invoke("GoGreeterService", "/example.v1.GoGreeterService/Bar", reqBytes)
	if err != nil {
		log.Fatalf("Plugin call failed: %v", err)
	}

	resp := &pb.HelloResponse{}
	if err := proto.Unmarshal(respBytes, resp); err != nil {
		log.Fatalf("Failed to unmarshal response: %v", err)
	}

	fmt.Printf("  OK: %s\n", resp.Message)
}

// testUnary demonstrates unary RPC via gRPC client
func testUnary(plugin *synurang.Plugin) {
	conn := synurang.NewPluginClientConn(plugin, "GoGreeterService")
	client := pb.NewGoGreeterServiceClient(conn)

	fmt.Println("Calling Bar (unary)...")
	resp, err := client.Bar(context.Background(), &pb.HelloRequest{Name: "Unary Test"})
	if err != nil {
		log.Fatalf("Unary call failed: %v", err)
	}

	fmt.Printf("  OK: %s\n", resp.Message)
}

// testServerStreaming demonstrates server streaming RPC
func testServerStreaming(plugin *synurang.Plugin) {
	conn := synurang.NewPluginClientConn(plugin, "GoGreeterService")
	client := pb.NewGoGreeterServiceClient(conn)

	fmt.Println("Calling BarServerStream (server streaming)...")
	stream, err := client.BarServerStream(context.Background(), &pb.HelloRequest{Name: "ServerStream Test"})
	if err != nil {
		log.Fatalf("Failed to open stream: %v", err)
	}

	count := 0
	for {
		resp, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			log.Fatalf("Stream receive error: %v", err)
		}
		fmt.Printf("  Received[%d]: %s\n", count, resp.Message)
		count++
	}
	fmt.Printf("  OK: Received %d messages\n", count)
}

// testClientStreaming demonstrates client streaming RPC
func testClientStreaming(plugin *synurang.Plugin) {
	conn := synurang.NewPluginClientConn(plugin, "GoGreeterService")
	client := pb.NewGoGreeterServiceClient(conn)

	fmt.Println("Calling BarClientStream (client streaming)...")
	stream, err := client.BarClientStream(context.Background())
	if err != nil {
		log.Fatalf("Failed to open stream: %v", err)
	}

	// Send 3 messages
	for i := 0; i < 3; i++ {
		if err := stream.Send(&pb.HelloRequest{Name: fmt.Sprintf("Message %d", i)}); err != nil {
			log.Fatalf("Failed to send: %v", err)
		}
		fmt.Printf("  Sent: Message %d\n", i)
	}

	// Close send and get response
	resp, err := stream.CloseAndRecv()
	if err != nil {
		log.Fatalf("CloseAndRecv failed: %v", err)
	}

	fmt.Printf("  OK: %s\n", resp.Message)
}

// testBidiStreaming demonstrates bidirectional streaming RPC
func testBidiStreaming(plugin *synurang.Plugin) {
	conn := synurang.NewPluginClientConn(plugin, "GoGreeterService")
	client := pb.NewGoGreeterServiceClient(conn)

	fmt.Println("Calling BarBidiStream (bidi streaming)...")
	stream, err := client.BarBidiStream(context.Background())
	if err != nil {
		log.Fatalf("Failed to open stream: %v", err)
	}

	// Send and receive in ping-pong fashion
	for i := 0; i < 3; i++ {
		// Send
		if err := stream.Send(&pb.HelloRequest{Name: fmt.Sprintf("Ping %d", i)}); err != nil {
			log.Fatalf("Failed to send: %v", err)
		}
		fmt.Printf("  Sent: Ping %d\n", i)

		// Receive
		resp, err := stream.Recv()
		if err != nil {
			log.Fatalf("Failed to receive: %v", err)
		}
		fmt.Printf("  Received: %s\n", resp.Message)
	}

	// Close send side
	if err := stream.CloseSend(); err != nil {
		log.Fatalf("CloseSend failed: %v", err)
	}

	fmt.Println("  OK: Bidi streaming completed")
}

// testConcurrentAllTypes runs all RPC types concurrently to test thread safety
func testConcurrentAllTypes(plugin *synurang.Plugin) {
	const (
		numWorkers   = 5 // workers per RPC type
		numCallsEach = 5 // calls per worker (5 * 5 * 4 = 100 total)
	)

	conn := synurang.NewPluginClientConn(plugin, "GoGreeterService")
	client := pb.NewGoGreeterServiceClient(conn)

	var wg sync.WaitGroup
	errors := make(chan error, 1000)

	// Unary workers
	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for i := 0; i < numCallsEach; i++ {
				randomSleep()
				_, err := client.Bar(context.Background(), &pb.HelloRequest{
					Name: fmt.Sprintf("Unary-W%d-C%d", workerID, i),
				})
				if err != nil {
					errors <- fmt.Errorf("unary W%d-C%d: %w", workerID, i, err)
					return
				}
			}
		}(w)
	}

	// Server streaming workers
	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for i := 0; i < numCallsEach; i++ {
				randomSleep()
				stream, err := client.BarServerStream(context.Background(), &pb.HelloRequest{
					Name: fmt.Sprintf("ServerStream-W%d-C%d", workerID, i),
				})
				if err != nil {
					errors <- fmt.Errorf("server-stream open W%d-C%d: %w", workerID, i, err)
					return
				}
				for {
					randomSleep()
					_, err := stream.Recv()
					if err == io.EOF {
						break
					}
					if err != nil {
						errors <- fmt.Errorf("server-stream recv W%d-C%d: %w", workerID, i, err)
						return
					}
				}
			}
		}(w)
	}

	// Client streaming workers
	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for i := 0; i < numCallsEach; i++ {
				randomSleep()
				stream, err := client.BarClientStream(context.Background())
				if err != nil {
					errors <- fmt.Errorf("client-stream open W%d-C%d: %w", workerID, i, err)
					return
				}
				for j := 0; j < 3; j++ {
					randomSleep()
					if err := stream.Send(&pb.HelloRequest{Name: fmt.Sprintf("Msg%d", j)}); err != nil {
						errors <- fmt.Errorf("client-stream send W%d-C%d: %w", workerID, i, err)
						return
					}
				}
				randomSleep()
				if _, err := stream.CloseAndRecv(); err != nil {
					errors <- fmt.Errorf("client-stream close W%d-C%d: %w", workerID, i, err)
					return
				}
			}
		}(w)
	}

	// Bidi streaming workers
	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for i := 0; i < numCallsEach; i++ {
				randomSleep()
				stream, err := client.BarBidiStream(context.Background())
				if err != nil {
					errors <- fmt.Errorf("bidi-stream open W%d-C%d: %w", workerID, i, err)
					return
				}

				// Concurrent send/recv within this stream
				var innerWg sync.WaitGroup
				innerWg.Add(2)

				// Sender
				go func() {
					defer innerWg.Done()
					for j := 0; j < 3; j++ {
						randomSleep()
						if err := stream.Send(&pb.HelloRequest{Name: fmt.Sprintf("Ping%d", j)}); err != nil {
							errors <- fmt.Errorf("bidi send W%d-C%d: %w", workerID, i, err)
							return
						}
					}
					randomSleep()
					stream.CloseSend()
				}()

				// Receiver
				go func() {
					defer innerWg.Done()
					for {
						randomSleep()
						_, err := stream.Recv()
						if err == io.EOF {
							break
						}
						if err != nil {
							errors <- fmt.Errorf("bidi recv W%d-C%d: %w", workerID, i, err)
							return
						}
					}
				}()

				innerWg.Wait()
			}
		}(w)
	}

	// Wait with timeout
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		close(errors)
		var errList []error
		for e := range errors {
			errList = append(errList, e)
		}
		if len(errList) > 0 {
			for _, e := range errList {
				fmt.Printf("  ERROR: %v\n", e)
			}
			log.Fatalf("Stress test failed with %d errors", len(errList))
		}
		totalCalls := 4 * numWorkers * numCallsEach // 4 RPC types
		fmt.Printf("  OK: %d concurrent RPC calls completed (4 types x %d workers x %d calls)\n",
			totalCalls, numWorkers, numCallsEach)
	case <-time.After(60 * time.Second):
		log.Fatalf("TIMEOUT: Stress test deadlocked!")
	}
}

// testConcurrentBidi tests that Send and Recv can run concurrently
func testConcurrentBidi(plugin *synurang.Plugin) {
	conn := synurang.NewPluginClientConn(plugin, "GoGreeterService")
	client := pb.NewGoGreeterServiceClient(conn)

	fmt.Println("Calling BarBidiStream (concurrent send/recv)...")
	stream, err := client.BarBidiStream(context.Background())
	if err != nil {
		log.Fatalf("Failed to open stream: %v", err)
	}

	const numMessages = 5
	var wg sync.WaitGroup
	recvDone := make(chan struct{})
	sendDone := make(chan struct{})

	// Receiver goroutine
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer close(recvDone)
		received := 0
		for {
			resp, err := stream.Recv()
			if err == io.EOF {
				break
			}
			if err != nil {
				fmt.Printf("  Recv error: %v\n", err)
				return
			}
			received++
			fmt.Printf("  [Recv goroutine] Got: %s\n", resp.Message)
		}
		fmt.Printf("  [Recv goroutine] Done, received %d messages\n", received)
	}()

	// Sender goroutine
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer close(sendDone)
		for i := 0; i < numMessages; i++ {
			if err := stream.Send(&pb.HelloRequest{Name: fmt.Sprintf("Concurrent %d", i)}); err != nil {
				fmt.Printf("  Send error: %v\n", err)
				return
			}
			fmt.Printf("  [Send goroutine] Sent: Concurrent %d\n", i)
			time.Sleep(10 * time.Millisecond) // Small delay to interleave
		}
		stream.CloseSend()
		fmt.Println("  [Send goroutine] Done, closed send")
	}()

	// Wait for both goroutines with timeout
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		fmt.Println("  OK: Concurrent bidi streaming completed")
	case <-time.After(5 * time.Second):
		log.Fatalf("TIMEOUT: Concurrent bidi streaming deadlocked!")
	}
}
