package io.github.ivere27.synurang;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

/**
 * Loads the synurang_jni native library with automatic extraction from JAR resources.
 * <p>
 * Load order:
 * <ol>
 *   <li>System property {@code synurang.library.path} — direct path to the native lib</li>
 *   <li>JAR resource {@code /native/{os}-{arch}/{libname}} — extract to temp dir</li>
 *   <li>Fallback: {@code System.loadLibrary("synurang_jni")} (Android / manual {@code -Djava.library.path})</li>
 * </ol>
 */
class NativeLibLoader {
    private static volatile boolean loaded;

    static synchronized void load() {
        if (loaded) return;

        // 1. Explicit path via system property
        String explicitPath = System.getProperty("synurang.library.path");
        if (explicitPath != null && !explicitPath.isEmpty()) {
            System.load(explicitPath);
            loaded = true;
            return;
        }

        // 2. Try extracting from JAR resource
        String resource = nativeResourcePath();
        if (resource != null) {
            try (InputStream in = NativeLibLoader.class.getResourceAsStream(resource)) {
                if (in != null) {
                    Path tempDir = Files.createTempDirectory("synurang-jni-");
                    File tempFile = new File(tempDir.toFile(), resourceFileName(resource));
                    tempFile.deleteOnExit();
                    tempDir.toFile().deleteOnExit();
                    Files.copy(in, tempFile.toPath(), StandardCopyOption.REPLACE_EXISTING);
                    System.load(tempFile.getAbsolutePath());
                    loaded = true;
                    return;
                }
            } catch (IOException | UnsatisfiedLinkError ignored) {
                // Fall through to System.loadLibrary
            }
        }

        // 3. Fallback: standard library path (Android, manual -Djava.library.path)
        System.loadLibrary("synurang_jni");
        loaded = true;
    }

    private static String nativeResourcePath() {
        String os = detectOS();
        String arch = detectArch();
        if (os == null || arch == null) return null;

        String libName;
        if ("windows".equals(os)) {
            libName = "synurang_jni.dll";
        } else if ("macos".equals(os)) {
            libName = "libsynurang_jni.dylib";
        } else {
            libName = "libsynurang_jni.so";
        }
        return "/native/" + os + "-" + arch + "/" + libName;
    }

    private static String resourceFileName(String resourcePath) {
        int idx = resourcePath.lastIndexOf('/');
        return idx >= 0 ? resourcePath.substring(idx + 1) : resourcePath;
    }

    private static String detectOS() {
        String name = System.getProperty("os.name", "").toLowerCase();
        if (name.contains("linux")) return "linux";
        if (name.contains("mac") || name.contains("darwin")) return "macos";
        if (name.contains("win")) return "windows";
        return null;
    }

    private static String detectArch() {
        String arch = System.getProperty("os.arch", "").toLowerCase();
        if (arch.equals("amd64") || arch.equals("x86_64")) return "x86_64";
        if (arch.equals("x86") || arch.equals("i386") || arch.equals("i686")) return "x86";
        if (arch.equals("arm") || arch.equals("armv7l") || arch.equals("armhf")) return "armv7";
        if (arch.equals("aarch64") || arch.equals("arm64")) return "aarch64";
        return null;
    }
}
