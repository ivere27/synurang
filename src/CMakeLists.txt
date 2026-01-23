# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(synurang_library VERSION 0.0.1 LANGUAGES C)

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
