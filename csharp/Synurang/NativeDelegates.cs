using System;
using System.Runtime.InteropServices;

namespace Synurang;

// char* Synurang_Invoke_<Service>(char* method, char* data, int data_len, int* resp_len)
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
internal delegate IntPtr InvokeDelegate(IntPtr method, IntPtr data, int dataLen, out int respLen);

// void Synurang_Free(char* ptr)
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
internal delegate void FreeDelegate(IntPtr ptr);

// uint64_t Synurang_Stream_<Service>_Open(char* method)
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
internal delegate ulong StreamOpenDelegate(IntPtr method);

// int Synurang_Stream_Send(uint64_t handle, char* data, int data_len)
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
internal delegate int StreamSendDelegate(ulong handle, IntPtr data, int dataLen);

// char* Synurang_Stream_Recv(uint64_t handle, int* resp_len, int* status)
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
internal delegate IntPtr StreamRecvDelegate(ulong handle, out int respLen, out int status);

// void Synurang_Stream_CloseSend(uint64_t handle)
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
internal delegate void StreamCloseSendDelegate(ulong handle);

// void Synurang_Stream_Close(uint64_t handle)
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
internal delegate void StreamCloseDelegate(ulong handle);
