package module

import (
	"context"
	"google.golang.org/protobuf/proto"
)

// Stream is the typed service view of the common call. Send and Recv may run
// concurrently in separate goroutines; the bounded queues provide flow control.
type Stream[I proto.Message, O proto.Message] struct {
	call       *Call
	newRequest func() I
}

func NewStream[I proto.Message, O proto.Message](call *Call, newRequest func() I) *Stream[I, O] {
	return &Stream[I, O]{call, newRequest}
}
func (stream *Stream[I, O]) Context() context.Context { return stream.call.Context() }
func (stream *Stream[I, O]) Retain() func()           { return stream.call.Retain() }
func (stream *Stream[I, O]) Send(message O) error     { return stream.call.Send(message) }
func (stream *Stream[I, O]) Recv() (I, error) {
	request := stream.newRequest()
	err := stream.call.Recv(request)
	return request, err
}
