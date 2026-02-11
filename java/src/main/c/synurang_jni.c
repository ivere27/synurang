// Synurang JNI Native Layer
//
// Thin C wrapper (~250 lines) providing JNI bindings for dlopen/dlsym
// and the Synurang plugin C ABI.
//
// Function pointer signatures match the C ABI from src/plugin_host_unix.cpp:
//   Invoke:  char* fn(char* method, char* data, int data_len, int* resp_len)
//   Free:    void  fn(char* ptr)
//   Stream:  uint64_t open(char* method)
//            int send(uint64_t handle, char* data, int data_len)
//            char* recv(uint64_t handle, int* resp_len, int* status)
//            void close_send(uint64_t handle)
//            void close(uint64_t handle)
//
// Response format: [status:1byte][payload...]
//   status=0: success, payload is protobuf
//   status=1: error, payload is error string
//
// Stream recv status: 0=data, 1=EOF, 2+=error

#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>

#ifndef _WIN32
#include <dlfcn.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <signal.h>
#include <sys/time.h>
#include <sys/syscall.h>

// close_range() syscall (Linux 5.9+, glibc 2.34+)
#ifndef __NR_close_range
#define __NR_close_range 436
#endif
#endif

// FFI function pointer types matching Synurang exports
typedef char* (*synurang_invoke_func)(char* method, char* data, int data_len, int* resp_len);
typedef void (*synurang_free_func)(char* ptr);
typedef uint64_t (*synurang_stream_open_func)(char* method);
typedef int (*synurang_stream_send_func)(uint64_t handle, char* data, int data_len);
typedef char* (*synurang_stream_recv_func)(uint64_t handle, int* resp_len, int* status);
typedef void (*synurang_stream_close_send_func)(uint64_t handle);
typedef void (*synurang_stream_close_func)(uint64_t handle);

// Helper: throw a Java PluginError exception
static void throw_plugin_error(JNIEnv *env, const char *msg) {
    jclass cls = (*env)->FindClass(env, "io/github/ivere27/synurang/PluginError");
    if (cls != NULL) {
        (*env)->ThrowNew(env, cls, msg);
    }
}

// =============================================================================
// Plugin Loading
// =============================================================================

JNIEXPORT jlong JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeOpen(JNIEnv *env, jclass clazz, jstring path) {
#ifdef _WIN32
    throw_plugin_error(env, "Windows not supported in JNI layer");
    return 0;
#else
    const char *c_path = (*env)->GetStringUTFChars(env, path, NULL);
    if (c_path == NULL) return 0;

    void *handle = dlopen(c_path, RTLD_LAZY);
    (*env)->ReleaseStringUTFChars(env, path, c_path);

    if (handle == NULL) {
        throw_plugin_error(env, dlerror());
        return 0;
    }
    return (jlong)(uintptr_t)handle;
#endif
}

JNIEXPORT void JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeClose(JNIEnv *env, jclass clazz, jlong handle) {
#ifndef _WIN32
    if (handle != 0) {
        dlclose((void *)(uintptr_t)handle);
    }
#endif
}

JNIEXPORT jlong JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeLookupSymbol(JNIEnv *env, jclass clazz, jlong handle, jstring name) {
#ifdef _WIN32
    return 0;
#else
    const char *c_name = (*env)->GetStringUTFChars(env, name, NULL);
    if (c_name == NULL) return 0;

    void *sym = dlsym((void *)(uintptr_t)handle, c_name);
    (*env)->ReleaseStringUTFChars(env, name, c_name);

    return (jlong)(uintptr_t)sym;
#endif
}

// =============================================================================
// Unary RPC
// =============================================================================

JNIEXPORT jbyteArray JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeInvoke(
    JNIEnv *env, jclass clazz,
    jlong invokePtr, jlong freePtr,
    jstring method, jbyteArray data
) {
    synurang_invoke_func invoke_fn = (synurang_invoke_func)(uintptr_t)invokePtr;
    synurang_free_func free_fn = (synurang_free_func)(uintptr_t)freePtr;

    // Convert method string
    const char *c_method = (*env)->GetStringUTFChars(env, method, NULL);
    if (c_method == NULL) return NULL;

    // Convert data bytes
    char *c_data = NULL;
    int data_len = 0;
    if (data != NULL) {
        data_len = (*env)->GetArrayLength(env, data);
        if (data_len > 0) {
            c_data = (char *)malloc(data_len);
            if (c_data == NULL) {
                (*env)->ReleaseStringUTFChars(env, method, c_method);
                throw_plugin_error(env, "malloc failed");
                return NULL;
            }
            (*env)->GetByteArrayRegion(env, data, 0, data_len, (jbyte *)c_data);
        }
    }

    // Call the plugin
    int resp_len = 0;
    char *resp = invoke_fn((char *)c_method, c_data, data_len, &resp_len);

    (*env)->ReleaseStringUTFChars(env, method, c_method);
    free(c_data);

    if (resp == NULL) {
        throw_plugin_error(env, "plugin returned null");
        return NULL;
    }

    // Copy response to Java byte array
    jbyteArray result = (*env)->NewByteArray(env, resp_len);
    if (result != NULL && resp_len > 0) {
        (*env)->SetByteArrayRegion(env, result, 0, resp_len, (jbyte *)resp);
    }

    free_fn(resp);
    return result;
}

// =============================================================================
// Streaming
// =============================================================================

JNIEXPORT jlong JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeStreamOpen(
    JNIEnv *env, jclass clazz,
    jlong openPtr, jstring method
) {
    synurang_stream_open_func open_fn = (synurang_stream_open_func)(uintptr_t)openPtr;

    const char *c_method = (*env)->GetStringUTFChars(env, method, NULL);
    if (c_method == NULL) return 0;

    uint64_t handle = open_fn((char *)c_method);
    (*env)->ReleaseStringUTFChars(env, method, c_method);

    return (jlong)handle;
}

JNIEXPORT jint JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeStreamSend(
    JNIEnv *env, jclass clazz,
    jlong sendPtr, jlong handle, jbyteArray data
) {
    synurang_stream_send_func send_fn = (synurang_stream_send_func)(uintptr_t)sendPtr;

    char *c_data = NULL;
    int data_len = 0;
    if (data != NULL) {
        data_len = (*env)->GetArrayLength(env, data);
        if (data_len > 0) {
            c_data = (char *)malloc(data_len);
            if (c_data == NULL) {
                throw_plugin_error(env, "malloc failed");
                return -1;
            }
            (*env)->GetByteArrayRegion(env, data, 0, data_len, (jbyte *)c_data);
        }
    }

    int result = send_fn((uint64_t)handle, c_data, data_len);
    free(c_data);

    return (jint)result;
}

JNIEXPORT jbyteArray JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeStreamRecv(
    JNIEnv *env, jclass clazz,
    jlong recvPtr, jlong freePtr, jlong handle
) {
    synurang_stream_recv_func recv_fn = (synurang_stream_recv_func)(uintptr_t)recvPtr;
    synurang_free_func free_fn = (synurang_free_func)(uintptr_t)freePtr;

    int resp_len = 0;
    int status = 0;
    char *resp = recv_fn((uint64_t)handle, &resp_len, &status);

    // status=1 means EOF -> return null
    if (status == 1) {
        if (resp != NULL) free_fn(resp);
        return NULL;
    }

    // status >= 2 means error
    if (status >= 2) {
        if (resp != NULL && resp_len > 0) {
            // Error message is in resp
            char *msg = (char *)malloc(resp_len + 1);
            if (msg != NULL) {
                memcpy(msg, resp, resp_len);
                msg[resp_len] = '\0';
                throw_plugin_error(env, msg);
                free(msg);
            }
            free_fn(resp);
        } else {
            throw_plugin_error(env, "stream error");
        }
        return NULL;
    }

    // status=0 means data
    if (resp == NULL || resp_len == 0) {
        throw_plugin_error(env, "empty stream response");
        return NULL;
    }

    jbyteArray result = (*env)->NewByteArray(env, resp_len);
    if (result != NULL && resp_len > 0) {
        (*env)->SetByteArrayRegion(env, result, 0, resp_len, (jbyte *)resp);
    }

    free_fn(resp);
    return result;
}

JNIEXPORT void JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeStreamCloseSend(
    JNIEnv *env, jclass clazz,
    jlong closeSendPtr, jlong handle
) {
    synurang_stream_close_send_func fn = (synurang_stream_close_send_func)(uintptr_t)closeSendPtr;
    fn((uint64_t)handle);
}

JNIEXPORT void JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeStreamClose(
    JNIEnv *env, jclass clazz,
    jlong closePtr, jlong handle
) {
    synurang_stream_close_func fn = (synurang_stream_close_func)(uintptr_t)closePtr;
    fn((uint64_t)handle);
}

// =============================================================================
// Process Host — socketpair + fork/exec
// =============================================================================

#ifndef _WIN32

JNIEXPORT jintArray JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeSocketpair(JNIEnv *env, jclass clazz) {
    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) < 0) {
        throw_plugin_error(env, strerror(errno));
        return NULL;
    }
    jint jfds[2] = { fds[0], fds[1] };
    jintArray result = (*env)->NewIntArray(env, 2);
    if (result != NULL) {
        (*env)->SetIntArrayRegion(env, result, 0, 2, jfds);
    }
    return result;
}

JNIEXPORT jint JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeForkExec(
    JNIEnv *env, jclass clazz,
    jstring executable, jobjectArray args, jint childFd
) {
    const char *c_exec = (*env)->GetStringUTFChars(env, executable, NULL);
    if (c_exec == NULL) return -1;

    int argc = args != NULL ? (*env)->GetArrayLength(env, args) : 0;

    // Build argv: [executable, args..., NULL]
    const char **argv = (const char **)malloc(sizeof(char *) * (argc + 2));
    if (argv == NULL) {
        (*env)->ReleaseStringUTFChars(env, executable, c_exec);
        throw_plugin_error(env, "malloc failed");
        return -1;
    }
    argv[0] = c_exec;
    for (int i = 0; i < argc; i++) {
        jstring arg = (jstring)(*env)->GetObjectArrayElement(env, args, i);
        argv[i + 1] = (*env)->GetStringUTFChars(env, arg, NULL);
    }
    argv[argc + 1] = NULL;

    // Build envp: copy current environ, replace/add SYNURANG_IPC=3
    extern char **environ;
    int env_count = 0;
    while (environ[env_count]) env_count++;

    char **envp = (char **)malloc(sizeof(char *) * (env_count + 2));
    if (envp == NULL) {
        for (int i = 0; i < argc; i++) {
            jstring arg = (jstring)(*env)->GetObjectArrayElement(env, args, i);
            (*env)->ReleaseStringUTFChars(env, arg, argv[i + 1]);
        }
        (*env)->ReleaseStringUTFChars(env, executable, c_exec);
        free(argv);
        throw_plugin_error(env, "malloc failed");
        return -1;
    }
    int j = 0;
    for (int i = 0; i < env_count; i++) {
        if (strncmp(environ[i], "SYNURANG_IPC=", 13) != 0) {
            envp[j++] = environ[i];
        }
    }
    envp[j++] = "SYNURANG_IPC=3";
    envp[j] = NULL;

    pid_t pid = fork();
    if (pid < 0) {
        int err = errno;
        for (int i = 0; i < argc; i++) {
            jstring arg = (jstring)(*env)->GetObjectArrayElement(env, args, i);
            (*env)->ReleaseStringUTFChars(env, arg, argv[i + 1]);
        }
        (*env)->ReleaseStringUTFChars(env, executable, c_exec);
        free(argv);
        free(envp);
        throw_plugin_error(env, strerror(err));
        return -1;
    }

    if (pid == 0) {
        // Child process — only async-signal-safe functions from here

        // Dup child fd to 3
        if (childFd != 3) {
            dup2(childFd, 3);
            close(childFd);
        }

        // Close all fds > 3 to prevent leaking parent's fds.
        // Try close_range() syscall first (Linux 5.9+), fall back to loop.
        if (syscall(__NR_close_range, 4, ~0U, 0) != 0) {
            long maxfd = sysconf(_SC_OPEN_MAX);
            if (maxfd < 0) maxfd = 1024;
            for (int fd = 4; fd < maxfd; fd++) {
                close(fd);
            }
        }

        // execve with explicit envp (setenv is not async-signal-safe)
        execve(c_exec, (char *const *)argv, envp);
        _exit(127);  // exec failed
    }

    // Parent — release JNI strings
    for (int i = 0; i < argc; i++) {
        jstring arg = (jstring)(*env)->GetObjectArrayElement(env, args, i);
        (*env)->ReleaseStringUTFChars(env, arg, argv[i + 1]);
    }
    (*env)->ReleaseStringUTFChars(env, executable, c_exec);
    free(argv);
    free(envp);

    // Close child's end in parent
    close(childFd);

    return (jint)pid;
}

JNIEXPORT void JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeKill(
    JNIEnv *env, jclass clazz, jint pid, jint sig
) {
    kill((pid_t)pid, sig);
}

JNIEXPORT jint JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeWaitPid(
    JNIEnv *env, jclass clazz, jint pid
) {
    int status;
    if (waitpid((pid_t)pid, &status, 0) < 0) {
        return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

JNIEXPORT jboolean JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeIsAlive(
    JNIEnv *env, jclass clazz, jint pid
) {
    return kill((pid_t)pid, 0) == 0 ? JNI_TRUE : JNI_FALSE;
}

// =============================================================================
// Raw fd I/O — for SocketPairSocket
// =============================================================================

JNIEXPORT jint JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeReadFd(
    JNIEnv *env, jclass clazz,
    jint fd, jbyteArray buf, jint offset, jint len
) {
    char *c_buf = (char *)malloc(len);
    if (c_buf == NULL) {
        throw_plugin_error(env, "malloc failed");
        return -1;
    }

    ssize_t n = read(fd, c_buf, len);
    if (n > 0) {
        (*env)->SetByteArrayRegion(env, buf, offset, (jint)n, (jbyte *)c_buf);
    }
    free(c_buf);

    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            // Timeout (SO_RCVTIMEO expired)
            jclass cls = (*env)->FindClass(env, "java/net/SocketTimeoutException");
            if (cls != NULL) (*env)->ThrowNew(env, cls, "Read timed out");
            return -1;
        }
        throw_plugin_error(env, strerror(errno));
        return -1;
    }
    return (jint)n;  // 0 = EOF
}

JNIEXPORT void JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeWriteFd(
    JNIEnv *env, jclass clazz,
    jint fd, jbyteArray buf, jint offset, jint len
) {
    char *c_buf = (char *)malloc(len);
    if (c_buf == NULL) {
        throw_plugin_error(env, "malloc failed");
        return;
    }
    (*env)->GetByteArrayRegion(env, buf, offset, len, (jbyte *)c_buf);

    ssize_t written = 0;
    while (written < len) {
        ssize_t n = write(fd, c_buf + written, len - written);
        if (n < 0) {
            free(c_buf);
            throw_plugin_error(env, strerror(errno));
            return;
        }
        written += n;
    }
    free(c_buf);
}

JNIEXPORT void JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeCloseFd(
    JNIEnv *env, jclass clazz, jint fd
) {
    close(fd);
}

JNIEXPORT void JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeShutdownFd(
    JNIEnv *env, jclass clazz, jint fd, jint how
) {
    shutdown(fd, how);
}

JNIEXPORT void JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeSetSoTimeout(
    JNIEnv *env, jclass clazz, jint fd, jint timeoutMs
) {
    struct timeval tv;
    tv.tv_sec = timeoutMs / 1000;
    tv.tv_usec = (timeoutMs % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
}

JNIEXPORT jint JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeGetSoTimeout(
    JNIEnv *env, jclass clazz, jint fd
) {
    struct timeval tv;
    socklen_t len = sizeof(tv);
    if (getsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, &len) < 0) return 0;
    return (jint)(tv.tv_sec * 1000 + tv.tv_usec / 1000);
}

JNIEXPORT jint JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeGetRecvBufSize(
    JNIEnv *env, jclass clazz, jint fd
) {
    int size;
    socklen_t len = sizeof(size);
    if (getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, &len) < 0) return 8192;
    return (jint)size;
}

JNIEXPORT jint JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeGetSendBufSize(
    JNIEnv *env, jclass clazz, jint fd
) {
    int size;
    socklen_t len = sizeof(size);
    if (getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, &len) < 0) return 8192;
    return (jint)size;
}

JNIEXPORT void JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeSetRecvBufSize(
    JNIEnv *env, jclass clazz, jint fd, jint size
) {
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
}

JNIEXPORT void JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeSetSendBufSize(
    JNIEnv *env, jclass clazz, jint fd, jint size
) {
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
}

// =============================================================================
// Direct buffer address — for zero-copy native pointer access
// =============================================================================

JNIEXPORT jlong JNICALL
Java_io_github_ivere27_synurang_SynurangJni_nativeGetDirectBufferAddress(
    JNIEnv *env, jclass clazz, jobject buffer
) {
    void *addr = (*env)->GetDirectBufferAddress(env, buffer);
    if (addr == NULL) {
        throw_plugin_error(env, "Not a direct buffer or buffer is invalid");
        return 0;
    }
    return (jlong)(uintptr_t)addr;
}

#endif // !_WIN32
