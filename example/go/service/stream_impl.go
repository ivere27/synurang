package service

import (
	"fmt"
	"log"
	"time"

	pb "github.com/ivere27/synurang/example/pkg/api"
	core_service "github.com/ivere27/synurang/pkg/service"

	"google.golang.org/protobuf/proto"
)

// HandleBarServerStream handles the BarServerStream logic via FFI
func HandleBarServerStream(session *core_service.StreamSession, reqData []byte) {
	// Wait for Dart to signal it's ready to receive
	if !session.WaitForReady() {
		session.ErrorStream(fmt.Errorf("stream not ready or closed"))
		return
	}

	var req pb.HelloRequest
	if err := proto.Unmarshal(reqData, &req); err != nil {
		session.ErrorStream(err)
		return
	}

	log.Printf("FFI ServerStream: BarServerStream called with name=%s", req.Name)

	// Use a fake stream that sends via FFI callback
	languages := []string{"en", "ko", "ja", "es", "fr"}
	for i, lang := range languages {
		greeting := getGreeting(lang, req.Name) // Reuse getGreeting from greeter.go
		resp := &pb.HelloResponse{
			Message: fmt.Sprintf("[%d/5] %s", i+1, greeting),
			From:    "go",
		}
		respBytes, _ := proto.Marshal(resp)
		if err := session.SendFromStream(respBytes); err != nil {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	session.EndStream()
}

// HandleBarClientStream handles the BarClientStream logic via FFI
func HandleBarClientStream(session *core_service.StreamSession) {
	log.Printf("FFI ClientStream: BarClientStream started (session %d)", session.ID)

	var names []string

	// Collect all data from client
	for {
		select {
		case data, ok := <-session.DataChan:
			if !ok {
				// EOF - Client finished sending
				resp := &pb.HelloResponse{
					Message: fmt.Sprintf("Hello to all: %s!", joinNames(names)),
					From:    "go",
				}
				respBytes, _ := proto.Marshal(resp)
				session.SendFromStream(respBytes)
				session.EndStream()
				return
			}

			var req pb.HelloRequest
			if err := proto.Unmarshal(data, &req); err != nil {
				session.ErrorStream(err)
				return
			}
			log.Printf("FFI ClientStream: received name=%s", req.Name)
			names = append(names, req.Name)

		case <-session.DoneChan:
			// Session cancelled externally
			return
		}
	}
}

// HandleBarBidiStream handles the BarBidiStream logic via FFI
func HandleBarBidiStream(session *core_service.StreamSession) {
	// Wait for Dart to signal it's ready to receive
	if !session.WaitForReady() {
		session.ErrorStream(fmt.Errorf("stream not ready or closed"))
		return
	}

	log.Printf("FFI BidiStream: BarBidiStream started (session %d)", session.ID)

	for {
		select {
		case data, ok := <-session.DataChan:
			if !ok {
				// EOF - Client finished sending
				session.EndStream()
				return
			}

			var req pb.HelloRequest
			if err := proto.Unmarshal(data, &req); err != nil {
				session.ErrorStream(err)
				return
			}
			log.Printf("FFI BidiStream: received name=%s", req.Name)

			// Echo back immediately
			greeting := getGreeting(req.Language, req.Name)
			resp := &pb.HelloResponse{
				Message:   greeting,
				From:      "go",
				Timestamp: nil, // Add timestamp if needed but nil is fine for now
			}
			respBytes, _ := proto.Marshal(resp)
			if err := session.SendFromStream(respBytes); err != nil {
				return
			}

		case <-session.DoneChan:
			return
		}
	}
}

func joinNames(names []string) string {
	if len(names) == 0 {
		return "(nobody)"
	}
	result := names[0]
	for i := 1; i < len(names); i++ {
		result += ", " + names[i]
	}
	return result
}
