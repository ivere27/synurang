cmake_minimum_required(VERSION 3.10)

project(synurang_windows_plugin LANGUAGES CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(_synurang_libraries $<TARGET_FILE:synurang_module_host>)
if(TARGET synurang)
  list(APPEND _synurang_libraries $<TARGET_FILE:synurang>)
endif()
set(synurang_windows_bundled_libraries ${_synurang_libraries} PARENT_SCOPE)
# Flutter's FFI plugin bundler uses the package name on every platform.
set(synurang_bundled_libraries ${_synurang_libraries} PARENT_SCOPE)
