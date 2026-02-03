cmake_minimum_required(VERSION 3.14)
project(synurang_cpp_plugin)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Find protobuf
find_package(Protobuf REQUIRED)

# Proto directories - paths relative to example/cpp/plugin/
set(API_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../api)
set(EXAMPLE_API_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../api)

# Proto files
set(PROTO_FILES ${EXAMPLE_API_DIR}/example.proto ${API_DIR}/core.proto)
set(PROTO_SRCS)
set(PROTO_HDRS)
foreach(PROTO_FILE ${PROTO_FILES})
    get_filename_component(PROTO_NAME ${PROTO_FILE} NAME_WE)
    list(APPEND PROTO_SRCS ${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.pb.cc)
    list(APPEND PROTO_HDRS ${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.pb.h)
    add_custom_command(
        OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.pb.cc ${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.pb.h
        COMMAND ${Protobuf_PROTOC_EXECUTABLE}
        ARGS --cpp_out=${CMAKE_CURRENT_BINARY_DIR}
             -I${EXAMPLE_API_DIR}
             -I${API_DIR}
             ${PROTO_FILE}
        DEPENDS ${PROTO_FILE}
        COMMENT "Generating C++ protobuf for ${PROTO_NAME}.proto"
    )
endforeach()

# Copy generated FFI plugin files (from protoc-gen-synurang-ffi)
# These should be generated separately and copied here
file(GLOB FFI_SRCS 
    ${CMAKE_CURRENT_SOURCE_DIR}/example_ffi_plugin.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/example_ffi_plugin.h
)

add_library(plugin SHARED
    main.cpp
    example_ffi_plugin.cc
    ${PROTO_SRCS}
)

target_include_directories(plugin PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${Protobuf_INCLUDE_DIRS}
)

target_link_libraries(plugin
    ${Protobuf_LIBRARIES}
    pthread
)

set_target_properties(plugin PROPERTIES
    OUTPUT_NAME "plugin"
    PREFIX "lib"
)
