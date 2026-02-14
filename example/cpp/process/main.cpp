// C++ Process Child - uses shared service with gRPC transport
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <thread>

#include <grpcpp/grpcpp.h>
#include <grpcpp/server_builder.h>
#include <grpcpp/server_posix.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>

#include "example.grpc.pb.h"
#include "../service/greeter_service.h"

using grpc::Server;
using grpc::ServerBuilder;
using grpc::ServerContext;
using grpc::ServerReader;
using grpc::ServerReaderWriter;
using grpc::ServerWriter;
using grpc::Status;
using example::v1::GoGreeterService;
using example::v1::HelloRequest;
using example::v1::HelloResponse;

// Adapter: wraps shared logic with gRPC interface
class GreeterServiceImpl final : public GoGreeterService::Service {
    GreeterServiceLogic<HelloRequest, HelloResponse, void> logic{"cpp-process"};

public:
    Status Bar(ServerContext* ctx, const HelloRequest* req, HelloResponse* resp) override {
        *resp = logic.Bar(*req);
        return Status::OK;
    }

    Status BarServerStream(ServerContext* ctx, const HelloRequest* req,
                           ServerWriter<HelloResponse>* writer) override {
        logic.BarServerStream(*req, writer);
        return Status::OK;
    }

    Status BarClientStream(ServerContext* ctx, ServerReader<HelloRequest>* reader,
                           HelloResponse* resp) override {
        *resp = logic.BarClientStream(reader);
        return Status::OK;
    }

    Status BarBidiStream(ServerContext* ctx,
                         ServerReaderWriter<HelloResponse, HelloRequest>* stream) override {
        logic.BarBidiStream(stream);
        return Status::OK;
    }
};

int main(int argc, char** argv) {
#ifndef _WIN32
    signal(SIGPIPE, SIG_IGN);
#endif

    const char* fd_str = std::getenv("SYNURANG_IPC");
    if (!fd_str) {
        std::cerr << "SYNURANG_IPC environment variable not set" << std::endl;
        return 1;
    }

    int fd = std::stoi(fd_str);
    
    // Ensure blocking mode for gRPC server start
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags != -1) {
        fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
    }

    std::cerr << "C++ process child: starting gRPC server on fd " << fd << std::endl;

    GreeterServiceImpl service;
    ServerBuilder builder;
    builder.RegisterService(&service);

    std::unique_ptr<Server> server(builder.BuildAndStart());
    if (!server) {
        std::cerr << "Failed to start server" << std::endl;
        return 1;
    }

    // Add the connected FD to the server
    grpc::AddInsecureChannelFromFd(server.get(), fd);

    std::cerr << "C++ process child: serving on fd " << fd << "..." << std::endl;
    server->Wait();
    return 0;
}
