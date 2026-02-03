// Multi-Plugin Test Host
// Loads Go, C++, and Rust plugins and tests all 4 gRPC types with each
package main

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/ivere27/synurang/pkg/synurang"
	pb "github.com/ivere27/synurang/test/plugin/api"
)

func main() {
	plugins := []struct {
		name string
		path string
	}{
		{"Go", "bin/libplugin_go.so"},
		{"C++", "bin/libplugin_cpp.so"},
		{"Rust", "bin/libplugin_rust.so"},
	}

	fmt.Println("═══════════════════════════════════════════════════════════════")
	fmt.Println("  Multi-Plugin gRPC Test (All 4 RPC Types × 3 Languages)")
	fmt.Println("═══════════════════════════════════════════════════════════════")

	results := make(map[string]map[string]bool)

	for _, p := range plugins {
		fmt.Printf("\n▶ Loading %s plugin: %s\n", p.name, p.path)

		if _, err := os.Stat(p.path); os.IsNotExist(err) {
			fmt.Printf("  ⚠ SKIP: Plugin not found\n")
			continue
		}

		plugin, err := synurang.LoadPlugin(p.path)
		if err != nil {
			fmt.Printf("  ✗ Failed to load: %v\n", err)
			continue
		}

		results[p.name] = testPlugin(plugin, p.name)
		plugin.Close()
	}

	// Summary
	fmt.Println("\n═══════════════════════════════════════════════════════════════")
	fmt.Println("  Summary")
	fmt.Println("═══════════════════════════════════════════════════════════════")
	fmt.Printf("%-10s | %-8s | %-8s | %-8s | %-8s\n", "Language", "Unary", "Server", "Client", "Bidi")
	fmt.Println("───────────────────────────────────────────────────────────────")
	for _, lang := range []string{"Go", "C++", "Rust"} {
		if r, ok := results[lang]; ok {
			fmt.Printf("%-10s | %-8s | %-8s | %-8s | %-8s\n",
				lang,
				status(r["unary"]),
				status(r["server"]),
				status(r["client"]),
				status(r["bidi"]))
		} else {
			fmt.Printf("%-10s | %-8s | %-8s | %-8s | %-8s\n", lang, "SKIP", "SKIP", "SKIP", "SKIP")
		}
	}
}

func status(ok bool) string {
	if ok {
		return "✓ PASS"
	}
	return "✗ FAIL"
}

func testPlugin(plugin *synurang.Plugin, name string) map[string]bool {
	results := make(map[string]bool)
	ctx := context.Background()

	conn := synurang.NewPluginClientConn(plugin, "GoGreeterService")
	client := pb.NewGoGreeterServiceClient(conn)

	// Test 1: Unary RPC
	fmt.Printf("  [1/4] Unary RPC... ")
	resp, err := client.Bar(ctx, &pb.HelloRequest{Name: "Test"})
	if err != nil {
		fmt.Printf("✗ %v\n", err)
		results["unary"] = false
	} else {
		fmt.Printf("✓ %s (from: %s)\n", resp.Message, resp.From)
		results["unary"] = true
	}

	// Test 2: Server Streaming
	fmt.Printf("  [2/4] Server Streaming... ")
	stream, err := client.BarServerStream(ctx, &pb.HelloRequest{Name: "Stream"})
	if err != nil {
		fmt.Printf("✗ %v\n", err)
		results["server"] = false
	} else {
		count := 0
		for {
			_, err := stream.Recv()
			if err == io.EOF {
				break
			}
			if err != nil {
				fmt.Printf("✗ recv: %v\n", err)
				break
			}
			count++
		}
		fmt.Printf("✓ received %d messages\n", count)
		results["server"] = count > 0
	}

	// Test 3: Client Streaming
	fmt.Printf("  [3/4] Client Streaming... ")
	clientStream, err := client.BarClientStream(ctx)
	if err != nil {
		fmt.Printf("✗ %v\n", err)
		results["client"] = false
	} else {
		for i := 0; i < 3; i++ {
			clientStream.Send(&pb.HelloRequest{Name: fmt.Sprintf("Msg%d", i)})
		}
		resp, err := clientStream.CloseAndRecv()
		if err != nil {
			fmt.Printf("✗ %v\n", err)
			results["client"] = false
		} else {
			fmt.Printf("✓ %s\n", resp.Message)
			results["client"] = true
		}
	}

	// Test 4: Bidirectional Streaming
	fmt.Printf("  [4/4] Bidi Streaming... ")
	bidiStream, err := client.BarBidiStream(ctx)
	if err != nil {
		fmt.Printf("✗ %v\n", err)
		results["bidi"] = false
	} else {
		go func() {
			for i := 0; i < 3; i++ {
				bidiStream.Send(&pb.HelloRequest{Name: fmt.Sprintf("Ping%d", i)})
			}
			bidiStream.CloseSend()
		}()

		count := 0
		for {
			_, err := bidiStream.Recv()
			if err == io.EOF {
				break
			}
			if err != nil {
				break
			}
			count++
		}
		fmt.Printf("✓ echoed %d messages\n", count)
		results["bidi"] = count > 0
	}

	return results
}
