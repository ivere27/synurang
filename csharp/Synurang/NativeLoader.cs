using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Synurang;

/// <summary>
/// Cross-platform native library loader and interop compatibility helpers.
/// Uses NativeLibrary on .NET Core 3.0+, kernel32 P/Invoke on .NET Framework (Windows XP+).
/// </summary>
internal static class NativeLoader
{
    // =========================================================================
    // Library Loading
    // =========================================================================

#if NETCOREAPP3_0_OR_GREATER
    public static IntPtr LoadLibrary(string path) => NativeLibrary.Load(path);
    public static IntPtr GetExport(IntPtr handle, string name) => NativeLibrary.GetExport(handle, name);
    public static void FreeLibrary(IntPtr handle) => NativeLibrary.Free(handle);
#elif NETFRAMEWORK
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "LoadLibraryW")]
    private static extern IntPtr Kernel32_LoadLibrary(string lpFileName);

    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Ansi, ExactSpelling = true, EntryPoint = "GetProcAddress")]
    private static extern IntPtr Kernel32_GetProcAddress(IntPtr hModule, string lpProcName);

    [DllImport("kernel32", SetLastError = true, EntryPoint = "FreeLibrary")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Kernel32_FreeLibrary(IntPtr hModule);

    public static IntPtr LoadLibrary(string path)
    {
        IntPtr handle = Kernel32_LoadLibrary(path);
        if (handle == IntPtr.Zero)
        {
            int error = Marshal.GetLastWin32Error();
            throw new DllNotFoundException($"Failed to load library '{path}' (Win32 error {error})");
        }
        return handle;
    }

    public static IntPtr GetExport(IntPtr handle, string name)
    {
        IntPtr sym = Kernel32_GetProcAddress(handle, name);
        if (sym == IntPtr.Zero)
            throw new EntryPointNotFoundException($"Symbol not found: {name}");
        return sym;
    }

    public static void FreeLibrary(IntPtr handle)
    {
        Kernel32_FreeLibrary(handle);
    }
#endif

    // =========================================================================
    // Delegate creation (generic version requires .NET 4.5.1+ / .NET Core 1.0+)
    // =========================================================================

    public static T GetDelegate<T>(IntPtr functionPointer) where T : Delegate
    {
#if NETCOREAPP || NET45_OR_GREATER
        return Marshal.GetDelegateForFunctionPointer<T>(functionPointer);
#else
        return (T)Marshal.GetDelegateForFunctionPointer(functionPointer, typeof(T));
#endif
    }

    // =========================================================================
    // UTF-8 string marshaling (Marshal.StringToCoTaskMemUTF8 requires .NET Core 3.0+)
    // =========================================================================

    public static IntPtr StringToCoTaskMemUTF8(string str)
    {
#if NETCOREAPP3_0_OR_GREATER
        return Marshal.StringToCoTaskMemUTF8(str);
#else
        if (str == null) return IntPtr.Zero;
        byte[] bytes = Encoding.UTF8.GetBytes(str);
        IntPtr ptr = Marshal.AllocCoTaskMem(bytes.Length + 1);
        Marshal.Copy(bytes, 0, ptr, bytes.Length);
        Marshal.WriteByte(ptr, bytes.Length, 0); // null terminator
        return ptr;
#endif
    }

    // =========================================================================
    // Volatile read (Volatile class requires .NET 4.5+ / .NET Core 1.0+)
    // =========================================================================

    public static int VolatileRead(ref int location)
    {
#if NET45_OR_GREATER || NETCOREAPP
        return Volatile.Read(ref location);
#else
#pragma warning disable CS0420 // reference to volatile field
        return Thread.VolatileRead(ref location);
#pragma warning restore CS0420
#endif
    }
}
