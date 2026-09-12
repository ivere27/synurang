// Package callgrpc adapts native module calls to grpc.ClientConnInterface.
// The core host in pkg/call remains independent of gRPC.
package callgrpc

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"sync"

	"github.com/ivere27/synurang/pkg/call"
	"github.com/ivere27/synurang/pkg/ffierror"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

// Conn borrows a module. The caller owns the module's lifetime.
type Conn struct{ module *call.Module }

func New(module *call.Module) *Conn { return &Conn{module: module} }

var _ grpc.ClientConnInterface = (*Conn)(nil)

type options struct {
	headers  []*metadata.MD
	trailers []*metadata.MD
	finish   []func(error)
	maxSend  int
	maxRecv  int
}

func parseOptions(ctx context.Context, supplied []grpc.CallOption) (options, error) {
	result := options{maxSend: math.MaxInt32, maxRecv: 4 << 20}
	var unsupported error
	if md, ok := metadata.FromOutgoingContext(ctx); ok && len(md) != 0 {
		unsupported = status.Error(codes.Unimplemented, "Module ABI does not carry request metadata")
	}
	for _, option := range supplied {
		switch value := option.(type) {
		case grpc.StaticMethodCallOption, grpc.FailFastCallOption:
			// The module is already loaded; there is no network ready state.
		case grpc.HeaderCallOption:
			if value.HeaderAddr != nil {
				result.headers = append(result.headers, value.HeaderAddr)
			}
		case grpc.TrailerCallOption:
			if value.TrailerAddr != nil {
				result.trailers = append(result.trailers, value.TrailerAddr)
			}
		case grpc.OnFinishCallOption:
			if value.OnFinish != nil {
				result.finish = append(result.finish, value.OnFinish)
			}
		case grpc.MaxRecvMsgSizeCallOption:
			result.maxRecv = value.MaxRecvMsgSize
		case grpc.MaxSendMsgSizeCallOption:
			result.maxSend = value.MaxSendMsgSize
		default:
			unsupported = status.Errorf(codes.Unimplemented, "Module transport does not support %T", option)
		}
	}
	if result.maxSend < 0 || result.maxRecv < 0 {
		unsupported = status.Error(codes.InvalidArgument, "Negative message size limit")
	}
	return result, unsupported
}

func rpcError(err error) error {
	if err == nil || errors.Is(err, io.EOF) {
		return err
	}
	var moduleError *call.Error
	if errors.As(err, &moduleError) {
		code := codes.Code(moduleError.Code)
		if code < codes.Canceled || code > codes.Unauthenticated {
			code = codes.Unknown
		}
		message := moduleError.Message
		detail, decodeError := ffierror.Unmarshal(moduleError.Details)
		if decodeError == nil && len(moduleError.Details) != 0 {
			if detail.Message != "" {
				message = detail.Message
			}
			converted, detailError := status.New(code, message).WithDetails(detail)
			if detailError == nil {
				return converted.Err()
			}
		}
		return status.Error(code, message)
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return status.FromContextError(err).Err()
	}
	if _, ok := status.FromError(err); ok {
		return err
	}
	return status.Error(codes.Internal, err.Error())
}

func errorTrailers(err error) metadata.MD {
	trailers := metadata.MD{}
	if err == nil {
		return trailers
	}
	var moduleError *call.Error
	if errors.As(err, &moduleError) && len(moduleError.Details) != 0 {
		trailers.Set("synurang-error-bin", string(moduleError.Details))
	}
	converted := rpcError(err)
	if converted != nil {
		if data, marshalError := proto.Marshal(status.Convert(converted).Proto()); marshalError == nil {
			trailers.Set("grpc-status-details-bin", string(data))
		}
	}
	return trailers
}

func (o options) complete(err error, trailers metadata.MD) {
	for _, address := range o.headers {
		*address = metadata.MD{}
	}
	for _, address := range o.trailers {
		*address = trailers.Copy()
	}
	for _, callback := range o.finish {
		callback(err)
	}
}

func encode(value any, limit int) ([]byte, error) {
	message, ok := value.(proto.Message)
	if !ok {
		return nil, status.Error(codes.Internal, "Request must implement proto.Message")
	}
	data, err := proto.Marshal(message)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "Encode request: %v", err)
	}
	if len(data) > limit {
		return nil, status.Error(codes.ResourceExhausted, "Request exceeds message size limit")
	}
	return data, nil
}

func decode(data []byte, value any, limit int) error {
	if len(data) > limit {
		return status.Error(codes.ResourceExhausted, "Response exceeds message size limit")
	}
	message, ok := value.(proto.Message)
	if !ok {
		return status.Error(codes.Internal, "Response must implement proto.Message")
	}
	if err := proto.Unmarshal(data, message); err != nil {
		return status.Errorf(codes.Internal, "Decode response: %v", err)
	}
	return nil
}

func (c *Conn) Invoke(ctx context.Context, method string, request, response any, supplied ...grpc.CallOption) (err error) {
	settings, err := parseOptions(ctx, supplied)
	var rawError error
	defer func() { settings.complete(err, errorTrailers(rawError)) }()
	if err != nil {
		rawError = err
		return err
	}
	data, err := encode(request, settings.maxSend)
	if err != nil {
		rawError = err
		return err
	}
	data, rawError = c.module.Unary(ctx, method, data)
	if rawError != nil {
		return rpcError(rawError)
	}
	err = decode(data, response, settings.maxRecv)
	rawError = err
	return err
}

func (c *Conn) NewStream(ctx context.Context, descriptor *grpc.StreamDesc, method string, supplied ...grpc.CallOption) (grpc.ClientStream, error) {
	settings, err := parseOptions(ctx, supplied)
	if err != nil {
		settings.complete(err, errorTrailers(err))
		return nil, err
	}
	if descriptor == nil {
		err := status.Error(codes.InvalidArgument, "Missing stream descriptor")
		settings.complete(err, errorTrailers(err))
		return nil, err
	}
	child, cancel := context.WithCancel(ctx)
	native, err := c.module.Open(child, call.Method{Path: method, RequestStream: descriptor.ClientStreams, ResponseStream: descriptor.ServerStreams})
	if err != nil {
		cancel()
		converted := rpcError(err)
		settings.complete(converted, errorTrailers(err))
		return nil, converted
	}
	stream := &clientStream{call: native, ctx: child, cancel: cancel, options: settings,
		responseStream: descriptor.ServerStreams, done: make(chan struct{})}
	go func() {
		select {
		case <-child.Done():
			stream.finish(child.Err())
		case <-stream.done:
		}
	}()
	return stream, nil
}

type clientStream struct {
	call           *call.Call
	ctx            context.Context
	cancel         context.CancelFunc
	options        options
	responseStream bool
	mu             sync.Mutex
	sendMu         sync.Mutex
	recvMu         sync.Mutex
	done           chan struct{}
	finished       bool
	err            error
	trailers       metadata.MD
}

func (s *clientStream) Header() (metadata.MD, error) { return metadata.MD{}, nil }
func (s *clientStream) Trailer() metadata.MD {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.trailers.Copy()
}
func (s *clientStream) Context() context.Context { return s.ctx }

func (s *clientStream) terminal() (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.finished, s.err
}

func (s *clientStream) finish(rawError error) {
	if errors.Is(rawError, io.EOF) {
		rawError = nil
	}
	s.mu.Lock()
	if s.finished {
		s.mu.Unlock()
		return
	}
	s.finished = true
	s.err = rpcError(rawError)
	s.trailers = errorTrailers(rawError)
	err, trailers := s.err, s.trailers.Copy()
	close(s.done)
	s.mu.Unlock()
	s.call.Close()
	s.cancel()
	s.options.complete(err, trailers)
}

func (s *clientStream) SendMsg(request any) error {
	s.sendMu.Lock()
	if finished, _ := s.terminal(); finished {
		s.sendMu.Unlock()
		return io.EOF
	}
	data, err := encode(request, s.options.maxSend)
	if err == nil {
		err = s.call.Send(data)
	}
	s.sendMu.Unlock()
	if err != nil {
		// A server may finish client/bidi streaming before accepting another
		// request. Send-side EOF leaves queued responses and final status
		// available to RecvMsg, as it does on a network gRPC stream.
		if !errors.Is(err, io.EOF) {
			s.finish(err)
		}
		return rpcError(err)
	}
	return nil
}

func (s *clientStream) CloseSend() error {
	s.sendMu.Lock()
	if finished, err := s.terminal(); finished {
		s.sendMu.Unlock()
		return err
	}
	err := s.call.HalfClose()
	s.sendMu.Unlock()
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err != nil {
		s.finish(err)
	}
	return rpcError(err)
}

func (s *clientStream) RecvMsg(response any) error {
	s.recvMu.Lock()
	if finished, err := s.terminal(); finished {
		s.recvMu.Unlock()
		if err != nil {
			return err
		}
		return io.EOF
	}
	data, err := s.call.Recv()
	if err != nil {
		s.recvMu.Unlock()
		s.finish(err)
		return rpcError(err)
	}
	if !s.responseStream {
		// Client-streaming stubs call RecvMsg only once. Verify terminal success
		// before decoding that response, including response-then-error cases.
		if _, err = s.call.Recv(); !errors.Is(err, io.EOF) {
			if err == nil {
				err = status.Error(codes.Internal, "Multiple unary responses")
			}
			s.recvMu.Unlock()
			s.finish(err)
			return rpcError(err)
		}
	}
	err = decode(data, response, s.options.maxRecv)
	s.recvMu.Unlock()
	if err != nil || !s.responseStream {
		s.finish(err)
	}
	return err
}

func (c *Conn) String() string { return fmt.Sprintf("synurang module %p", c.module) }
