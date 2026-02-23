/*
 * Minimal jni_md.h for Windows — used when cross-compiling with MinGW
 * where a JDK is not installed. The real JDK's jni_md.h defines these
 * same types; this file provides just enough to compile synurang_jni.c.
 */

#ifndef _JAVASOFT_JNI_MD_H_
#define _JAVASOFT_JNI_MD_H_

#define JNIEXPORT __declspec(dllexport)
#define JNIIMPORT __declspec(dllimport)
#define JNICALL   __stdcall

typedef int    jint;
typedef long long jlong;
typedef signed char jbyte;

#endif /* _JAVASOFT_JNI_MD_H_ */
