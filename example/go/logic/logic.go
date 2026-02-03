// Package logic provides the shared greeter business logic
// used by plugin, process, and FFI streaming modes.
// This package has NO proto imports to avoid namespace conflicts.
package logic

import (
	"fmt"
	"log"
	"strings"
)

// GreeterLogic provides the core business logic for the greeter service.
// This is proto-agnostic and can be used with any transport (gRPC, FFI, plugin).
type GreeterLogic struct {
	// Source identifies where this server is running (e.g., "go-plugin", "go-process")
	Source string
}

// NewGreeterLogic creates a new GreeterLogic with the given source identifier.
func NewGreeterLogic(source string) *GreeterLogic {
	return &GreeterLogic{Source: source}
}

// Bar handles unary RPC - returns (message, from)
func (l *GreeterLogic) Bar(name string) (message, from string) {
	log.Printf("[%s] Bar called: %s", l.Source, name)
	return fmt.Sprintf("Hello %s!", name), l.Source
}

// BarServerStream handles server streaming RPC.
// The send callback should return false to stop streaming.
func (l *GreeterLogic) BarServerStream(name string, send func(message, from string, index, total int) bool) {
	log.Printf("[%s] BarServerStream called: %s", l.Source, name)
	languages := []string{"en", "ko", "ja", "es", "fr"}
	for i, lang := range languages {
		greeting := GetGreeting(lang, name)
		if !send(fmt.Sprintf("[%d/5] %s", i+1, greeting), l.Source, i, len(languages)) {
			break
		}
	}
}

// BarClientStream handles client streaming RPC.
// Processes all names and returns (message, from)
func (l *GreeterLogic) BarClientStream(names []string) (message, from string) {
	log.Printf("[%s] BarClientStream called with %d names", l.Source, len(names))
	return fmt.Sprintf("Hello to all: %s!", JoinNames(names)), l.Source
}

// BarBidiStream handles one request in bidi streaming RPC.
// Returns (message, from) for the echo response.
func (l *GreeterLogic) BarBidiStream(name, language string) (message, from string) {
	log.Printf("[%s] BarBidiStream received: %s", l.Source, name)
	greeting := GetGreeting(language, name)
	return greeting, l.Source
}

// Trigger handles alert triggering - returns (message, from)
func (l *GreeterLogic) Trigger() (message, from string) {
	log.Printf("[%s] Trigger called", l.Source)
	return "Trigger called", l.Source
}

// GetGoroutines returns goroutine info - returns (count, message)
func (l *GreeterLogic) GetGoroutines() (count int32, message string) {
	return 1, l.Source + " goroutines"
}

// GetGreeting returns localized greeting
func GetGreeting(lang, name string) string {
	greetings := map[string]string{
		"en": "Hello",
		"ko": "안녕하세요",
		"ja": "こんにちは",
		"es": "Hola",
		"fr": "Bonjour",
	}
	greeting, ok := greetings[lang]
	if !ok {
		greeting = greetings["en"]
	}
	return fmt.Sprintf("%s, %s!", greeting, name)
}

// JoinNames joins a slice of names into a comma-separated string
func JoinNames(names []string) string {
	if len(names) == 0 {
		return "(nobody)"
	}
	return strings.Join(names, ", ")
}
