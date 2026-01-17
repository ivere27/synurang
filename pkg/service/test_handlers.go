package service

import (
	"log"
	"time"
)

// Test stream handlers - registered via init() for development/testing.
// In production builds, this file can be excluded via build tags if needed.
// For now, these minimal test handlers have negligible overhead.

func init() {
	registerTestStreamHandlers()
}

// registerTestStreamHandlers registers handlers for testing stream functionality.
// These handlers are used by the verification tests in full_verification_and_benchmark_test.dart.
func registerTestStreamHandlers() {
	// Server stream test: sends bytes [1, 2, 3, 4, 5] with small delays
	RegisterServerStreamHandler("test/server_stream", func(data []byte) HandlerFunc {
		return func(s *StreamSession) {
			if !s.WaitForReady() {
				return
			}
			for i := 1; i <= 5; i++ {
				if err := s.SendFromStream([]byte{byte(i)}); err != nil {
					log.Printf("ServerStream send error: %v", err)
					return
				}
				time.Sleep(10 * time.Millisecond)
			}
			s.CloseSend()
		}
	})

	// Client stream test: sums all received bytes and returns the total
	RegisterClientStreamHandler("test/client_stream", func() HandlerFunc {
		return func(s *StreamSession) {
			var sum byte
			for data := range s.DataChan {
				if len(data) > 0 {
					sum += data[0]
				}
			}
			s.SendFromStream([]byte{sum})
			s.CloseSend()
		}
	})

	// Bidi stream test: echoes back each received byte
	RegisterBidiStreamHandler("test/bidi_stream", func() HandlerFunc {
		return func(s *StreamSession) {
			if !s.WaitForReady() {
				return
			}
			for data := range s.DataChan {
				if err := s.SendFromStream(data); err != nil {
					log.Printf("BidiStream send error: %v", err)
					return
				}
			}
			s.CloseSend()
		}
	})

	log.Println("Test stream handlers registered")
}
