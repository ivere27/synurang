package io.github.ivere27.synurang;

import java.util.Iterator;
import java.util.NoSuchElementException;

/**
 * A bidirectional stream helper for generated code.
 * <p>
 * Provides send() for outgoing messages and an Iterator for incoming messages.
 * The recv iterator blocks on next() until data is available or the stream ends.
 *
 * @param <Req>  the request message type
 * @param <Resp> the response message type
 */
public class BidiStream<Req, Resp> implements AutoCloseable {
    private final PluginStream stream;
    private final Serializer<Req> serializer;
    private final Deserializer<Resp> deserializer;

    @FunctionalInterface
    public interface Serializer<T> {
        byte[] serialize(T message);
    }

    @FunctionalInterface
    public interface Deserializer<T> {
        T deserialize(byte[] data) throws Exception;
    }

    public BidiStream(PluginStream stream, Serializer<Req> serializer, Deserializer<Resp> deserializer) {
        this.stream = stream;
        this.serializer = serializer;
        this.deserializer = deserializer;
    }

    /**
     * Send a request message.
     */
    public void send(Req request) throws FfiError {
        stream.send(serializer.serialize(request));
    }

    /**
     * Close the send side. Call this after sending all requests.
     */
    public void closeSend() {
        stream.closeSend();
    }

    /**
     * Returns a blocking iterator over response messages.
     * Blocks on next() until data arrives or the stream ends.
     */
    public Iterator<Resp> responses() {
        return new Iterator<Resp>() {
            private Resp next = null;
            private boolean done = false;
            private boolean fetched = false;

            @Override
            public boolean hasNext() {
                if (done) return false;
                if (fetched) return true;
                try {
                    byte[] data = stream.recv();
                    if (data == null) {
                        done = true;
                        return false;
                    }
                    next = deserializer.deserialize(data);
                    fetched = true;
                    return true;
                } catch (Exception e) {
                    done = true;
                    if (e instanceof RuntimeException) throw (RuntimeException) e;
                    throw new RuntimeException(e);
                }
            }

            @Override
            public Resp next() {
                if (!hasNext()) throw new NoSuchElementException();
                fetched = false;
                return next;
            }
        };
    }

    @Override
    public void close() {
        stream.close();
    }
}
