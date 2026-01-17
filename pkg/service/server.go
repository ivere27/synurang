package service

import (
	"context"
	"crypto/subtle"
	"fmt"
	"log"
	"sync"
	"time"

	pb "github.com/ivere27/synurang/pkg/api"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

// ServiceRegistrar allows registering custom services
type ServiceRegistrar func(*grpc.Server, *CoreServiceServer)

// MessageFactory creates a new instance of a proto message
type MessageFactory func() proto.Message

// CoreServiceServer implements all gRPC services
type CoreServiceServer struct {
	pb.UnimplementedHealthServiceServer
	*CacheServiceServer
	cfg      *Config
	mu       sync.RWMutex
	dartConn *grpc.ClientConn // gRPC client to Dart (for UDS/TCP mode)
}

// NewCoreService creates a new CoreServiceServer
func NewCoreService(cfg *Config) *CoreServiceServer {
	s := &CoreServiceServer{cfg: cfg}

	// Only initialize cache if enabled AND cachePath is provided
	if cfg.EnableCache && cfg.CachePath != "" {
		cache, err := NewCacheService(cfg.CachePath)
		if err != nil {
			log.Printf("Warning: Failed to initialize cache service: %v", err)
		} else {
			s.CacheServiceServer = cache
		}
	}

	// Initialize gRPC client to Dart/Flutter server (for UDS/TCP mode)
	if cfg.ViewSocketPath != "" {
		conn, err := grpc.Dial(
			"unix://"+cfg.ViewSocketPath,
			grpc.WithTransportCredentials(insecure.NewCredentials()),
		)
		if err != nil {
			log.Printf("Warning: Failed to connect to Flutter server via UDS: %v", err)
		} else {
			s.dartConn = conn
			log.Printf("Connected to Flutter gRPC server via UDS: %s", cfg.ViewSocketPath)
		}
	} else if cfg.ViewTcpPort != "" {
		conn, err := grpc.Dial(
			"localhost:"+cfg.ViewTcpPort,
			grpc.WithTransportCredentials(insecure.NewCredentials()),
		)
		if err != nil {
			log.Printf("Warning: Failed to connect to Flutter server via TCP: %v", err)
		} else {
			s.dartConn = conn
			log.Printf("Connected to Flutter gRPC server via TCP: localhost:%s", cfg.ViewTcpPort)
		}
	}

	return s
}

// Close cleans up server resources
func (s *CoreServiceServer) Close() {
	log.Println("CoreServiceServer closing...")
	if s.dartConn != nil {
		s.dartConn.Close()
	}
	if s.CacheServiceServer != nil {
		s.CacheServiceServer.Close()
	}
}

// NewGrpcServer creates a new gRPC server with interceptors and registers services
func NewGrpcServer(s *CoreServiceServer, cfg *Config, registrars ...ServiceRegistrar) *grpc.Server {
	opts := []grpc.ServerOption{
		grpc.UnaryInterceptor(s.authInterceptor),
		grpc.StreamInterceptor(s.streamAuthInterceptor),
	}

	srv := grpc.NewServer(opts...)

	// Register Core Services
	pb.RegisterHealthServiceServer(srv, s)

	// Conditionally register cache service
	if s.CacheServiceServer != nil {
		pb.RegisterCacheServiceServer(srv, s)
	}

	// Register Custom Services
	for _, r := range registrars {
		r(srv, s)
	}

	return srv
}

// authInterceptor validates the token in metadata
func (s *CoreServiceServer) authInterceptor(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
	if s.cfg.Token == "" {
		return handler(ctx, req)
	}

	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "missing metadata")
	}

	tokens := md.Get("authorization")
	if len(tokens) == 0 {
		return nil, status.Error(codes.Unauthenticated, "missing token")
	}

	if subtle.ConstantTimeCompare([]byte(tokens[0]), []byte("Bearer "+s.cfg.Token)) != 1 {
		return nil, status.Error(codes.Unauthenticated, "invalid token")
	}

	return handler(ctx, req)
}

// streamAuthInterceptor validates the token for streaming RPCs
func (s *CoreServiceServer) streamAuthInterceptor(srv interface{}, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
	if s.cfg.Token == "" {
		return handler(srv, ss)
	}

	md, ok := metadata.FromIncomingContext(ss.Context())
	if !ok {
		return status.Error(codes.Unauthenticated, "missing metadata")
	}

	tokens := md.Get("authorization")
	if len(tokens) == 0 {
		return status.Error(codes.Unauthenticated, "missing token")
	}

	if subtle.ConstantTimeCompare([]byte(tokens[0]), []byte("Bearer "+s.cfg.Token)) != 1 {
		return status.Error(codes.Unauthenticated, "invalid token")
	}

	return handler(srv, ss)
}

// DartConn returns the gRPC client connection to Dart (nil if not connected)
func (s *CoreServiceServer) DartConn() *grpc.ClientConn {
	return s.dartConn
}

// InvokeDart calls a Dart method via gRPC (UDS/TCP) or FFI callback
func (s *CoreServiceServer) InvokeDart(method string, req proto.Message, resp proto.Message) error {
	// Use gRPC client if available (UDS/TCP mode)
	if s.dartConn != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		// Add auth metadata if configured
		if s.cfg.Token != "" {
			ctx = metadata.NewOutgoingContext(ctx, metadata.New(map[string]string{
				"authorization": "Bearer " + s.cfg.Token,
			}))
		}

		// Use gRPC invoke directly with proto.Message
		err := s.dartConn.Invoke(ctx, method, req, resp)
		if err != nil {
			return fmt.Errorf("grpc invoke failed: %w", err)
		}
		return nil
	}

	// Fallback to FFI callback
	if DartCallback == nil {
		return fmt.Errorf("dart callback not registered")
	}

	reqBytes, err := proto.Marshal(req)
	if err != nil {
		return fmt.Errorf("failed to marshal request: %w", err)
	}

	respBytes, err := DartCallback(method, reqBytes)
	if err != nil {
		return fmt.Errorf("dart callback failed: %w", err)
	}

	if err := proto.Unmarshal(respBytes, resp); err != nil {
		return fmt.Errorf("failed to unmarshal response: %w", err)
	}

	return nil
}

// InvokeDartStream calls a Dart streaming method
func (s *CoreServiceServer) InvokeDartStream(method string, req proto.Message, factory MessageFactory) ([]proto.Message, error) {
	// Use gRPC client if available (UDS/TCP mode)
	if s.dartConn != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		// Add auth metadata if configured
		if s.cfg.Token != "" {
			ctx = metadata.NewOutgoingContext(ctx, metadata.New(map[string]string{
				"authorization": "Bearer " + s.cfg.Token,
			}))
		}

		// Create a streaming client descriptor
		streamDesc := &grpc.StreamDesc{
			StreamName:    method,
			ServerStreams: true,
		}

		stream, err := s.dartConn.NewStream(ctx, streamDesc, method)
		if err != nil {
			return nil, fmt.Errorf("failed to create stream: %w", err)
		}

		// Send the request
		if err := stream.SendMsg(req); err != nil {
			return nil, fmt.Errorf("failed to send request: %w", err)
		}
		if err := stream.CloseSend(); err != nil {
			return nil, fmt.Errorf("failed to close send: %w", err)
		}

		// Receive responses
		var responses []proto.Message
		for {
			resp := factory()
			if err := stream.RecvMsg(resp); err != nil {
				if err.Error() == "EOF" {
					break
				}
				// Check for gRPC EOF
				if status.Code(err) == codes.OK {
					break
				}
				return nil, fmt.Errorf("failed to receive: %w", err)
			}
			responses = append(responses, resp)
		}

		return responses, nil
	}

	// Fallback to FFI callback mechanism
	if DartCallback == nil {
		return nil, fmt.Errorf("dart callback not registered")
	}

	// 1. Create a stream session to receive data from Dart
	session := NewStreamSession(method, StreamTypeServerStream)
	defer func() {
		// We don't defer CloseStreamSession here because we need it open to receive data.
		// It will be closed by Dart (via FFI CloseStream) or by us when we are done.
	}()

	// 2. Append session ID to method so Dart knows where to send data
	methodWithId := fmt.Sprintf("%s:%d", method, session.ID)

	reqBytes, err := proto.Marshal(req)
	if err != nil {
		CloseStreamSession(session.ID)
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	// 3. Invoke Dart (Unary call to start the stream)
	_, err = DartCallback(methodWithId, reqBytes)
	if err != nil {
		CloseStreamSession(session.ID)
		return nil, fmt.Errorf("dart callback failed: %w", err)
	}

	// 4. Collect responses from DataChan
	var responses []proto.Message

	// Wait for data
	var timeoutChan <-chan time.Time
	if s.cfg.StreamTimeout > 0 {
		timeoutChan = time.After(s.cfg.StreamTimeout)
	}

	for {
		select {
		case data, ok := <-session.DataChan:
			if !ok {
				// Channel closed by CloseStreamSession (triggered by Dart CloseStream)
				return responses, nil
			}

			resp := factory()
			if err := proto.Unmarshal(data, resp); err != nil {
				log.Printf("Error unmarshaling stream response: %v", err)
				continue
			}
			responses = append(responses, resp)

		case <-session.DoneChan:
			// Session ended
			return responses, nil

		case <-timeoutChan:
			CloseStreamSession(session.ID)
			return nil, fmt.Errorf("timeout waiting for stream data")
		}
	}
}

// InvokeDartClientStream calls a Dart client streaming method
func (s *CoreServiceServer) InvokeDartClientStream(method string, reqs []proto.Message, respFactory MessageFactory) (proto.Message, error) {
	if DartCallback == nil {
		return nil, fmt.Errorf("dart callback not registered")
	}

	session := NewStreamSession(method, StreamTypeBidiStream)
	defer CloseStreamSession(session.ID)

	methodWithId := fmt.Sprintf("%s:%d", method, session.ID)

	// Send initial request (empty or first?)
	_, err := DartCallback(methodWithId, []byte{})
	if err != nil {
		return nil, fmt.Errorf("dart callback failed: %w", err)
	}

	// Send requests
	for i, req := range reqs {
		reqBytes, _ := proto.Marshal(req)
		if err := session.SendFromStream(reqBytes); err != nil {
			return nil, fmt.Errorf("failed to send stream data %d: %w", i, err)
		}
	}
	session.CloseSend() // Signal Go -> Dart EOF

	// Wait for single response from Dart
	var timeoutChan <-chan time.Time
	if s.cfg.StreamTimeout > 0 {
		timeoutChan = time.After(s.cfg.StreamTimeout)
	}

	select {
	case data, ok := <-session.DataChan:
		if !ok {
			return nil, fmt.Errorf("stream closed without response")
		}
		resp := respFactory()
		if err := proto.Unmarshal(data, resp); err != nil {
			return nil, fmt.Errorf("failed to unmarshal response: %w", err)
		}
		return resp, nil
	case <-timeoutChan:
		return nil, fmt.Errorf("timeout waiting for response")
	}
}

// InvokeDartBidiStream calls a Dart bidirectional streaming method
func (s *CoreServiceServer) InvokeDartBidiStream(method string, reqs []proto.Message, respFactory MessageFactory) ([]proto.Message, error) {
	if DartCallback == nil {
		return nil, fmt.Errorf("dart callback not registered")
	}

	session := NewStreamSession(method, StreamTypeBidiStream)

	methodWithId := fmt.Sprintf("%s:%d", method, session.ID)

	_, err := DartCallback(methodWithId, []byte{})
	if err != nil {
		CloseStreamSession(session.ID)
		return nil, fmt.Errorf("dart callback failed: %w", err)
	}

	var responses []proto.Message
	var respErr error
	var wg sync.WaitGroup

	// Reader routine
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case data, ok := <-session.DataChan:
				if !ok {
					return
				}
				resp := respFactory()
				if err := proto.Unmarshal(data, resp); err != nil {
					log.Printf("Bidi unmarshal error: %v", err)
					continue
				}
				responses = append(responses, resp)
			case <-session.DoneChan:
				return
			}
		}
	}()

	// Sender routine
	for i, req := range reqs {
		reqBytes, _ := proto.Marshal(req)
		if err := session.SendFromStream(reqBytes); err != nil {
			respErr = fmt.Errorf("failed to send bidi data %d: %w", i, err)
			break
		}
	}
	session.CloseSend()

	// Wait for completion
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	var timeoutChan <-chan time.Time
	if s.cfg.StreamTimeout > 0 {
		timeoutChan = time.After(s.cfg.StreamTimeout)
	}

	select {
	case <-done:
		// success
	case <-timeoutChan:
		CloseStreamSession(session.ID)
		respErr = fmt.Errorf("timeout waiting for bidi completion")
	}

	return responses, respErr
}
