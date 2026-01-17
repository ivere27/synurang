package service

import "time"

// Config holds server configuration
type Config struct {
	EngineSocketPath string        // UDS path for engine gRPC server
	EngineTcpPort    string        // TCP port for engine gRPC server
	ViewSocketPath   string        // UDS path for Dart gRPC server
	ViewTcpPort      string        // TCP port for Dart gRPC server
	Token            string        // JWT token for authentication
	CachePath        string        // Path to cache directory
	EnableCache      bool          // Enable cache service (requires SQLite)
	StreamTimeout    time.Duration // Timeout for streaming RPCs
}

// DartCallback is the function signature for calling Dart from Go
var DartCallback func(method string, data []byte) ([]byte, error)
