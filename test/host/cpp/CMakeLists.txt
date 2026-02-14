cmake_minimum_required(VERSION 3.16)
project(synurang_cpp_host_test)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
option(ENABLE_PROCESS_BRUTE "Build process-mode brute-force host target" OFF)

# Include paths
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/../../../include)

# Source files
set(HOST_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../src/plugin_host_unix.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../src/plugin_host_windows.cpp
)

set(PROCESS_HOST_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../src/process_host_unix.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../src/process_host_windows.cpp
)

# Test executable
add_executable(test_cpp_host main.cpp ${HOST_SOURCES})

# Link libraries
if(UNIX AND NOT APPLE)
    target_link_libraries(test_cpp_host dl pthread)
elseif(APPLE)
    target_link_libraries(test_cpp_host pthread)
endif()

# Output to bin directory
set_target_properties(test_cpp_host PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../../../bin"
)

# Brute-force chaos test executable
add_executable(brute_cpp_host brute.cpp ${HOST_SOURCES})

if(UNIX AND NOT APPLE)
    target_link_libraries(brute_cpp_host dl pthread)
elseif(APPLE)
    target_link_libraries(brute_cpp_host pthread)
endif()

set_target_properties(brute_cpp_host PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../../../bin"
)

if(ENABLE_PROCESS_BRUTE)
    find_package(Protobuf REQUIRED)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(GRPC REQUIRED grpc++)
    find_program(GRPC_CPP_PLUGIN grpc_cpp_plugin)

    if(NOT GRPC_CPP_PLUGIN)
        message(FATAL_ERROR "grpc_cpp_plugin not found in PATH")
    endif()

    set(API_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../api)
    set(EXAMPLE_API_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../example/api)
    set(PROTO_OUT_DIR ${CMAKE_CURRENT_BINARY_DIR}/process_proto)
    file(MAKE_DIRECTORY ${PROTO_OUT_DIR})

    set(PROTO_SRCS
        ${PROTO_OUT_DIR}/example.pb.cc
        ${PROTO_OUT_DIR}/example.grpc.pb.cc
        ${PROTO_OUT_DIR}/core.pb.cc
        ${PROTO_OUT_DIR}/core.grpc.pb.cc
    )
    set(PROTO_HDRS
        ${PROTO_OUT_DIR}/example.pb.h
        ${PROTO_OUT_DIR}/example.grpc.pb.h
        ${PROTO_OUT_DIR}/core.pb.h
        ${PROTO_OUT_DIR}/core.grpc.pb.h
    )

    add_custom_command(
        OUTPUT ${PROTO_SRCS} ${PROTO_HDRS}
        COMMAND ${Protobuf_PROTOC_EXECUTABLE}
        ARGS
            --cpp_out=${PROTO_OUT_DIR}
            --grpc_out=${PROTO_OUT_DIR}
            --plugin=protoc-gen-grpc=${GRPC_CPP_PLUGIN}
            -I${EXAMPLE_API_DIR}
            -I${API_DIR}
            ${EXAMPLE_API_DIR}/example.proto
            ${API_DIR}/core.proto
        DEPENDS
            ${EXAMPLE_API_DIR}/example.proto
            ${API_DIR}/core.proto
        COMMENT "Generating process-mode protobuf/grpc C++ sources"
    )

    add_executable(
        brute_cpp_process_host
        brute_process.cpp
        ${PROCESS_HOST_SOURCES}
        ${PROTO_SRCS}
    )

    target_include_directories(brute_cpp_process_host PRIVATE
        ${PROTO_OUT_DIR}
        ${Protobuf_INCLUDE_DIRS}
        ${GRPC_INCLUDE_DIRS}
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../include
    )

    target_link_libraries(brute_cpp_process_host
        ${Protobuf_LIBRARIES}
        ${GRPC_LIBRARIES}
    )

    if(UNIX AND NOT APPLE)
        target_link_libraries(brute_cpp_process_host dl pthread)
    elseif(APPLE)
        target_link_libraries(brute_cpp_process_host pthread)
    endif()

    set_target_properties(brute_cpp_process_host PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../../../bin"
    )
endif()
