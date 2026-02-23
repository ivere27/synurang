/*
 * Minimal jni_md.h for macOS — used when cross-compiling from Linux
 * where a macOS JDK is not installed. The real JDK's jni_md.h defines
 * these same types; this file provides just enough to compile synurang_jni.c.
 */

#ifndef _JAVASOFT_JNI_MD_H_
#define _JAVASOFT_JNI_MD_H_

#define JNIEXPORT __attribute__((visibility("default")))
#define JNIIMPORT
#define JNICALL

typedef int    jint;
typedef long   jlong;
typedef signed char jbyte;

#endif /* _JAVASOFT_JNI_MD_H_ */
