# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(synurang_library VERSION 0.0.1 LANGUAGES C)

# Pure-C service/stream runtime used by generated C bindings. It is kept as a
# separate target so applications can link it without the prebuilt Go library.
if(EMSCRIPTEN)
  set(_synurang_no_threads_default ON)
else()
  set(_synurang_no_threads_default OFF)
endif()
option(SYNURANG_C_RUNTIME_NO_THREADS
  "Build the C runtime with the manual-poll executor only"
  ${_synurang_no_threads_default})
unset(_synurang_no_threads_default)

add_library(synurang_c_runtime STATIC c_runtime.c)
add_library(synurang::c_runtime ALIAS synurang_c_runtime)
target_include_directories(synurang_c_runtime PUBLIC
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/../include>"
  "$<INSTALL_INTERFACE:include>"
)
set_target_properties(synurang_c_runtime PROPERTIES
  C_STANDARD 11
  C_STANDARD_REQUIRED ON
  POSITION_INDEPENDENT_CODE ON
)
if(SYNURANG_C_RUNTIME_NO_THREADS)
  target_compile_definitions(synurang_c_runtime
    PUBLIC SYNURANG_RUNTIME_NO_THREADS=1)
elseif(NOT WIN32)
  find_package(Threads REQUIRED)
  target_link_libraries(synurang_c_runtime PUBLIC Threads::Threads)
endif()

# synurang uses a prebuilt Go shared library
# The library is built via `make shared_linux` in the synurang package

IF(CMAKE_SYSTEM_NAME MATCHES "Linux")
  IF(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/libsynurang-linux-amd64.so")
    # Add the prebuilt Go shared library
    add_library(synurang SHARED IMPORTED GLOBAL)
    set_target_properties(synurang PROPERTIES
      IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/libsynurang-linux-amd64.so"
    )
  ENDIF()
ELSEIF(CMAKE_SYSTEM_NAME MATCHES "Android")
  # Android uses architecture-specific libraries
  if(${ANDROID_ABI} STREQUAL "arm64-v8a")
    add_library(synurang SHARED IMPORTED GLOBAL)
    set_target_properties(synurang PROPERTIES
      IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/libsynurang-android-arm64.so"
    )
  elseif(${ANDROID_ABI} STREQUAL "armeabi-v7a")
    add_library(synurang SHARED IMPORTED GLOBAL)
    set_target_properties(synurang PROPERTIES
      IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/libsynurang-android-arm.so"
    )
  elseif(${ANDROID_ABI} STREQUAL "x86_64")
    add_library(synurang SHARED IMPORTED GLOBAL)
    set_target_properties(synurang PROPERTIES
      IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/libsynurang-android-x86_64.so"
    )
  elseif(${ANDROID_ABI} STREQUAL "x86")
    add_library(synurang SHARED IMPORTED GLOBAL)
    set_target_properties(synurang PROPERTIES
      IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/libsynurang-android-x86.so"
    )
  else()
    message(FATAL_ERROR "Unsupported Android ABI: ${ANDROID_ABI}")
  endif()
ELSEIF(WIN32)
  IF(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/synurang.dll")
    add_library(synurang SHARED IMPORTED GLOBAL)
    set_target_properties(synurang PROPERTIES
      IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/synurang.dll"
      IMPORTED_IMPLIB "${CMAKE_CURRENT_SOURCE_DIR}/synurang.lib"
    )
  ENDIF()
ELSE()
  message(FATAL_ERROR "Unsupported platform: ${CMAKE_SYSTEM_NAME}")
ENDIF()
