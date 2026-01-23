cmake_minimum_required(VERSION 3.10)

project(synurang_windows_plugin LANGUAGES CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

if(TARGET synurang)
  set(synurang_windows_bundled_libraries
    $<TARGET_FILE:synurang>
    PARENT_SCOPE
  )
endif()
