// Shared C++ greeter service implementation
// Used by both plugin and process modes
#ifndef SYNURANG_GREETER_SERVICE_H_
#define SYNURANG_GREETER_SERVICE_H_

#include <string>
#include <iostream>
#include <sstream>

// Template class for shared business logic
// Template parameter Stream allows different stream interfaces (gRPC vs FFI)
template<typename Request, typename Response, typename Stream>
class GreeterServiceLogic {
public:
    std::string source;

    explicit GreeterServiceLogic(const std::string& src) : source(src) {}

    // Unary RPC logic
    Response Bar(const Request& request) {
        std::cerr << "[" << source << "] Bar: " << request.name() << std::endl;
        Response response;
        response.set_message("Hello " + request.name() + "!");
        response.set_from(source);
        return response;
    }

    // Server streaming logic
    template<typename StreamWriter>
    void BarServerStream(const Request& request, StreamWriter* writer) {
        std::cerr << "[" << source << "] BarServerStream: " << request.name() << std::endl;
        for (int i = 0; i < 3; i++) {
            Response response;
            std::ostringstream msg;
            msg << "Hello " << request.name() << " #" << (i + 1);
            response.set_message(msg.str());
            response.set_from(source);
            if (!writer->Write(response)) break;
        }
    }

    // Client streaming logic
    template<typename StreamReader>
    Response BarClientStream(StreamReader* reader) {
        std::cerr << "[" << source << "] BarClientStream started" << std::endl;
        int count = 0;
        Request req;
        while (reader->Read(&req)) {
            std::cerr << "[" << source << "] BarClientStream received: " << req.name() << std::endl;
            count++;
        }
        Response response;
        response.set_message("Received " + std::to_string(count) + " messages");
        response.set_from(source);
        return response;
    }

    // Bidi streaming logic
    template<typename BidiStream>
    void BarBidiStream(BidiStream* stream) {
        std::cerr << "[" << source << "] BarBidiStream started" << std::endl;
        Request req;
        while (stream->Read(&req)) {
            std::cerr << "[" << source << "] BarBidiStream received: " << req.name() << std::endl;
            Response response;
            response.set_message("Echo: " + req.name());
            response.set_from(source);
            if (!stream->Write(response)) break;
        }
    }
};

#endif // SYNURANG_GREETER_SERVICE_H_
