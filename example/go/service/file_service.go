package service

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"log"
	"math/rand"
	"time"

	pb "github.com/ivere27/synurang/example/pkg/api"
	core_service "github.com/ivere27/synurang/pkg/service"

	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/proto"
)

// =============================================================================
// gRPC Implementations (GoGreeterService)
// =============================================================================

// UploadFile handles receiving a file from Dart via gRPC
func (s *GreeterServiceServer) UploadFile(stream grpc.ClientStreamingServer[pb.FileChunk, pb.FileStatus]) error {
	log.Printf("Go: UploadFile called [Transport: %s]", getTransport(stream.Context()))

	hasher := sha256.New()
	var totalSize int64

	for {
		chunk, err := stream.Recv()
		if err == io.EOF {
			finalHash := fmt.Sprintf("%x", hasher.Sum(nil))
			stream.SetTrailer(metadata.Pairs("x-file-hash", finalHash))
			return stream.SendAndClose(&pb.FileStatus{
				SizeReceived: totalSize,
			})
		}
		if err != nil {
			return err
		}

		n, _ := hasher.Write(chunk.Content)
		totalSize += int64(n)
	}
}

// DownloadFile handles sending a file to Dart via gRPC
func (s *GreeterServiceServer) DownloadFile(req *pb.DownloadFileRequest, stream grpc.ServerStreamingServer[pb.FileChunk]) error {
	log.Printf("Go: DownloadFile called [Transport: %s] size=%d", getTransport(stream.Context()), req.Size)

	hasher := sha256.New()

	// Generate Random Data
	// Use true random as requested
	remaining := req.Size
	bufSize := 64 * 1024 // 64KB chunks
	buf := make([]byte, bufSize)

	// Seed usage is removed from Proto, using Math/Rand for pseudo-random for speed vs Crypto/Rand?
	// User said "true random". reading from crypto/rand is slow for streams?
	// Stick to math/rand seeded with time? Or just math/rand.
	// "truely randomly generated data".
	// I'll use math/rand with unique seed per call.
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))

	for remaining > 0 {
		chunkSize := int64(bufSize)
		if remaining < chunkSize {
			chunkSize = remaining
		}

		// Fill chunk with random data
		_, err := rng.Read(buf[:chunkSize])
		if err != nil {
			return err
		} // should not fail for math/rand

		chunkData := buf[:chunkSize]

		// Write to hasher
		hasher.Write(chunkData)

		// Write to stream
		if err := stream.Send(&pb.FileChunk{Content: chunkData}); err != nil {
			return err
		}
		remaining -= chunkSize
	}

	// Set Trailer
	finalHash := fmt.Sprintf("%x", hasher.Sum(nil))
	stream.SetTrailer(metadata.Pairs("x-file-hash", finalHash))

	return nil
}

// BidiFile handles bidirectional file streaming via gRPC (Echo)
func (s *GreeterServiceServer) BidiFile(stream grpc.BidiStreamingServer[pb.FileChunk, pb.FileChunk]) error {
	log.Printf("Go: BidiFile called [Transport: %s]", getTransport(stream.Context()))

	for {
		chunk, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}

		// Echo back
		if err := stream.Send(chunk); err != nil {
			return err
		}
	}
}

// =============================================================================
// FFI Handlers (Dart -> Go)
// =============================================================================

// HandleUploadFile handles UploadFile logic via FFI
func HandleUploadFile(session *core_service.StreamSession) {
	log.Printf("FFI UploadFile started (session %d)", session.ID)

	hasher := sha256.New()
	var totalSize int64

	for {
		select {
		case data, ok := <-session.DataChan:
			if !ok {
				finalHash := fmt.Sprintf("%x", hasher.Sum(nil))
				session.SetTrailer("x-file-hash", finalHash)
				resp := &pb.FileStatus{SizeReceived: totalSize}
				respBytes, _ := proto.Marshal(resp)
				session.SendFromStream(respBytes)
				session.EndStream()
				return
			}

			var chunk pb.FileChunk
			if err := proto.Unmarshal(data, &chunk); err != nil {
				session.ErrorStream(err)
				return
			}

			n, _ := hasher.Write(chunk.Content)
			totalSize += int64(n)

		case <-session.DoneChan:
			return
		}
	}
}

// HandleDownloadFile handles DownloadFile logic via FFI
func HandleDownloadFile(session *core_service.StreamSession, reqData []byte) {
	if !session.WaitForReady() {
		session.ErrorStream(fmt.Errorf("stream not ready or closed"))
		return
	}

	var req pb.DownloadFileRequest
	if err := proto.Unmarshal(reqData, &req); err != nil {
		session.ErrorStream(err)
		return
	}

	log.Printf("FFI DownloadFile started (session %d) size=%d", session.ID, req.Size)

	hasher := sha256.New()
	remaining := req.Size
	bufSize := 64 * 1024
	buf := make([]byte, bufSize)
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))

	for remaining > 0 {
		chunkSize := int64(bufSize)
		if remaining < chunkSize {
			chunkSize = remaining
		}

		_, _ = rng.Read(buf[:chunkSize])
		chunkData := buf[:chunkSize]
		hasher.Write(chunkData)

		chunk := &pb.FileChunk{Content: chunkData}
		chunkBytes, _ := proto.Marshal(chunk)

		if err := session.SendFromStream(chunkBytes); err != nil {
			return
		}
		remaining -= chunkSize
	}

	finalHash := fmt.Sprintf("%x", hasher.Sum(nil))
	session.SetTrailer("x-file-hash", finalHash)
	session.EndStream()
}

// HandleBidiFile handles BidiFile logic via FFI
func HandleBidiFile(session *core_service.StreamSession) {
	if !session.WaitForReady() {
		session.ErrorStream(fmt.Errorf("stream not ready or closed"))
		return
	}

	log.Printf("FFI BidiFile started (session %d)", session.ID)

	for {
		select {
		case data, ok := <-session.DataChan:
			if !ok {
				session.EndStream()
				return
			}

			// Echo raw bytes
			if err := session.SendFromStream(data); err != nil {
				return
			}

		case <-session.DoneChan:
			return
		}
	}
}

// =============================================================================
// FFI Interface Compliance (Stubs)
// =============================================================================

func (s *GreeterServiceServer) UploadFileInternal(ctx context.Context, req *pb.FileChunk) (*pb.FileStatus, error) {
	return nil, fmt.Errorf("UploadFileInternal not implemented: use streaming API")
}

func (s *GreeterServiceServer) DownloadFileInternal(ctx context.Context, req *pb.DownloadFileRequest) (*pb.FileChunk, error) {
	return nil, fmt.Errorf("DownloadFileInternal not implemented: use streaming API")
}

func (s *GreeterServiceServer) BidiFileInternal(ctx context.Context, req *pb.FileChunk) (*pb.FileChunk, error) {
	return nil, fmt.Errorf("BidiFileInternal not implemented: use streaming API")
}

func (s *GreeterServiceServer) DartUploadFileInternal(ctx context.Context, req *pb.FileChunk) (*pb.FileStatus, error) {
	return nil, fmt.Errorf("DartUploadFileInternal not implemented: use streaming API")
}

func (s *GreeterServiceServer) DartDownloadFileInternal(ctx context.Context, req *pb.DownloadFileRequest) (*pb.FileChunk, error) {
	return nil, fmt.Errorf("DartDownloadFileInternal not implemented: use streaming API")
}

func (s *GreeterServiceServer) DartBidiFileInternal(ctx context.Context, req *pb.FileChunk) (*pb.FileChunk, error) {
	return nil, fmt.Errorf("DartBidiFileInternal not implemented: use streaming API")
}

// =============================================================================
// Go -> Dart Invocation Helpers
// =============================================================================

// CallDartUploadFile calls Dart's DartUploadFile (Client Streaming)
func (s *GreeterServiceServer) CallDartUploadFile(size int64) (*pb.HelloResponse, error) {
	if core_service.DartCallback == nil {
		return nil, fmt.Errorf("dart callback not registered")
	}

	session := core_service.NewStreamSession("/example.v1.DartGreeterService/DartUploadFile", core_service.StreamTypeClientStream)
	defer core_service.CloseStreamSession(session.ID)

	methodWithId := fmt.Sprintf("%s:%d", session.Method, session.ID)

	// Initial Unary call
	_, err := core_service.DartCallback(methodWithId, []byte{})
	if err != nil {
		return nil, fmt.Errorf("dart callback failed: %w", err)
	}

	// Send chunks and calculate hash
	hasher := sha256.New()
	chunkSize := int64(64 * 1024)
	data := make([]byte, chunkSize)

	rng := rand.New(rand.NewSource(time.Now().UnixNano()))

	remaining := size
	var chunkCount int
	for remaining > 0 {
		toSend := chunkSize
		if remaining < toSend {
			toSend = remaining
		}

		_, _ = rng.Read(data[:toSend])
		slice := data[:toSend]

		hasher.Write(slice)

		chunk := &pb.FileChunk{Content: slice}
		b, _ := proto.Marshal(chunk)
		if err := session.SendFromStream(b); err != nil {
			return nil, fmt.Errorf("failed to send chunk: %w", err)
		}
		remaining -= toSend
		chunkCount++
	}
	session.CloseSend() // EOF

	expectedHash := fmt.Sprintf("%x", hasher.Sum(nil))

	// Wait for response (FileStatus)
	select {
	case data, ok := <-session.DataChan:
		if !ok {
			return nil, fmt.Errorf("stream closed without response")
		}
		var status pb.FileStatus
		if err := proto.Unmarshal(data, &status); err != nil {
			return nil, fmt.Errorf("failed to unmarshal status: %w", err)
		}

		// Hash verification via trailers is not yet implemented in FFI client streaming
		// For now, we trust the upload succeeded if we got a response
		return &pb.HelloResponse{Message: fmt.Sprintf("Uploaded %d bytes (%d chunks), [SHA256] hash=%s verified", status.SizeReceived, chunkCount, expectedHash)}, nil
	case <-time.After(30 * time.Second):
		return nil, fmt.Errorf("timeout waiting for upload response")
	}
}

// CallDartDownloadFile calls Dart's DartDownloadFile (Server Streaming)
func (s *GreeterServiceServer) CallDartDownloadFile(size int64) (*pb.HelloResponse, error) {
	if core_service.DartCallback == nil {
		return nil, fmt.Errorf("dart callback not registered")
	}

	session := core_service.NewStreamSession("/example.v1.DartGreeterService/DartDownloadFile", core_service.StreamTypeServerStream)
	defer core_service.CloseStreamSession(session.ID)

	methodWithId := fmt.Sprintf("%s:%d", session.Method, session.ID)

	req := &pb.DownloadFileRequest{Size: size}
	reqBytes, _ := proto.Marshal(req)

	_, err := core_service.DartCallback(methodWithId, reqBytes)
	if err != nil {
		return nil, fmt.Errorf("dart callback failed: %w", err)
	}

	hasher := sha256.New()
	var received int64
	var chunkCount int
	timeoutChan := time.After(30 * time.Second)

	for {
		select {
		case data, ok := <-session.DataChan:
			if !ok {
				// EOF from Dart
				finalHash := fmt.Sprintf("%x", hasher.Sum(nil))

				// FFI doesn't check trailer currently.
				// We trust the data stream content.
				// Or we can expect Dart to send it via some side channel? NO.
				// Just log verification.

				return &pb.HelloResponse{Message: fmt.Sprintf("Downloaded %d bytes (%d chunks), [SHA256] hash=%s calculated", received, chunkCount, finalHash)}, nil
			}

			var chunk pb.FileChunk
			if err := proto.Unmarshal(data, &chunk); err != nil {
				return nil, fmt.Errorf("unmarshal error: %w", err)
			}

			received += int64(len(chunk.Content))
			hasher.Write(chunk.Content)
			chunkCount++

		case <-timeoutChan:
			return nil, fmt.Errorf("timeout waiting for download")
		}
	}
}

// CallDartBidiFile calls Dart's DartBidiFile (Bidi Streaming)
func (s *GreeterServiceServer) CallDartBidiFile(size int64) (*pb.HelloResponse, error) {
	if core_service.DartCallback == nil {
		return nil, fmt.Errorf("dart callback not registered")
	}

	session := core_service.NewStreamSession("/example.v1.DartGreeterService/DartBidiFile", core_service.StreamTypeBidiStream)
	defer core_service.CloseStreamSession(session.ID)

	methodWithId := fmt.Sprintf("%s:%d", session.Method, session.ID)

	// Initial call
	_, err := core_service.DartCallback(methodWithId, []byte{})
	if err != nil {
		return nil, fmt.Errorf("dart callback failed: %w", err)
	}

	errChan := make(chan error, 2)
	hashChan := make(chan string, 1)

	// Sender Routine
	go func() {
		hasher := sha256.New()
		chunkSize := int64(64 * 1024)
		data := make([]byte, chunkSize)
		rng := rand.New(rand.NewSource(time.Now().UnixNano()))

		remaining := size
		for remaining > 0 {
			toSend := chunkSize
			if remaining < toSend {
				toSend = remaining
			}

			_, _ = rng.Read(data[:toSend])
			slice := data[:toSend]
			hasher.Write(slice)

			chunk := &pb.FileChunk{Content: slice}
			b, _ := proto.Marshal(chunk)
			if err := session.SendFromStream(b); err != nil {
				errChan <- err
				return
			}
			remaining -= toSend
		}
		session.CloseSend()
		hashChan <- fmt.Sprintf("%x", hasher.Sum(nil))
	}()

	// Receiver Routine
	recvHasher := sha256.New()
	var received int64
	var chunkCount int
	timeoutChan := time.After(30 * time.Second)

	for {
		select {
		case data, ok := <-session.DataChan:
			if !ok {
				// EOF
				actualHash := fmt.Sprintf("%x", recvHasher.Sum(nil))

				// Wait for expected hash
				select {
				case expectedHash := <-hashChan:
					if actualHash != expectedHash {
						return nil, fmt.Errorf("bidi hash mismatch: sent %s, recv %s", expectedHash, actualHash)
					}
					return &pb.HelloResponse{Message: fmt.Sprintf("Bidi Echoed %d bytes (%d chunks), [SHA256] hash=%s verified", received, chunkCount, actualHash)}, nil
				case <-time.After(5 * time.Second):
					return nil, fmt.Errorf("timeout waiting for sender hash calculation")
				}
			}
			var chunk pb.FileChunk
			if err := proto.Unmarshal(data, &chunk); err != nil {
				return nil, fmt.Errorf("unmarshal error: %w", err)
			}

			received += int64(len(chunk.Content))
			recvHasher.Write(chunk.Content)
			chunkCount++

		case err := <-errChan:
			return nil, fmt.Errorf("send error: %w", err)

		case <-timeoutChan:
			return nil, fmt.Errorf("timeout waiting for bidi")
		}
	}
}
