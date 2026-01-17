package main

/*
#include <stdlib.h>

// Server startup arguments
struct CoreArgument {
    char* storagePath;
    char* cachePath;
    char* engineSocketPath;
    char* engineTcpPort;
    char* viewSocketPath;
    char* viewTcpPort;
    char* token;
    int enableCache;
    long long streamTimeout;
};

// FFI data structure for returning bytes
typedef struct {
    void* data;
    long long len;
} FfiData;

// Dart callback signature
typedef void (*InvokeDartCallback)(long long requestId, char* method, void* data, long long len);

static void invoke_dart_callback(InvokeDartCallback cb, long long requestId, char* method, void* data, long long len) {
    if (cb) {
        cb(requestId, method, data, len);
    }
}

// Stream callback signature (for server/bidi streaming)
typedef void (*StreamCallback)(long long streamId, char msgType, void* data, long long len);

static void invoke_stream_callback(StreamCallback cb, long long streamId, char msgType, void* data, long long len) {
    if (cb) {
        cb(streamId, msgType, data, len);
    }
}
*/
import "C"

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	goruntime "runtime"
	"runtime/debug"
	"sync"
	"syscall"
	"time"
	"unsafe"

	pb "synurang/pkg/api"
	"synurang/pkg/service"

	"google.golang.org/grpc"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

var (
	commitHash string
	commitDate string
	buildDate  string
)

var (
	srv          *grpc.Server
	impl         *service.CoreServiceServer
	implMu       sync.RWMutex
	listeners    []net.Listener
	serverErrors chan error
	sigChan      = make(chan os.Signal, 1)
	dartCallback C.InvokeDartCallback

	// Stream callback for server/bidi streaming
	streamCallback C.StreamCallback
)

func init() {
	log.SetFlags(log.Ldate | log.Ltime)
	log.Printf("Synurang - Commit: %s, Date: %s, Build: %s\n", commitHash, commitDate, buildDate)

	flag.String("golang-port", "18000", "Go gRPC server TCP port")
	flag.String("golang-socket", "/tmp/synurang.sock", "Go gRPC server UDS socket path")
	flag.String("flutter-port", "", "Flutter gRPC server TCP port (for bidirectional communication)")
	flag.String("flutter-socket", "", "Flutter gRPC server UDS socket path (for bidirectional communication)")
	flag.String("token", "jwttoken", "auth token")
}

// =============================================================================
// FFI Exports - Server Lifecycle
// =============================================================================

//export StartGrpcServer
func StartGrpcServer(cArg C.struct_CoreArgument) C.int {
	log.Println("Synurang - StartGrpcServer called")
	if srv != nil {
		log.Println("Synurang - already started")
		return -1
	}

	cfg := &service.Config{}

	if unsafe.Pointer(cArg.storagePath) != nil {
		cfg.EngineSocketPath = C.GoString(cArg.storagePath)
	}
	if unsafe.Pointer(cArg.cachePath) != nil {
		cfg.CachePath = C.GoString(cArg.cachePath)
	}
	// Enable cache only if path is provided AND explicitly enabled
	// The caller (Dart) passes 1 for enabled, 0 for disabled
	if cfg.CachePath != "" && cArg.enableCache == 1 {
		cfg.EnableCache = true
	} else {
		cfg.EnableCache = false
	}

	// Stream timeout (ms). 0 means unlimited.
	cfg.StreamTimeout = time.Duration(cArg.streamTimeout) * time.Millisecond

	if unsafe.Pointer(cArg.engineSocketPath) != nil {
		cfg.EngineSocketPath = C.GoString(cArg.engineSocketPath)
	}
	if unsafe.Pointer(cArg.engineTcpPort) != nil {
		cfg.EngineTcpPort = C.GoString(cArg.engineTcpPort)
	}
	if unsafe.Pointer(cArg.viewSocketPath) != nil {
		cfg.ViewSocketPath = C.GoString(cArg.viewSocketPath)
	}
	if unsafe.Pointer(cArg.viewTcpPort) != nil {
		cfg.ViewTcpPort = C.GoString(cArg.viewTcpPort)
	}
	if unsafe.Pointer(cArg.token) != nil {
		cfg.Token = C.GoString(cArg.token)
	}

	// Set the global default stream timeout for FFI callbacks
	service.SetDefaultStreamTimeout(cfg.StreamTimeout)

	listeners = make([]net.Listener, 0)
	var listenersMu sync.Mutex
	var wg sync.WaitGroup

	// UDS listener
	if cfg.EngineSocketPath != "" {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := os.Stat(cfg.EngineSocketPath); err == nil {
				os.Remove(cfg.EngineSocketPath)
			}
			udsListen, err := net.Listen("unix", cfg.EngineSocketPath)
			if err != nil {
				log.Printf("Failed to listen on UDS: %v", err)
			} else {
				listenersMu.Lock()
				listeners = append(listeners, udsListen)
				listenersMu.Unlock()
			}
		}()
	}

	// TCP listener
	if cfg.EngineTcpPort != "" {
		wg.Add(1)
		go func() {
			defer wg.Done()
			tcpListen, err := net.Listen("tcp", ":"+cfg.EngineTcpPort)
			if err != nil {
				log.Printf("Failed to listen on TCP: %v", err)
			} else {
				listenersMu.Lock()
				listeners = append(listeners, tcpListen)
				listenersMu.Unlock()
			}
		}()
	}

	wg.Wait()

	// Initialize server
	serviceImpl := service.NewCoreService(cfg)
	s := service.NewGrpcServer(serviceImpl, cfg)

	srv = s
	implMu.Lock()
	impl = serviceImpl
	implMu.Unlock()

	// Start serving
	serverErrors = make(chan error, 1)
	if len(listeners) > 0 {
		go func() {
			for _, listener := range listeners {
				go func(l net.Listener) {
					log.Printf("Synurang - Serving on %s", l.Addr().String())
					if err := srv.Serve(l); err != nil {
						log.Printf("Server error: %v", err)
						serverErrors <- err
					}
				}(listener)
			}
		}()
	} else {
		log.Println("Synurang - Running in FFI-only mode")
	}

	return 0
}

//export StopGrpcServer
func StopGrpcServer() C.int {
	log.Printf("Synurang - StopGrpcServer called (goroutines: %d)", goruntime.NumGoroutine())
	if srv != nil {
		implMu.Lock()
		if impl != nil {
			impl.Close()
			impl = nil
		}
		implMu.Unlock()

		srv.Stop()

		for _, listener := range listeners {
			listener.Close()
			if addr := listener.Addr(); addr.Network() == "unix" {
				os.Remove(addr.String())
			}
		}
		srv = nil
		listeners = nil

		goruntime.GC()
		debug.FreeOSMemory()
	}
	log.Printf("Synurang - StopGrpcServer finished (goroutines: %d)", goruntime.NumGoroutine())
	return 0
}

// =============================================================================
// FFI Exports - Backend Invocation (Dart -> Go)
// =============================================================================

//export InvokeBackend
func InvokeBackend(method *C.char, data unsafe.Pointer, dataLen C.longlong) C.FfiData {
	implMu.RLock()
	localImpl := impl
	implMu.RUnlock()

	if localImpl == nil {
		errStr := "Server implementation not initialized"
		cErr := C.CBytes([]byte(errStr))
		return C.FfiData{
			data: cErr,
			len:  C.longlong(-len(errStr)),
		}
	}

	goMethod := C.GoString(method)
	goData := unsafe.Slice((*byte)(data), int(dataLen))

	// Zero-copy: InvokeFfi allocates C memory and serializes directly
	cPtr, size, err := pb.InvokeFfi(localImpl, context.Background(), goMethod, goData)

	if err != nil {
		log.Printf("Invoke error: %v", err)
		st, ok := status.FromError(err)
		var pbErr *pb.Error
		if ok {
			for _, detail := range st.Details() {
				if e, ok := detail.(*pb.Error); ok {
					pbErr = e
					break
				}
			}
		}
		if pbErr == nil {
			pbErr = &pb.Error{
				Message:  err.Error(),
				GrpcCode: int32(st.Code()),
			}
		}
		errBytes, _ := proto.Marshal(pbErr)
		cErr := C.CBytes(errBytes)
		return C.FfiData{
			data: cErr,
			len:  C.longlong(-len(errBytes)),
		}
	}

	return C.FfiData{
		data: cPtr,
		len:  C.longlong(size),
	}
}

// parseMetadata parses "key=value\n" metadata format and extracts timeout if present.
// Returns metadata map and timeout in milliseconds (0 = no timeout).
func parseMetadata(metaData []byte) (map[string]string, int64) {
	if len(metaData) == 0 {
		return nil, 0
	}
	meta := make(map[string]string)
	var timeoutMs int64
	for _, line := range splitLines(metaData) {
		if len(line) == 0 {
			continue
		}
		idx := indexOf(line, '=')
		if idx > 0 {
			key := string(line[:idx])
			value := string(line[idx+1:])
			if key == "__timeout_ms" {
				fmt.Sscanf(value, "%d", &timeoutMs)
			} else {
				meta[key] = value
			}
		}
	}
	return meta, timeoutMs
}

func splitLines(data []byte) [][]byte {
	var lines [][]byte
	start := 0
	for i, b := range data {
		if b == '\n' {
			lines = append(lines, data[start:i])
			start = i + 1
		}
	}
	if start < len(data) {
		lines = append(lines, data[start:])
	}
	return lines
}

func indexOf(data []byte, ch byte) int {
	for i, b := range data {
		if b == ch {
			return i
		}
	}
	return -1
}

//export InvokeBackendWithMeta
func InvokeBackendWithMeta(method *C.char, data unsafe.Pointer, dataLen C.longlong,
	metaData unsafe.Pointer, metaLen C.longlong) C.FfiData {

	implMu.RLock()
	localImpl := impl
	implMu.RUnlock()

	if localImpl == nil {
		errStr := "Server implementation not initialized"
		cErr := C.CBytes([]byte(errStr))
		return C.FfiData{data: cErr, len: C.longlong(-len(errStr))}
	}

	goMethod := C.GoString(method)
	goData := unsafe.Slice((*byte)(data), int(dataLen))

	// Parse metadata and timeout
	var goMeta []byte
	if metaLen > 0 {
		goMeta = unsafe.Slice((*byte)(metaData), int(metaLen))
	}
	metadata, timeoutMs := parseMetadata(goMeta)

	// Create context with optional timeout
	ctx := context.Background()
	if timeoutMs > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(timeoutMs)*time.Millisecond)
		defer cancel()
	}

	// Metadata available in 'metadata' map for handlers that need it
	_ = metadata

	// Zero-copy: InvokeFfi allocates C memory and serializes directly
	cPtr, size, err := pb.InvokeFfi(localImpl, ctx, goMethod, goData)

	if err != nil {
		st, ok := status.FromError(err)
		var pbErr *pb.Error
		if ok {
			for _, detail := range st.Details() {
				if e, ok := detail.(*pb.Error); ok {
					pbErr = e
					break
				}
			}
		}
		if pbErr == nil {
			pbErr = &pb.Error{
				Message:  err.Error(),
				GrpcCode: int32(st.Code()),
			}
		}
		errBytes, _ := proto.Marshal(pbErr)
		cErr := C.CBytes(errBytes)
		return C.FfiData{data: cErr, len: C.longlong(-len(errBytes))}
	}

	return C.FfiData{data: cPtr, len: C.longlong(size)}
}

//export FreeFfiData
func FreeFfiData(data unsafe.Pointer) {
	if data != nil {
		C.free(data)
	}
}

// =============================================================================
// FFI Exports - Dart Callback (Go -> Dart)
// =============================================================================

//export RegisterDartCallback
func RegisterDartCallback(callback C.InvokeDartCallback) {
	log.Printf("RegisterDartCallback called")

	// Cleanup pending requests from previous callback (hot-reload support)
	service.DefaultRequestHandler.CleanupPending()

	dartCallback = callback
	service.DartCallback = func(method string, data []byte) ([]byte, error) {
		if dartCallback == nil {
			return nil, fmt.Errorf("dart callback is nil")
		}

		requestId, ch := service.DefaultRequestHandler.CreateRequest()

		cMethod := C.CString(method)
		defer C.free(unsafe.Pointer(cMethod))

		cData := C.CBytes(data)
		defer C.free(cData)

		C.invoke_dart_callback(dartCallback, C.longlong(requestId), cMethod, cData, C.longlong(len(data)))

		return service.DefaultRequestHandler.WaitForResponse(requestId, ch)
	}
}

//export SendFfiResponse
func SendFfiResponse(requestId C.longlong, data unsafe.Pointer, dataLen C.longlong) {
	goData := C.GoBytes(data, C.int(dataLen))
	service.DefaultRequestHandler.HandleResponse(int64(requestId), goData)
}

// =============================================================================
// FFI Exports - Streaming Support
// =============================================================================

//export RegisterStreamCallback
func RegisterStreamCallback(callback C.StreamCallback) {
	log.Println("RegisterStreamCallback called")
	streamCallback = callback

	// Register the regular stream callback (1 copy at FFI boundary)
	service.SetStreamCallback(func(streamId int64, msgType byte, data []byte) {
		if streamCallback == nil {
			return
		}
		var cData unsafe.Pointer
		var cLen C.longlong = 0
		if len(data) > 0 {
			cData = C.CBytes(data)
			cLen = C.longlong(len(data))
			// Do NOT free cData here! Ownership is transferred to Dart.
			// Dart must free it using calloc.free() after processing.
		}
		C.invoke_stream_callback(streamCallback, C.longlong(streamId), C.char(msgType), cData, cLen)
	})

	// Register the zero-copy stream callback (receives C pointer directly)
	service.SetStreamCallbackFfi(func(streamId int64, msgType byte, data unsafe.Pointer, len int64) {
		if streamCallback == nil {
			return
		}
		// Data is already in C memory, pass directly - no copy!
		C.invoke_stream_callback(streamCallback, C.longlong(streamId), C.char(msgType), data, C.longlong(len))
	})
}

//export InvokeBackendServerStream
func InvokeBackendServerStream(method *C.char, data unsafe.Pointer, dataLen C.longlong) C.longlong {
	goMethod := C.GoString(method)
	var goData []byte
	if dataLen > 0 {
		goData = C.GoBytes(data, C.int(dataLen))
	}

	return C.longlong(service.HandleServerStream(goMethod, goData))
}

//export InvokeBackendClientStream
func InvokeBackendClientStream(method *C.char) C.longlong {
	goMethod := C.GoString(method)
	return C.longlong(service.HandleClientStream(goMethod))
}

//export InvokeBackendBidiStream
func InvokeBackendBidiStream(method *C.char) C.longlong {
	goMethod := C.GoString(method)
	return C.longlong(service.HandleBidiStream(goMethod))
}

//export SendStreamData
func SendStreamData(streamId C.longlong, data unsafe.Pointer, dataLen C.longlong) C.int {
	// OPTION 1: Safe (current) - copies data into Go heap
	goData := C.GoBytes(data, C.int(dataLen))

	// OPTION 2: Zero-copy - use unsafe.Slice to view Dart's memory directly
	// Note: Only safe if the data is not accessed after this function returns
	// goData := unsafe.Slice((*byte)(data), int(dataLen))

	err := service.SendToStream(int64(streamId), goData)
	if err != nil {
		log.Printf("SendStreamData error: %v", err)
		return -1
	}
	return 0
}

//export CloseStream
func CloseStream(streamId C.longlong) {
	service.CloseStreamSession(int64(streamId))
}

//export CloseStreamInput
func CloseStreamInput(streamId C.longlong) {
	service.CloseStreamInput(int64(streamId))
}

//export StreamReady
func StreamReady(streamId C.longlong) {
	service.SignalStreamReady(int64(streamId))
}

// =============================================================================
// ZERO-COPY CACHE FFI FUNCTIONS
// These functions bypass protobuf serialization for binary data.
// =============================================================================

//export CacheGet
func CacheGet(storeName *C.char, key *C.char) C.FfiData {
	implMu.RLock()
	currentImpl := impl
	implMu.RUnlock()

	if currentImpl == nil || currentImpl.CacheServiceServer == nil {
		return C.FfiData{data: nil, len: 0}
	}

	goStoreName := C.GoString(storeName)
	goKey := C.GoString(key)

	resp, err := currentImpl.CacheServiceServer.Get(context.Background(), &pb.GetCacheRequest{
		StoreName: goStoreName,
		Key:       goKey,
	})

	if err != nil || resp == nil || len(resp.Value) == 0 {
		return C.FfiData{data: nil, len: 0}
	}

	cResp := C.CBytes(resp.Value)
	return C.FfiData{
		data: cResp,
		len:  C.longlong(len(resp.Value)),
	}
}

//export CachePut
func CachePut(storeName *C.char, key *C.char, data unsafe.Pointer, dataLen C.longlong, ttlSeconds C.longlong) C.int {
	implMu.RLock()
	currentImpl := impl
	implMu.RUnlock()

	if currentImpl == nil || currentImpl.CacheServiceServer == nil {
		return -1
	}

	goStoreName := C.GoString(storeName)
	goKey := C.GoString(key)
	// ZERO-COPY: Create a slice backed by the C pointer.
	// This is safe because CacheServiceServer.Put is synchronous and blocks until
	// the database write is complete, at which point we return and Dart frees the memory.
	goData := unsafe.Slice((*byte)(data), int(dataLen))

	_, err := currentImpl.CacheServiceServer.Put(context.Background(), &pb.PutCacheRequest{
		StoreName:  goStoreName,
		Key:        goKey,
		Value:      goData,
		TtlSeconds: int64(ttlSeconds),
	})

	if err != nil {
		log.Printf("CachePut error: %v", err)
		return -1
	}
	return 0
}

//export CacheContains
func CacheContains(storeName *C.char, key *C.char) C.int {
	implMu.RLock()
	currentImpl := impl
	implMu.RUnlock()

	if currentImpl == nil || currentImpl.CacheServiceServer == nil {
		return -1
	}

	goStoreName := C.GoString(storeName)
	goKey := C.GoString(key)

	resp, err := currentImpl.CacheServiceServer.Contains(context.Background(), &pb.GetCacheRequest{
		StoreName: goStoreName,
		Key:       goKey,
	})

	if err != nil {
		return -1
	}
	if resp.Value {
		return 1
	}
	return 0
}

//export CacheDelete
func CacheDelete(storeName *C.char, key *C.char) C.int {
	implMu.RLock()
	currentImpl := impl
	implMu.RUnlock()

	if currentImpl == nil || currentImpl.CacheServiceServer == nil {
		return -1
	}

	goStoreName := C.GoString(storeName)
	goKey := C.GoString(key)

	_, err := currentImpl.CacheServiceServer.Delete(context.Background(), &pb.DeleteCacheRequest{
		StoreName: goStoreName,
		Key:       goKey,
	})

	if err != nil {
		return -1
	}
	return 0
}

// =============================================================================
// Standalone Main (for testing without FFI)
// =============================================================================

func main() {
	flag.Parse()
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	arg := C.malloc(C.sizeof_struct_CoreArgument)
	defer C.free(arg)
	cArg := (*C.struct_CoreArgument)(arg)

	golangPort := flag.Lookup("golang-port").Value.String()
	golangSocket := flag.Lookup("golang-socket").Value.String()
	flutterPort := flag.Lookup("flutter-port").Value.String()
	flutterSocket := flag.Lookup("flutter-socket").Value.String()
	token := flag.Lookup("token").Value.String()

	log.Printf("Go server config: golang-port=%s, golang-socket=%s", golangPort, golangSocket)
	log.Printf("Flutter server config: flutter-port=%s, flutter-socket=%s", flutterPort, flutterSocket)

	cArg.engineTcpPort = C.CString(golangPort)
	cArg.engineSocketPath = C.CString(golangSocket)
	cArg.viewTcpPort = C.CString(flutterPort)
	cArg.viewSocketPath = C.CString(flutterSocket)
	cArg.token = C.CString(token)

	StartGrpcServer(*cArg)

	select {
	case err := <-serverErrors:
		log.Printf("Server error: %v", err)
		os.Exit(1)
	case sig := <-sigChan:
		log.Printf("Received signal: %v, shutting down...", sig)
		StopGrpcServer()
		os.Exit(0)
	}
}
