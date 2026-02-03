package service

import (
	"fmt"
	"log"
	"time"

	"github.com/ivere27/synurang/example/go/logic"
	pb "github.com/ivere27/synurang/example/pkg/api"
	core_service "github.com/ivere27/synurang/pkg/service"

	"google.golang.org/protobuf/proto"
)

// Shared logic instance for FFI streaming handlers
var ffiLogic = logic.NewGreeterLogic("go")

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

	// Use shared logic with callback
	ffiLogic.BarServerStream(req.Name, func(message, from string, index, total int) bool {
		resp := &pb.HelloResponse{
			Message: message,
			From:    from,
		}
		respBytes, _ := proto.Marshal(resp)
		if err := session.SendFromStream(respBytes); err != nil {
			return false
		}
		time.Sleep(100 * time.Millisecond)
		return true
	})
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
				// EOF - Client finished sending, use shared logic
				msg, from := ffiLogic.BarClientStream(names)
				resp := &pb.HelloResponse{
					Message: msg,
					From:    from,
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

			// Use shared logic for echo response
			msg, from := ffiLogic.BarBidiStream(req.Name, req.Language)
			resp := &pb.HelloResponse{
				Message:   msg,
				From:      from,
				Timestamp: nil,
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
