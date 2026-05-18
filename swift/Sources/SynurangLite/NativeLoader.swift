import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

/// Error thrown by `NativeLoader` when a dlopen / dlsym fails.
public struct NativeLoaderError: Error, CustomStringConvertible {
    public let detail: String
    public init(_ detail: String) { self.detail = detail }
    public var description: String { detail }
    public var localizedDescription: String { detail }
}

/// Cross-platform thin wrapper around `dlopen` / `dlsym` / `dlclose`.
///
/// On Darwin/Linux uses libdl. On Windows uses LoadLibraryW / GetProcAddress
/// (best-effort — the primary platforms for Phase A are iOS/macOS).
///
/// "Attach to process" returns a sentinel handle (Darwin: `RTLD_DEFAULT`,
/// Linux: `RTLD_DEFAULT`) and is used by XCFramework consumers that statically
/// link the Synurang C ABI symbols into the main image.
public enum NativeLoader {

    // MARK: - Library handle abstraction

    /// Opaque handle representing a loaded module. On Unix this is the
    /// raw dlopen handle; on Windows it is the HMODULE.
    public typealias Handle = UnsafeMutableRawPointer

    // MARK: - Loading

    public static func load(_ path: String) throws -> Handle {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw NativeLoaderError("dlopen('\(path)') failed: \(dlerrorString())")
        }
        return handle
        #elseif canImport(WinSDK)
        return try path.withCString(encodedAs: UTF16.self) { wpath -> Handle in
            guard let h = LoadLibraryW(wpath) else {
                throw NativeLoaderError("LoadLibraryW('\(path)') failed (Win32 error \(GetLastError()))")
            }
            return UnsafeMutableRawPointer(h)
        }
        #else
        throw NativeLoaderError("native loading unsupported on this platform")
        #endif
    }

    /// Returns a sentinel handle that resolves symbols against the host
    /// process image (statically linked C ABI).
    public static func loadProcess() -> Handle? {
        #if canImport(Darwin)
        // RTLD_DEFAULT on Darwin is the macro `((void *) -2)`. Re-create that
        // value here since Swift's Darwin shim does not export the macro.
        return UnsafeMutableRawPointer(bitPattern: -2)
        #elseif canImport(Glibc) || canImport(Musl)
        // RTLD_DEFAULT on Linux is `((void *) 0)`. Some libc variants do not
        // expose the symbol via Swift; the literal works on every glibc/musl.
        return UnsafeMutableRawPointer(bitPattern: 0)
        #elseif canImport(WinSDK)
        if let h = GetModuleHandleW(nil) {
            return UnsafeMutableRawPointer(h)
        }
        return nil
        #else
        return nil
        #endif
    }

    public static func resolve(_ name: String, in handle: Handle?) throws -> UnsafeMutableRawPointer {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        // dlsym accepts RTLD_DEFAULT/RTLD_NEXT as special handles. Swift's
        // overlay types these as UnsafeMutableRawPointer? so we forward as-is.
        guard let sym = dlsym(handle, name) else {
            throw NativeLoaderError("dlsym('\(name)') failed: \(dlerrorString())")
        }
        return sym
        #elseif canImport(WinSDK)
        guard let h = handle else {
            throw NativeLoaderError("GetProcAddress('\(name)') failed: null module handle")
        }
        guard let sym = GetProcAddress(HMODULE(h), name) else {
            throw NativeLoaderError("GetProcAddress('\(name)') failed (Win32 error \(GetLastError()))")
        }
        return UnsafeMutableRawPointer(sym)
        #else
        throw NativeLoaderError("symbol resolution unsupported on this platform")
        #endif
    }

    public static func free(_ handle: Handle) {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        // RTLD_DEFAULT sentinels must not be dlclosed.
        let raw = Int(bitPattern: handle)
        if raw == 0 || raw == -2 { return }
        _ = dlclose(handle)
        #elseif canImport(WinSDK)
        FreeLibrary(HMODULE(handle))
        #endif
    }

    // MARK: - Internal

    private static func dlerrorString() -> String {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        if let raw = dlerror() {
            return String(cString: raw)
        }
        return "unknown error"
        #else
        return "unknown error"
        #endif
    }
}
