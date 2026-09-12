#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "synurang/module_host.h"

#define JNI_FN(name) Java_io_github_ivere27_synurang_ModuleJni_##name
typedef struct ModuleContext {
    SynurangHost* host;
    JavaVM* vm;
    jobject callback;
    jmethodID wakeup;
} ModuleContext;
#define CONTEXT(value) ((ModuleContext*)(uintptr_t)(value))
#define HOST(value) ((value) == 0 ? NULL : CONTEXT(value)->host)

static void wakeup(void* data) {
    ModuleContext* context = (ModuleContext*)data;
    JNIEnv* env = NULL;
    int attached = (*context->vm)->GetEnv(context->vm, (void**)&env, JNI_VERSION_1_6) == JNI_EDETACHED;
    if (attached && (*context->vm)->AttachCurrentThreadAsDaemon(context->vm, (void**)&env, NULL) != JNI_OK) return;
    if (env != NULL) {
        (*env)->CallVoidMethod(env, context->callback, context->wakeup);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    }
    if (attached) (*context->vm)->DetachCurrentThread(context->vm);
}

JNIEXPORT void JNICALL JNI_FN(setWakeup)(JNIEnv* env, jclass cls, jlong host, jobject callback) {
    ModuleContext* context = CONTEXT(host);
    jclass type = (*env)->GetObjectClass(env, callback);
    (void)cls;
    (*env)->GetJavaVM(env, &context->vm);
    context->callback = (*env)->NewGlobalRef(env, callback);
    context->wakeup = (*env)->GetMethodID(env, type, "wakeup", "()V");
    (*env)->DeleteLocalRef(env, type);
    if (context->callback != NULL && context->wakeup != NULL)
        synurang_host_set_wakeup(context->host, wakeup, context);
}

static void fail(JNIEnv* env, const char* message) {
    jclass cls = (*env)->FindClass(env, "java/lang/IllegalStateException");
    if (cls != NULL) (*env)->ThrowNew(env, cls, message);
}

static char* utf8(JNIEnv* env, jbyteArray value) {
    jsize size = (*env)->GetArrayLength(env, value);
    char* copy = (char*)malloc((size_t)size + 1u);
    if (copy == NULL) { fail(env, "Out of memory"); return NULL; }
    (*env)->GetByteArrayRegion(env, value, 0, size, (jbyte*)copy);
    if ((*env)->ExceptionCheck(env)) { free(copy); return NULL; }
    copy[size] = '\0';
    if (memchr(copy, '\0', (size_t)size) != NULL) {
        free(copy); fail(env, "Embedded NUL in module path or method"); return NULL;
    }
    return copy;
}

JNIEXPORT jlong JNICALL JNI_FN(load)(JNIEnv* env, jclass cls, jbyteArray path, jbyteArray symbol) {
    char* module_path = utf8(env, path);
    char* accessor;
    SynurangHost* host;
    ModuleContext* context;
    (void)cls;
    if (module_path == NULL) return 0;
    accessor = utf8(env, symbol);
    if (accessor == NULL) { free(module_path); return 0; }
    context = (ModuleContext*)calloc(1, sizeof(*context));
    if (context == NULL) { free(module_path); free(accessor); fail(env, "Out of memory"); return 0; }
    host = synurang_host_load(module_path, accessor, NULL);
    free(module_path); free(accessor);
    if (host == NULL) { free(context); fail(env, synurang_host_error()); return 0; }
    context->host = host;
    return (jlong)(uintptr_t)context;
}

JNIEXPORT jlong JNICALL JNI_FN(open)(JNIEnv* env, jclass cls, jlong host,
        jbyteArray method, jboolean request_stream, jboolean response_stream, jlong timeout) {
    char* name = utf8(env, method);
    SynurangCallOptions options = {sizeof(options), request_stream ? 1u : 0u,
        response_stream ? 1u : 0u, 0, (uint64_t)timeout};
    uint64_t call;
    (void)cls;
    if (name == NULL) return 0;
    call = synurang_host_open(HOST(host), name, &options);
    free(name);
    return (jlong)call;
}

JNIEXPORT jint JNICALL JNI_FN(send)(JNIEnv* env, jclass cls, jlong host, jlong call, jbyteArray data) {
    jsize size = (*env)->GetArrayLength(env, data);
    jbyte* bytes = (*env)->GetByteArrayElements(env, data, NULL);
    int result;
    (void)cls;
    if (bytes == NULL) return -5;
    result = synurang_host_send(HOST(host), (uint64_t)call, (const uint8_t*)bytes, (uint32_t)size);
    (*env)->ReleaseByteArrayElements(env, data, bytes, JNI_ABORT);
    return result;
}

JNIEXPORT jint JNICALL JNI_FN(halfClose)(JNIEnv* env, jclass cls, jlong host, jlong call) {
    (void)env; (void)cls;
    return synurang_host_half_close(HOST(host), (uint64_t)call);
}

JNIEXPORT jobject JNICALL JNI_FN(receive)(JNIEnv* env, jclass cls, jlong host, jlong call) {
    SynurangReadResult result;
    int status = synurang_host_receive(HOST(host), (uint64_t)call, &result);
    jbyteArray data;
    jclass read_class;
    jmethodID constructor;
    (void)cls;
    if (result.size > INT32_MAX) {
        synurang_host_free(HOST(host), result.data);
        fail(env, "Module message exceeds JVM array limit"); return NULL;
    }
    data = (*env)->NewByteArray(env, (jsize)result.size);
    if (data != NULL && result.size != 0)
        (*env)->SetByteArrayRegion(env, data, 0, (jsize)result.size, (const jbyte*)result.data);
    if (result.data != NULL) synurang_host_free(HOST(host), result.data);
    if ((*env)->ExceptionCheck(env)) return NULL;
    read_class = (*env)->FindClass(env, "io/github/ivere27/synurang/ModuleJni$Read");
    if (read_class == NULL) return NULL;
    constructor = (*env)->GetMethodID(env, read_class, "<init>", "(III[B)V");
    if (constructor == NULL) return NULL;
    return (*env)->NewObject(env, read_class, constructor, status, (jint)result.kind, result.code, data);
}

JNIEXPORT jint JNICALL JNI_FN(cancel)(JNIEnv* env, jclass cls, jlong host, jlong call, jint code) {
    (void)env; (void)cls;
    return synurang_host_cancel(HOST(host), (uint64_t)call, code);
}
JNIEXPORT void JNICALL JNI_FN(release)(JNIEnv* env, jclass cls, jlong host, jlong call) {
    (void)env; (void)cls;
    synurang_host_release(HOST(host), (uint64_t)call);
}
JNIEXPORT void JNICALL JNI_FN(poll)(JNIEnv* env, jclass cls, jlong host, jint budget) {
    (void)env; (void)cls;
    (void)synurang_host_poll(HOST(host), (uint32_t)budget);
}
JNIEXPORT jboolean JNICALL JNI_FN(hasWork)(JNIEnv* env, jclass cls, jlong host) {
    (void)env; (void)cls;
    return synurang_host_has_work(HOST(host)) ? JNI_TRUE : JNI_FALSE;
}
JNIEXPORT jint JNICALL JNI_FN(destroy)(JNIEnv* env, jclass cls, jlong host) {
    if (host == 0) return 0;
    int status = synurang_host_destroy(HOST(host));
    (void)cls;
    if (status == 0) {
        if (CONTEXT(host)->callback != NULL) (*env)->DeleteGlobalRef(env, CONTEXT(host)->callback);
        free(CONTEXT(host));
    }
    return status;
}
