package io.github.ivere27.synurang;

/**
 * Exception thrown when a plugin operation fails.
 */
public class PluginError extends Exception {
    public PluginError(String message) {
        super(message);
    }

    public PluginError(String message, Throwable cause) {
        super(message, cause);
    }

    /**
     * Thrown when operations are attempted on a closed plugin.
     */
    public static class ClosedError extends PluginError {
        public ClosedError() {
            super("plugin is closed");
        }
    }
}
