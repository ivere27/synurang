package io.github.ivere27.synurang;

/** The provider stopped accepting requests; queued responses remain readable. */
public final class RequestClosedException extends FfiError {
    public RequestClosedException() { super("Provider stopped accepting requests", 0, 9); }
}
