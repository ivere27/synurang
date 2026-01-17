// Go CLI tool to test Flutter and Go gRPC servers over UDS/TCP
//
// Usage:
//   go run main.go --target=flutter --transport=tcp --port=10050
//   go run main.go --target=flutter --transport=uds --socket=/tmp/flutter_view.sock
//   go run main.go --target=go --transport=tcp --port=18000
//   go run main.go --target=go --transport=uds --socket=/tmp/go_engine.sock

package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"time"

	example_pb "synurang/example/pkg/api"
	core_pb "synurang/pkg/api"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/types/known/emptypb"
)

var (
	target    = flag.String("target", "go", "Target server: 'go' (EngineService) or 'flutter' (DartGreeterService)")
	transport = flag.String("transport", "tcp", "Transport: 'tcp' or 'uds'")
	addr      = flag.String("addr", "localhost:18000", "TCP address (used when transport=tcp)")
	socket    = flag.String("socket", "/tmp/synurang.sock", "UDS socket path (used when transport=uds)")
	token     = flag.String("token", "demo-token", "Auth token")
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	flag.Parse()

	fmt.Println("╔════════════════════════════════════════════════════════════════╗")
	fmt.Println("║         Synurang Transport Test CLI                            ║")
	fmt.Println("╚════════════════════════════════════════════════════════════════╝")
	fmt.Println()

	// Build connection options
	options := []grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	}

	dialAddr := *addr
	if *transport == "uds" {
		dialAddr = *socket
		options = append(options, grpc.WithContextDialer(func(ctx context.Context, addr string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", addr)
		}))
	}

	fmt.Printf("Target: %s\n", *target)
	fmt.Printf("Transport: %s\n", *transport)
	fmt.Printf("Address: %s\n", dialAddr)
	fmt.Printf("Token: %s\n", *token)
	fmt.Println()

	// Connect
	conn, err := grpc.Dial(dialAddr, options...)
	if err != nil {
		log.Fatalf("Failed to connect: %v", err)
	}
	defer conn.Close()

	// Create context with auth token
	ctx, cancel := context.WithTimeout(
		metadata.NewOutgoingContext(
			context.Background(),
			metadata.New(map[string]string{"authorization": "Bearer " + *token}),
		),
		time.Second*10,
	)
	defer cancel()

	start := time.Now()

	switch *target {
	case "go":
		testGoServer(ctx, conn)
	case "flutter":
		testFlutterServer(ctx, conn)
	default:
		log.Fatalf("Unknown target: %s (use 'go' or 'flutter')", *target)
	}

	fmt.Printf("\n✅ Tests completed in %v\n", time.Since(start))
}

func testGoServer(ctx context.Context, conn *grpc.ClientConn) {
	fmt.Println("┌─ Testing Go Server (EngineService) ───────────────────────────")

	// Test Health via core HealthService
	healthClient := core_pb.NewHealthServiceClient(conn)
	pingResp, err := healthClient.Ping(ctx, &emptypb.Empty{})
	if err != nil {
		log.Printf("│  ✗ Ping failed: %v", err)
	} else {
		fmt.Printf("│  ✓ Ping: version=%s\n", pingResp.Version)
	}

	// Test GoGreeterService
	greeterClient := example_pb.NewGoGreeterServiceClient(conn)

	// Unary RPC
	barResp, err := greeterClient.Bar(ctx, &example_pb.HelloRequest{
		Name:     "CLI-Test",
		Language: "en",
	})
	if err != nil {
		log.Printf("│  ✗ Bar failed: %v", err)
	} else {
		fmt.Printf("│  ✓ Bar: %s (from: %s)\n", barResp.Message, barResp.From)
	}

	// Server Streaming
	fmt.Println("│  Testing ServerStream...")
	stream, err := greeterClient.BarServerStream(ctx, &example_pb.HelloRequest{Name: "CLI"})
	if err != nil {
		log.Printf("│  ✗ BarServerStream failed: %v", err)
	} else {
		count := 0
		for {
			resp, err := stream.Recv()
			if err != nil {
				break
			}
			count++
			fmt.Printf("│    [%d] %s\n", count, resp.Message)
		}
		fmt.Printf("│  ✓ Received %d stream messages\n", count)
	}

	fmt.Println("└───────────────────────────────────────────────────────────────")
}

func testFlutterServer(ctx context.Context, conn *grpc.ClientConn) {
	fmt.Println("┌─ Testing Flutter Server (DartGreeterService) ─────────────────")

	// Test DartGreeterService
	greeterClient := example_pb.NewDartGreeterServiceClient(conn)

	// Unary RPC
	fooResp, err := greeterClient.Foo(ctx, &example_pb.HelloRequest{
		Name:     "CLI-Test",
		Language: "en",
	})
	if err != nil {
		log.Printf("│  ✗ Foo failed: %v", err)
	} else {
		fmt.Printf("│  ✓ Foo: %s (from: %s)\n", fooResp.Message, fooResp.From)
	}

	// Server Streaming
	fmt.Println("│  Testing FooServerStream...")
	stream, err := greeterClient.FooServerStream(ctx, &example_pb.HelloRequest{Name: "CLI"})
	if err != nil {
		log.Printf("│  ✗ FooServerStream failed: %v", err)
	} else {
		count := 0
		for {
			resp, err := stream.Recv()
			if err != nil {
				break
			}
			count++
			fmt.Printf("│    [%d] %s\n", count, resp.Message)
		}
		fmt.Printf("│  ✓ Received %d stream messages\n", count)
	}

	fmt.Println("└───────────────────────────────────────────────────────────────")
}
