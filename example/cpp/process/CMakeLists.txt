cmake_minimum_required(VERSION 3.14)
project(synurang_cpp_process)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Find dependencies
find_package(Protobuf REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(GRPC REQUIRED grpc++)

# Proto directories
set(API_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../api)
set(EXAMPLE_API_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../example/api)

# Generate proto files
set(PROTO_FILES ${EXAMPLE_API_DIR}/example.proto ${API_DIR}/core.proto ${API_DIR}/cache.proto)
set(PROTO_SRCS)
set(PROTO_HDRS)
foreach(PROTO_FILE ${PROTO_FILES})
    get_filename_component(PROTO_NAME ${PROTO_FILE} NAME_WE)
    list(APPEND PROTO_SRCS ${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.pb.cc)
    list(APPEND PROTO_HDRS ${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.pb.h)
    list(APPEND GRPC_SRCS ${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.grpc.pb.cc)
    add_custom_command(
        OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.pb.cc ${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.pb.h
               ${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.grpc.pb.cc ${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.grpc.pb.h
        COMMAND ${Protobuf_PROTOC_EXECUTABLE}
        ARGS --cpp_out=${CMAKE_CURRENT_BINARY_DIR}
             --grpc_out=${CMAKE_CURRENT_BINARY_DIR}
             --plugin=protoc-gen-grpc=/usr/bin/grpc_cpp_plugin
             -I${EXAMPLE_API_DIR}
             -I${API_DIR}
             ${PROTO_FILE}
        DEPENDS ${PROTO_FILE}
        COMMENT "Generating C++ protobuf+grpc for ${PROTO_NAME}.proto"
    )
endforeach()

add_executable(process_child
    main.cpp
    ${PROTO_SRCS}
    ${GRPC_SRCS}
)

target_include_directories(process_child PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${Protobuf_INCLUDE_DIRS}
    ${GRPC_INCLUDE_DIRS}
)

target_link_libraries(process_child
    ${Protobuf_LIBRARIES}
    ${GRPC_LIBRARIES}
)
