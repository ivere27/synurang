package io.github.ivere27.synurang;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/**
 * Structured error decoded from the shared core.v1.Error FFI payload.
 */
public class FfiError extends Exception {
    private final int code;
    private final int grpcCode;
    private final byte[] payload;

    public FfiError(String message) {
        this(message, 0, 2, null, null);
    }

    public FfiError(String message, Throwable cause) {
        this(message, 0, 2, null, cause);
    }

    public FfiError(String message, int code, int grpcCode) {
        this(message, code, grpcCode, null, null);
    }

    protected FfiError(String message, int code, int grpcCode, byte[] payload, Throwable cause) {
        super(message, cause);
        this.code = code;
        this.grpcCode = grpcCode;
        this.payload = payload == null ? null : Arrays.copyOf(payload, payload.length);
    }

    public int getCode() {
        return code;
    }

    public int getGrpcCode() {
        return grpcCode;
    }

    public byte[] getPayload() {
        return payload == null ? null : Arrays.copyOf(payload, payload.length);
    }

    public static FfiError fromPayload(byte[] payload) {
        DecodedPayload decoded = decodePayload(payload);
        return new FfiError(decoded.message, decoded.code, decoded.grpcCode, decoded.payload, null);
    }

    protected static DecodedPayload decodePayload(byte[] payload) {
        if (payload == null || payload.length == 0) {
            return new DecodedPayload("", 0, 0, payload);
        }

        int index = 0;
        int code = 0;
        int grpcCode = 0;
        String message = null;

        while (index < payload.length) {
            VarintResult tag = readVarint(payload, index);
            if (tag == null || tag.value == 0) {
                break;
            }
            index = tag.nextIndex;
            int fieldNumber = (int) (tag.value >>> 3);
            int wireType = (int) (tag.value & 0x07);

            switch (fieldNumber) {
                case 1:
                    if (wireType != 0) {
                        index = skipField(payload, index, wireType);
                        continue;
                    }
                    VarintResult codeResult = readVarint(payload, index);
                    if (codeResult == null) {
                        index = payload.length;
                        break;
                    }
                    code = (int) codeResult.value;
                    index = codeResult.nextIndex;
                    break;
                case 2:
                    if (wireType != 2) {
                        index = skipField(payload, index, wireType);
                        continue;
                    }
                    VarintResult lenResult = readVarint(payload, index);
                    if (lenResult == null) {
                        index = payload.length;
                        break;
                    }
                    int len = (int) lenResult.value;
                    index = lenResult.nextIndex;
                    if (len < 0 || index + len > payload.length) {
                        index = payload.length;
                        break;
                    }
                    message = new String(payload, index, len, StandardCharsets.UTF_8);
                    index += len;
                    break;
                case 3:
                    if (wireType != 0) {
                        index = skipField(payload, index, wireType);
                        continue;
                    }
                    VarintResult grpcResult = readVarint(payload, index);
                    if (grpcResult == null) {
                        index = payload.length;
                        break;
                    }
                    grpcCode = (int) grpcResult.value;
                    index = grpcResult.nextIndex;
                    break;
                default:
                    index = skipField(payload, index, wireType);
                    break;
            }
        }

        if (message == null) {
            message = new String(payload, StandardCharsets.UTF_8);
        }
        return new DecodedPayload(message, code, grpcCode, payload);
    }

    private static int skipField(byte[] payload, int index, int wireType) {
        switch (wireType) {
            case 0:
                VarintResult varint = readVarint(payload, index);
                return varint == null ? payload.length : varint.nextIndex;
            case 2:
                VarintResult len = readVarint(payload, index);
                if (len == null) {
                    return payload.length;
                }
                int size = (int) len.value;
                int next = len.nextIndex + size;
                return size < 0 || next > payload.length ? payload.length : next;
            default:
                return payload.length;
        }
    }

    private static VarintResult readVarint(byte[] payload, int index) {
        long value = 0;
        int shift = 0;
        while (index < payload.length && shift < 64) {
            int b = payload[index++] & 0xff;
            value |= (long) (b & 0x7f) << shift;
            if ((b & 0x80) == 0) {
                return new VarintResult(value, index);
            }
            shift += 7;
        }
        return null;
    }

    protected static final class DecodedPayload {
        final String message;
        final int code;
        final int grpcCode;
        final byte[] payload;

        DecodedPayload(String message, int code, int grpcCode, byte[] payload) {
            this.message = message;
            this.code = code;
            this.grpcCode = grpcCode;
            this.payload = payload;
        }
    }

    private static final class VarintResult {
        final long value;
        final int nextIndex;

        VarintResult(long value, int nextIndex) {
            this.value = value;
            this.nextIndex = nextIndex;
        }
    }

    /**
     * Thrown when operations are attempted on a closed plugin.
     */
    public static class ClosedError extends FfiError {
        public ClosedError() {
            super("plugin is closed");
        }
    }
}
