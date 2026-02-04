cmake_minimum_required(VERSION 3.16)
project(synurang_cpp_host_test)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Include paths
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/../../../include)

# Source files
set(HOST_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../src/plugin_host_unix.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../src/plugin_host_windows.cpp
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
