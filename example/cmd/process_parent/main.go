package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"time"

	pb "github.com/ivere27/synurang/example/pkg/api"
	"github.com/ivere27/synurang/pkg/synurang"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health/grpc_health_v1"
)

func main() {
	childPath := flag.String("child", "", "Path to child process binary")
	flag.Parse()

	if *childPath == "" {
		log.Fatal("Usage: process_parent --child=./path/to/child")
	}

	log.Printf("Starting child process: %s", *childPath)
	cmd := exec.Command(*childPath)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	
	// StartProcess handles the IPC channel setup
	// On Unix: socketpair + fd inheritance
	// On Windows: named pipes
	ctx := context.Background()
	conn, err := synurang.StartProcess(ctx, cmd, grpc.WithBlock())
	if err != nil {
		log.Fatalf("StartProcess failed: %v", err)
	}
	// Ensure child is cleaned up when we exit
	defer func() {
		conn.Close()
		if cmd.Process != nil {
			cmd.Process.Kill()
		}
	}()

	log.Println("Connected to child process!")
	
	// Verify Health
	healthClient := grpc_health_v1.NewHealthClient(conn)
	hResp, err := healthClient.Check(ctx, &grpc_health_v1.HealthCheckRequest{})
	if err != nil {
		log.Fatalf("Health check failed: %v", err)
	}
	log.Printf("Child Health: %s", hResp.Status)

	// Create Greeter Client
	client := pb.NewGoGreeterServiceClient(conn)

	// 1. Unary RPC
	log.Println("\n=== 1. Unary RPC ===")
	uResp, err := client.Bar(ctx, &pb.HelloRequest{Name: "Parent"})
	if err != nil {
		log.Fatalf("Unary failed: %v", err)
	}
	log.Printf("Unary Response: %s", uResp.Message)

	// 2. Server Streaming
	log.Println("\n=== 2. Server Streaming ===")
	sStream, err := client.BarServerStream(ctx, &pb.HelloRequest{Name: "Streamer"})
	if err != nil {
		log.Fatalf("ServerStream failed: %v", err)
	}
	for {
		msg, err := sStream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			log.Fatalf("Recv failed: %v", err)
		}
		log.Printf("Received: %s", msg.Message)
	}

	// 3. Client Streaming
	log.Println("\n=== 3. Client Streaming ===")
	cStream, err := client.BarClientStream(ctx)
	if err != nil {
		log.Fatalf("ClientStream failed: %v", err)
	}
	for i := 0; i < 3; i++ {
		log.Printf("Sending: Msg %d", i)
		if err := cStream.Send(&pb.HelloRequest{Name: fmt.Sprintf("Msg %d", i)}); err != nil {
			log.Fatalf("Send failed: %v", err)
		}
	}
	cResp, err := cStream.CloseAndRecv()
	if err != nil {
		log.Fatalf("CloseAndRecv failed: %v", err)
	}
	log.Printf("ClientStream Response: %s", cResp.Message)

	// 4. Bidi Streaming
	log.Println("\n=== 4. Bidi Streaming ===")
	bStream, err := client.BarBidiStream(ctx)
	if err != nil {
		log.Fatalf("BidiStream failed: %v", err)
	}
	
	waitc := make(chan struct{})
	go func() {
		for {
			msg, err := bStream.Recv()
			if err == io.EOF {
				close(waitc)
				return
			}
			if err != nil {
				log.Fatalf("Bidi Recv failed: %v", err)
			}
			log.Printf("Bidi Recv: %s", msg.Message)
		}
	}()

	for i := 0; i < 3; i++ {
		log.Printf("Bidi Send: Ping %d", i)
		if err := bStream.Send(&pb.HelloRequest{Name: fmt.Sprintf("Ping %d", i)}); err != nil {
			log.Fatalf("Bidi Send failed: %v", err)
		}
		time.Sleep(100 * time.Millisecond) // Simulate work
	}
	bStream.CloseSend()
	<-waitc

	log.Println("\nAll RPC examples completed successfully!")
}
