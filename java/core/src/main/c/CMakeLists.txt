cmake_minimum_required(VERSION 3.10)
project(synurang_jni LANGUAGES C)

get_filename_component(SYNURANG_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
add_library(synurang_jni SHARED synurang_jni.c synurang_module_jni.c
    "${SYNURANG_ROOT}/src/module_host.c")
target_include_directories(synurang_jni PRIVATE "${SYNURANG_ROOT}/include")
if(NOT WIN32)
    find_package(Threads REQUIRED)
    target_link_libraries(synurang_jni Threads::Threads)
endif()

if(ANDROID)
    # NDK provides jni.h automatically — no find_package needed
    target_link_libraries(synurang_jni log)
elseif(WIN32)
    if(SYNURANG_JNI_INCLUDE)
        # Cross-compiling with MinGW — use supplied JNI headers
        target_include_directories(synurang_jni PRIVATE ${SYNURANG_JNI_INCLUDE})
    else()
        find_package(JNI REQUIRED)
        target_include_directories(synurang_jni PRIVATE ${JNI_INCLUDE_DIRS})
    endif()
    # kernel32 (LoadLibrary/GetProcAddress) is linked implicitly
else()
    find_package(JNI REQUIRED)
    target_include_directories(synurang_jni PRIVATE ${JNI_INCLUDE_DIRS})
    if(UNIX AND NOT APPLE)
        target_link_libraries(synurang_jni dl)
    endif()
endif()
