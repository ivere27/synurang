cmake_minimum_required(VERSION 3.10)
project(synurang_jni LANGUAGES C)

add_library(synurang_jni SHARED synurang_jni.c)

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
