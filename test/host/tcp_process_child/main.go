// TCP process child for Dart/Java process-mode tests.
//
// It reads SYNURANG_IPC and binds a TCP listener, then prints:
//   SYNURANG_PORT:<port>
// so parents can connect.
package main

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"

	"github.com/ivere27/synurang/example/go/service"
	pb "github.com/ivere27/synurang/example/pkg/api"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	"google.golang.org/grpc/health/grpc_health_v1"
)

func bindAddrFromEnv() string {
	raw := strings.TrimSpace(os.Getenv("SYNURANG_IPC"))
	if raw == "" || strings.EqualFold(raw, "tcp") {
		return "127.0.0.1:0"
	}
	if strings.HasPrefix(strings.ToLower(raw), "tcp://") {
		u, err := url.Parse(raw)
		if err == nil && u.Host != "" {
			return u.Host
		}
	}
	return "127.0.0.1:0"
}

func main() {
	ln, err := net.Listen("tcp", bindAddrFromEnv())
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen failed: %v\n", err)
		os.Exit(1)
	}

	port := ln.Addr().(*net.TCPAddr).Port
	fmt.Printf("SYNURANG_PORT:%d\n", port)

	server := grpc.NewServer()

	hs := health.NewServer()
	hs.SetServingStatus("", grpc_health_v1.HealthCheckResponse_SERVING)
	grpc_health_v1.RegisterHealthServer(server, hs)

	pb.RegisterGoGreeterServiceServer(server, service.NewGreeterServiceServerWithSource("go-process-tcp"))

	if err := server.Serve(ln); err != nil {
		fmt.Fprintf(os.Stderr, "serve failed: %v\n", err)
		os.Exit(1)
	}
}
