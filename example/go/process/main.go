// Process mode entry point - gRPC server over IPC
package main

import (
	"log"
	"net"

	"github.com/ivere27/synurang/example/go/service"
	pb "github.com/ivere27/synurang/example/pkg/api"
	"github.com/ivere27/synurang/pkg/synurang"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	"google.golang.org/grpc/health/grpc_health_v1"
)

func main() {
	ln, err := synurang.NewIPCListener()
	if err != nil {
		log.Fatalf("NewIPCListener failed: %v", err)
	}

	server := grpc.NewServer()

	// Register health service
	hs := health.NewServer()
	hs.SetServingStatus("", grpc_health_v1.HealthCheckResponse_SERVING)
	grpc_health_v1.RegisterHealthServer(server, hs)

	// Register greeter service using shared implementation
	pb.RegisterGoGreeterServiceServer(server, service.NewGreeterServiceServerWithSource("go-process"))

	log.Println("Go process child: serving gRPC over IPC...")
	if err := server.Serve(ln); err != nil && err != net.ErrClosed {
		log.Fatalf("Serve failed: %v", err)
	}
}
