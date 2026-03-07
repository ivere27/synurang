using System;
using System.Text;

namespace Synurang;

public class FfiError : Exception
{
    public int Code { get; }
    public int GrpcCode { get; }
    public byte[]? Payload { get; }

    public FfiError(string message) : this(message, 0, 2, null, null) { }

    public FfiError(string message, Exception inner) : this(message, 0, 2, null, inner) { }

    public FfiError(string message, int code, int grpcCode)
        : this(message, code, grpcCode, null, null) { }

    protected FfiError(string message, int code, int grpcCode, byte[]? payload, Exception? inner)
        : base(message, inner)
    {
        Code = code;
        GrpcCode = grpcCode;
        Payload = payload == null ? null : (byte[])payload.Clone();
    }

    public static FfiError FromPayload(byte[]? payload)
    {
        DecodedPayload decoded = DecodePayload(payload);
        return new FfiError(decoded.Message, decoded.Code, decoded.GrpcCode, decoded.Payload, null);
    }

    protected static DecodedPayload DecodePayload(byte[]? payload)
    {
        if (payload == null || payload.Length == 0)
            return new DecodedPayload(string.Empty, 0, 0, payload);

        int index = 0;
        int code = 0;
        int grpcCode = 0;
        string? message = null;

        while (index < payload.Length)
        {
            if (!TryReadVarint(payload, ref index, out ulong tag) || tag == 0)
                break;

            int fieldNumber = (int)(tag >> 3);
            int wireType = (int)(tag & 0x07);

            switch (fieldNumber)
            {
                case 1 when wireType == 0:
                    if (!TryReadVarint(payload, ref index, out ulong codeValue))
                        index = payload.Length;
                    else
                        code = (int)codeValue;
                    break;
                case 2 when wireType == 2:
                    if (!TryReadVarint(payload, ref index, out ulong lengthValue))
                    {
                        index = payload.Length;
                        break;
                    }
                    int length = (int)lengthValue;
                    if (length < 0 || index + length > payload.Length)
                    {
                        index = payload.Length;
                        break;
                    }
                    message = Encoding.UTF8.GetString(payload, index, length);
                    index += length;
                    break;
                case 3 when wireType == 0:
                    if (!TryReadVarint(payload, ref index, out ulong grpcValue))
                        index = payload.Length;
                    else
                        grpcCode = (int)grpcValue;
                    break;
                default:
                    index = SkipField(payload, index, wireType);
                    break;
            }
        }

        if (message == null)
            message = Encoding.UTF8.GetString(payload);

        return new DecodedPayload(message, code, grpcCode, payload);
    }

    private static int SkipField(byte[] payload, int index, int wireType)
    {
        switch (wireType)
        {
            case 0:
                return TryReadVarint(payload, ref index, out _) ? index : payload.Length;
            case 2:
                if (!TryReadVarint(payload, ref index, out ulong length))
                    return payload.Length;
                int next = index + (int)length;
                return next <= payload.Length ? next : payload.Length;
            default:
                return payload.Length;
        }
    }

    private static bool TryReadVarint(byte[] payload, ref int index, out ulong value)
    {
        value = 0;
        int shift = 0;
        while (index < payload.Length && shift < 64)
        {
            byte b = payload[index++];
            value |= (ulong)(b & 0x7f) << shift;
            if ((b & 0x80) == 0)
                return true;
            shift += 7;
        }
        return false;
    }

    protected sealed class DecodedPayload
    {
        public string Message { get; }
        public int Code { get; }
        public int GrpcCode { get; }
        public byte[]? Payload { get; }

        public DecodedPayload(string message, int code, int grpcCode, byte[]? payload)
        {
            Message = message;
            Code = code;
            GrpcCode = grpcCode;
            Payload = payload == null ? null : (byte[])payload.Clone();
        }
    }
}
