//go:build synurang_call_conformance

package main

import (
	"context"
	"github.com/ivere27/synurang/pkg/ffierror"
	"github.com/ivere27/synurang/pkg/module"
	pb "github.com/ivere27/synurang/test/call/pb"
	"io"
)

type service struct{}

func (service) Unary(_ context.Context, request *pb.Value) (*pb.Value, error) {
	if request.Value == -1 {
		return nil, ffierror.New(42, "Error after response", 7)
	}
	return request, nil
}
func (service) Server(request *pb.Value, stream *module.Stream[*pb.Value, *pb.Value]) error {
	for i := int32(0); i < request.Value; i++ {
		if err := stream.Send(&pb.Value{Value: i}); err != nil {
			return err
		}
	}
	return nil
}
func (service) Client(stream *module.Stream[*pb.Value, *pb.Value]) (*pb.Value, error) {
	total := int32(0)
	for {
		request, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		if request.Value == -2 {
			return &pb.Value{Value: 42}, nil
		}
		total += request.Value
	}
	return &pb.Value{Value: total}, nil
}
func (service) Bidi(stream *module.Stream[*pb.Value, *pb.Value]) error {
	for {
		request, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if err := stream.Send(request); err != nil {
			return err
		}
	}
}
func (service) Wait(ctx context.Context, _ *pb.Value) (*pb.Value, error) {
	<-ctx.Done()
	return nil, ctx.Err()
}
func (service) Fail(context.Context, *pb.Value) (*pb.Value, error) {
	return nil, ffierror.New(42, "Permission denied by provider", 7)
}
func init() {
	module.RegisterModule(func() *module.Instance {
		instance := module.New()
		if err := pb.RegisterCallsModule(instance, service{}); err != nil {
			panic(err)
		}
		return instance
	})
}
func main() { module.Run() }
