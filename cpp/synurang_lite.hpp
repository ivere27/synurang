// SynurangLite (C++) — hand-maintained runtime referenced by generated
// `*_lite.hpp` headers produced by `protoc-gen-synurang-ffi --lang=cpp,mode=lite`.
//
// Zero external dependencies: pure C++11, no libprotobuf, no gRPC. C++14
// and C++17 are also supported (Optional<T> aliases std::optional when
// available). The generated messages expose `serialize()` / `parse(bytes)`
// so they can be carried over either:
//   1. The Synurang FFI path (default) — implement `Transport` over a host
//      runtime like volvoxgrid::Runtime, and the generated `XxxLite` client
//      invokes/streams typed messages through it.
//   2. Any other transport you wire up — the messages are independent of
//      the transport layer.
//
// Header-only. Drop into your project and `#include` it from the generated
// lite header.

#ifndef SYNURANG_LITE_HPP
#define SYNURANG_LITE_HPP

#include <cstdint>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

// MSVC reports C++ standard via _MSVC_LANG, not __cplusplus, unless the
// /Zc:__cplusplus flag is set. Pick the larger of the two so feature
// detection works under both toolchains.
#if defined(_MSVC_LANG) && _MSVC_LANG > __cplusplus
#  define SYNURANG_LITE_CPLUSPLUS _MSVC_LANG
#else
#  define SYNURANG_LITE_CPLUSPLUS __cplusplus
#endif

#if SYNURANG_LITE_CPLUSPLUS >= 201703L
#  include <optional>
#  define SYNURANG_LITE_HAS_STD_OPTIONAL 1
#endif

namespace synurang {
namespace lite {

// =============================================================================
// Optional<T> — proto3-optional presence wrapper. On C++17+ this is a thin
// alias for std::optional<T>; on C++11/14 it falls back to a small in-place
// container with the same interface used by the generated headers
// (has_value(), operator*, operator bool, reset()).
// =============================================================================

#if defined(SYNURANG_LITE_HAS_STD_OPTIONAL)
template <typename T>
using Optional = std::optional<T>;
#else
template <typename T>
class Optional {
public:
    Optional() : has_(false), value_() {}
    Optional(const T& v) : has_(true), value_(v) {}
    Optional(T&& v) : has_(true), value_(std::move(v)) {}
    Optional(const Optional& o) : has_(o.has_), value_(o.value_) {}
    Optional(Optional&& o) : has_(o.has_), value_(std::move(o.value_)) {
        o.has_ = false;
        o.value_ = T();
    }

    Optional& operator=(const T& v) {
        has_ = true;
        value_ = v;
        return *this;
    }
    Optional& operator=(T&& v) {
        has_ = true;
        value_ = std::move(v);
        return *this;
    }
    Optional& operator=(const Optional& o) {
        has_ = o.has_;
        value_ = o.value_;
        return *this;
    }
    Optional& operator=(Optional&& o) {
        has_ = o.has_;
        value_ = std::move(o.value_);
        o.has_ = false;
        o.value_ = T();
        return *this;
    }

    bool has_value() const { return has_; }
    explicit operator bool() const { return has_; }

    T& operator*() { return value_; }
    const T& operator*() const { return value_; }
    T* operator->() { return &value_; }
    const T* operator->() const { return &value_; }

    T& value() { return value_; }
    const T& value() const { return value_; }

    void reset() {
        has_ = false;
        value_ = T();
    }

private:
    bool has_;
    T value_;
};
#endif  // SYNURANG_LITE_HAS_STD_OPTIONAL

// =============================================================================
// Wire format primitives
// =============================================================================

enum class WireType : int {
    Varint          = 0,
    Fixed64         = 1,
    LengthDelimited = 2,
    StartGroup      = 3,  // deprecated proto2 groups; unsupported here
    EndGroup        = 4,
    Fixed32         = 5,
};

class ProtoError : public std::runtime_error {
public:
    explicit ProtoError(const std::string& msg) : std::runtime_error(msg) {}
};

// =============================================================================
// ProtoWriter — appends varint / fixed / length-delimited fields to a buffer.
// =============================================================================

class ProtoWriter {
public:
    ProtoWriter() = default;

    const std::vector<uint8_t>& data() const noexcept { return buf_; }
    std::vector<uint8_t>&& take() noexcept { return std::move(buf_); }
    std::string str() const { return std::string(buf_.begin(), buf_.end()); }

    void write_tag(int32_t field_number, WireType wire) {
        write_varint((static_cast<uint64_t>(field_number) << 3) |
                     static_cast<uint64_t>(static_cast<int>(wire)));
    }

    void write_varint(uint64_t v) {
        while (v >= 0x80) {
            buf_.push_back(static_cast<uint8_t>((v & 0x7F) | 0x80));
            v >>= 7;
        }
        buf_.push_back(static_cast<uint8_t>(v));
    }

    // Scalar writers — field tag + value. Mirror the swift/csharp writers.

    void write_int32(int32_t fn, int32_t value) {
        write_tag(fn, WireType::Varint);
        // Negative int32 is sign-extended to int64 then written as 10-byte varint.
        write_varint(static_cast<uint64_t>(static_cast<int64_t>(value)));
    }

    void write_int64(int32_t fn, int64_t value) {
        write_tag(fn, WireType::Varint);
        write_varint(static_cast<uint64_t>(value));
    }

    void write_uint32(int32_t fn, uint32_t value) {
        write_tag(fn, WireType::Varint);
        write_varint(static_cast<uint64_t>(value));
    }

    void write_uint64(int32_t fn, uint64_t value) {
        write_tag(fn, WireType::Varint);
        write_varint(value);
    }

    void write_sint32(int32_t fn, int32_t value) {
        write_tag(fn, WireType::Varint);
        uint32_t zz = (static_cast<uint32_t>(value) << 1) ^
                      static_cast<uint32_t>(value >> 31);
        write_varint(static_cast<uint64_t>(zz));
    }

    void write_sint64(int32_t fn, int64_t value) {
        write_tag(fn, WireType::Varint);
        uint64_t zz = (static_cast<uint64_t>(value) << 1) ^
                      static_cast<uint64_t>(value >> 63);
        write_varint(zz);
    }

    void write_bool(int32_t fn, bool value) {
        write_tag(fn, WireType::Varint);
        write_varint(value ? 1u : 0u);
    }

    void write_fixed32(int32_t fn, uint32_t value) {
        write_tag(fn, WireType::Fixed32);
        write_fixed32_raw(value);
    }

    void write_fixed64(int32_t fn, uint64_t value) {
        write_tag(fn, WireType::Fixed64);
        write_fixed64_raw(value);
    }

    void write_sfixed32(int32_t fn, int32_t value) {
        write_fixed32(fn, static_cast<uint32_t>(value));
    }

    void write_sfixed64(int32_t fn, int64_t value) {
        write_fixed64(fn, static_cast<uint64_t>(value));
    }

    void write_float(int32_t fn, float value) {
        uint32_t bits;
        std::memcpy(&bits, &value, sizeof(bits));
        write_fixed32(fn, bits);
    }

    void write_double(int32_t fn, double value) {
        uint64_t bits;
        std::memcpy(&bits, &value, sizeof(bits));
        write_fixed64(fn, bits);
    }

    void write_string(int32_t fn, const std::string& value) {
        write_length_delimited(fn, value.data(), value.size());
    }

    void write_bytes(int32_t fn, const std::vector<uint8_t>& value) {
        write_length_delimited(
            fn, reinterpret_cast<const char*>(value.data()), value.size());
    }

    void write_length_delimited(int32_t fn, const char* data, size_t n) {
        write_tag(fn, WireType::LengthDelimited);
        write_varint(static_cast<uint64_t>(n));
        if (n > 0 && data) {
            const auto* p = reinterpret_cast<const uint8_t*>(data);
            buf_.insert(buf_.end(), p, p + n);
        }
    }

    // Writes a nested message: caller hands us pre-serialized bytes.
    void write_message_bytes(int32_t fn, const std::vector<uint8_t>& bytes) {
        write_length_delimited(
            fn, reinterpret_cast<const char*>(bytes.data()), bytes.size());
    }

private:
    void write_fixed32_raw(uint32_t v) {
        for (int i = 0; i < 4; ++i) {
            buf_.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xFF));
        }
    }
    void write_fixed64_raw(uint64_t v) {
        for (int i = 0; i < 8; ++i) {
            buf_.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xFF));
        }
    }

    std::vector<uint8_t> buf_;
};

// =============================================================================
// ProtoReader — non-owning view over a contiguous wire-format buffer.
// =============================================================================

class ProtoReader {
public:
    ProtoReader(const uint8_t* data, size_t size) : ptr_(data), end_(data + size) {}
    explicit ProtoReader(const std::vector<uint8_t>& v)
        : ProtoReader(v.data(), v.size()) {}

    bool eof() const noexcept { return ptr_ >= end_; }
    size_t remaining() const noexcept {
        return static_cast<size_t>(end_ - ptr_);
    }

    // Reads the next field tag. Returns false at EOF.
    bool read_tag(int32_t& field_number, WireType& wire) {
        if (eof()) return false;
        uint64_t tag = read_varint();
        int w = static_cast<int>(tag & 0x07);
        if (w < 0 || w > 5) {
            throw ProtoError("invalid wire type");
        }
        wire = static_cast<WireType>(w);
        field_number = static_cast<int32_t>(tag >> 3);
        return true;
    }

    uint64_t read_varint() {
        uint64_t result = 0;
        unsigned shift = 0;
        while (true) {
            require(1);
            uint8_t b = *ptr_++;
            result |= static_cast<uint64_t>(b & 0x7F) << shift;
            if ((b & 0x80) == 0) return result;
            shift += 7;
            if (shift > 63) throw ProtoError("malformed varint");
        }
    }

    int32_t read_int32() {
        return static_cast<int32_t>(static_cast<int64_t>(read_varint()));
    }
    int64_t read_int64() {
        return static_cast<int64_t>(read_varint());
    }
    uint32_t read_uint32() {
        return static_cast<uint32_t>(read_varint());
    }
    uint64_t read_uint64() { return read_varint(); }

    int32_t read_sint32() {
        uint32_t v = static_cast<uint32_t>(read_varint());
        return static_cast<int32_t>((v >> 1) ^ (~(v & 1) + 1));
    }
    int64_t read_sint64() {
        uint64_t v = read_varint();
        return static_cast<int64_t>((v >> 1) ^ (~(v & 1) + 1));
    }

    bool read_bool() { return read_varint() != 0; }

    uint32_t read_fixed32() {
        require(4);
        uint32_t v = 0;
        for (int i = 0; i < 4; ++i) v |= static_cast<uint32_t>(ptr_[i]) << (8 * i);
        ptr_ += 4;
        return v;
    }
    uint64_t read_fixed64() {
        require(8);
        uint64_t v = 0;
        for (int i = 0; i < 8; ++i) v |= static_cast<uint64_t>(ptr_[i]) << (8 * i);
        ptr_ += 8;
        return v;
    }

    int32_t read_sfixed32() { return static_cast<int32_t>(read_fixed32()); }
    int64_t read_sfixed64() { return static_cast<int64_t>(read_fixed64()); }

    float read_float() {
        uint32_t bits = read_fixed32();
        float f;
        std::memcpy(&f, &bits, sizeof(f));
        return f;
    }
    double read_double() {
        uint64_t bits = read_fixed64();
        double d;
        std::memcpy(&d, &bits, sizeof(d));
        return d;
    }

    std::vector<uint8_t> read_length_delimited() {
        uint64_t n = read_varint();
        require(n);
        std::vector<uint8_t> out(ptr_, ptr_ + n);
        ptr_ += n;
        return out;
    }

    std::string read_string() {
        uint64_t n = read_varint();
        require(n);
        std::string s(reinterpret_cast<const char*>(ptr_), static_cast<size_t>(n));
        ptr_ += n;
        return s;
    }

    std::vector<uint8_t> read_bytes() { return read_length_delimited(); }

    void skip(WireType wire) {
        switch (wire) {
        case WireType::Varint:
            read_varint();
            return;
        case WireType::Fixed64:
            require(8);
            ptr_ += 8;
            return;
        case WireType::LengthDelimited: {
            uint64_t n = read_varint();
            require(n);
            ptr_ += n;
            return;
        }
        case WireType::Fixed32:
            require(4);
            ptr_ += 4;
            return;
        case WireType::StartGroup:
        case WireType::EndGroup:
        default:
            throw ProtoError("unsupported wire type in skip");
        }
    }

private:
    void require(uint64_t n) {
        // Compare in uint64_t so a >4 GiB length on a 32-bit host (where
        // size_t is 32 bits) can't silently truncate and pass the check.
        if (static_cast<uint64_t>(remaining()) < n) {
            throw ProtoError("unexpected end of payload");
        }
    }

    const uint8_t* ptr_;
    const uint8_t* end_;
};

// =============================================================================
// Well-known protobuf message shims
// =============================================================================

struct Empty {
    void encode(ProtoWriter&) const {}
    std::vector<uint8_t> serialize() const { return std::vector<uint8_t>(); }
    void parse_from(ProtoReader& r) {
        int32_t field;
        WireType wire;
        while (r.read_tag(field, wire)) r.skip(wire);
    }
    static Empty parse(const std::vector<uint8_t>& bytes) {
        ProtoReader r(bytes);
        Empty m;
        m.parse_from(r);
        return m;
    }
    static Empty parse(const uint8_t* data, size_t n) {
        ProtoReader r(data, n);
        Empty m;
        m.parse_from(r);
        return m;
    }
};

template <typename Derived, typename T>
struct WrapperBase {
    T value;
    explicit WrapperBase(T v = T()) : value(std::move(v)) {}

    std::vector<uint8_t> serialize() const {
        ProtoWriter w;
        static_cast<const Derived*>(this)->encode(w);
        return w.data();
    }
};

struct Int32Value : public WrapperBase<Int32Value, int32_t> {
    using WrapperBase<Int32Value, int32_t>::WrapperBase;
    void encode(ProtoWriter& w) const { if (value != 0) w.write_int32(1, value); }
    void parse_from(ProtoReader& r) {
        int32_t field; WireType wire;
        while (r.read_tag(field, wire)) {
            if (field == 1 && wire == WireType::Varint) value = r.read_int32();
            else r.skip(wire);
        }
    }
    static Int32Value parse(const std::vector<uint8_t>& bytes) { ProtoReader r(bytes); Int32Value m; m.parse_from(r); return m; }
    static Int32Value parse(const uint8_t* data, size_t n) { ProtoReader r(data, n); Int32Value m; m.parse_from(r); return m; }
};

struct Int64Value : public WrapperBase<Int64Value, int64_t> {
    using WrapperBase<Int64Value, int64_t>::WrapperBase;
    void encode(ProtoWriter& w) const { if (value != 0) w.write_int64(1, value); }
    void parse_from(ProtoReader& r) {
        int32_t field; WireType wire;
        while (r.read_tag(field, wire)) {
            if (field == 1 && wire == WireType::Varint) value = r.read_int64();
            else r.skip(wire);
        }
    }
    static Int64Value parse(const std::vector<uint8_t>& bytes) { ProtoReader r(bytes); Int64Value m; m.parse_from(r); return m; }
    static Int64Value parse(const uint8_t* data, size_t n) { ProtoReader r(data, n); Int64Value m; m.parse_from(r); return m; }
};

struct UInt32Value : public WrapperBase<UInt32Value, uint32_t> {
    using WrapperBase<UInt32Value, uint32_t>::WrapperBase;
    void encode(ProtoWriter& w) const { if (value != 0) w.write_uint32(1, value); }
    void parse_from(ProtoReader& r) {
        int32_t field; WireType wire;
        while (r.read_tag(field, wire)) {
            if (field == 1 && wire == WireType::Varint) value = r.read_uint32();
            else r.skip(wire);
        }
    }
    static UInt32Value parse(const std::vector<uint8_t>& bytes) { ProtoReader r(bytes); UInt32Value m; m.parse_from(r); return m; }
    static UInt32Value parse(const uint8_t* data, size_t n) { ProtoReader r(data, n); UInt32Value m; m.parse_from(r); return m; }
};

struct UInt64Value : public WrapperBase<UInt64Value, uint64_t> {
    using WrapperBase<UInt64Value, uint64_t>::WrapperBase;
    void encode(ProtoWriter& w) const { if (value != 0) w.write_uint64(1, value); }
    void parse_from(ProtoReader& r) {
        int32_t field; WireType wire;
        while (r.read_tag(field, wire)) {
            if (field == 1 && wire == WireType::Varint) value = r.read_uint64();
            else r.skip(wire);
        }
    }
    static UInt64Value parse(const std::vector<uint8_t>& bytes) { ProtoReader r(bytes); UInt64Value m; m.parse_from(r); return m; }
    static UInt64Value parse(const uint8_t* data, size_t n) { ProtoReader r(data, n); UInt64Value m; m.parse_from(r); return m; }
};

struct BoolValue : public WrapperBase<BoolValue, bool> {
    using WrapperBase<BoolValue, bool>::WrapperBase;
    void encode(ProtoWriter& w) const { if (value) w.write_bool(1, value); }
    void parse_from(ProtoReader& r) {
        int32_t field; WireType wire;
        while (r.read_tag(field, wire)) {
            if (field == 1 && wire == WireType::Varint) value = r.read_bool();
            else r.skip(wire);
        }
    }
    static BoolValue parse(const std::vector<uint8_t>& bytes) { ProtoReader r(bytes); BoolValue m; m.parse_from(r); return m; }
    static BoolValue parse(const uint8_t* data, size_t n) { ProtoReader r(data, n); BoolValue m; m.parse_from(r); return m; }
};

struct FloatValue : public WrapperBase<FloatValue, float> {
    using WrapperBase<FloatValue, float>::WrapperBase;
    void encode(ProtoWriter& w) const { if (value != 0.0f) w.write_float(1, value); }
    void parse_from(ProtoReader& r) {
        int32_t field; WireType wire;
        while (r.read_tag(field, wire)) {
            if (field == 1 && wire == WireType::Fixed32) value = r.read_float();
            else r.skip(wire);
        }
    }
    static FloatValue parse(const std::vector<uint8_t>& bytes) { ProtoReader r(bytes); FloatValue m; m.parse_from(r); return m; }
    static FloatValue parse(const uint8_t* data, size_t n) { ProtoReader r(data, n); FloatValue m; m.parse_from(r); return m; }
};

struct DoubleValue : public WrapperBase<DoubleValue, double> {
    using WrapperBase<DoubleValue, double>::WrapperBase;
    void encode(ProtoWriter& w) const { if (value != 0.0) w.write_double(1, value); }
    void parse_from(ProtoReader& r) {
        int32_t field; WireType wire;
        while (r.read_tag(field, wire)) {
            if (field == 1 && wire == WireType::Fixed64) value = r.read_double();
            else r.skip(wire);
        }
    }
    static DoubleValue parse(const std::vector<uint8_t>& bytes) { ProtoReader r(bytes); DoubleValue m; m.parse_from(r); return m; }
    static DoubleValue parse(const uint8_t* data, size_t n) { ProtoReader r(data, n); DoubleValue m; m.parse_from(r); return m; }
};

struct StringValue : public WrapperBase<StringValue, std::string> {
    using WrapperBase<StringValue, std::string>::WrapperBase;
    void encode(ProtoWriter& w) const { if (!value.empty()) w.write_string(1, value); }
    void parse_from(ProtoReader& r) {
        int32_t field; WireType wire;
        while (r.read_tag(field, wire)) {
            if (field == 1 && wire == WireType::LengthDelimited) value = r.read_string();
            else r.skip(wire);
        }
    }
    static StringValue parse(const std::vector<uint8_t>& bytes) { ProtoReader r(bytes); StringValue m; m.parse_from(r); return m; }
    static StringValue parse(const uint8_t* data, size_t n) { ProtoReader r(data, n); StringValue m; m.parse_from(r); return m; }
};

struct BytesValue : public WrapperBase<BytesValue, std::vector<uint8_t>> {
    using WrapperBase<BytesValue, std::vector<uint8_t>>::WrapperBase;
    void encode(ProtoWriter& w) const { if (!value.empty()) w.write_bytes(1, value); }
    void parse_from(ProtoReader& r) {
        int32_t field; WireType wire;
        while (r.read_tag(field, wire)) {
            if (field == 1 && wire == WireType::LengthDelimited) value = r.read_bytes();
            else r.skip(wire);
        }
    }
    static BytesValue parse(const std::vector<uint8_t>& bytes) { ProtoReader r(bytes); BytesValue m; m.parse_from(r); return m; }
    static BytesValue parse(const uint8_t* data, size_t n) { ProtoReader r(data, n); BytesValue m; m.parse_from(r); return m; }
};

struct Timestamp {
    int64_t seconds = 0;
    int32_t nanos = 0;

    Timestamp() = default;
    Timestamp(int64_t s, int32_t n) : seconds(s), nanos(n) {}

    void encode(ProtoWriter& w) const {
        if (seconds != 0) w.write_int64(1, seconds);
        if (nanos != 0) w.write_int32(2, nanos);
    }
    std::vector<uint8_t> serialize() const {
        ProtoWriter w;
        encode(w);
        return w.data();
    }
    void parse_from(ProtoReader& r) {
        int32_t field; WireType wire;
        while (r.read_tag(field, wire)) {
            switch (field) {
            case 1: seconds = r.read_int64(); break;
            case 2: nanos = r.read_int32(); break;
            default: r.skip(wire); break;
            }
        }
    }
    static Timestamp parse(const std::vector<uint8_t>& bytes) { ProtoReader r(bytes); Timestamp m; m.parse_from(r); return m; }
    static Timestamp parse(const uint8_t* data, size_t n) { ProtoReader r(data, n); Timestamp m; m.parse_from(r); return m; }
};

struct Duration {
    int64_t seconds = 0;
    int32_t nanos = 0;

    Duration() = default;
    Duration(int64_t s, int32_t n) : seconds(s), nanos(n) {}

    void encode(ProtoWriter& w) const {
        if (seconds != 0) w.write_int64(1, seconds);
        if (nanos != 0) w.write_int32(2, nanos);
    }
    std::vector<uint8_t> serialize() const {
        ProtoWriter w;
        encode(w);
        return w.data();
    }
    void parse_from(ProtoReader& r) {
        int32_t field; WireType wire;
        while (r.read_tag(field, wire)) {
            switch (field) {
            case 1: seconds = r.read_int64(); break;
            case 2: nanos = r.read_int32(); break;
            default: r.skip(wire); break;
            }
        }
    }
    static Duration parse(const std::vector<uint8_t>& bytes) { ProtoReader r(bytes); Duration m; m.parse_from(r); return m; }
    static Duration parse(const uint8_t* data, size_t n) { ProtoReader r(data, n); Duration m; m.parse_from(r); return m; }
};

// =============================================================================
// FfiError — thrown by Transport implementations when the plugin returns an
// error response. Decodes the standard CoreFfiError payload:
//
//   message CoreFfiError { int32 code = 1; string message = 2; int32 grpc_code = 3; }
// =============================================================================

class FfiError : public std::runtime_error {
public:
    explicit FfiError(const std::string& msg, int32_t code = 0, int32_t grpc_code = 2)
        : std::runtime_error(msg), code_(code), grpc_code_(grpc_code) {}

    int32_t code() const noexcept { return code_; }
    int32_t grpc_code() const noexcept { return grpc_code_; }

    // Decodes a wire-format CoreFfiError payload. On any parse failure, falls
    // back to using the payload as a raw UTF-8 message string.
    static FfiError from_payload(const uint8_t* data, size_t n) {
        if (n == 0 || data == nullptr) return FfiError("");
        try {
            ProtoReader r(data, n);
            int32_t code = 0;
            int32_t grpc_code = 0;
            std::string message;
            int32_t field;
            WireType wire;
            while (r.read_tag(field, wire)) {
                if (field == 1 && wire == WireType::Varint) {
                    code = r.read_int32();
                } else if (field == 2 && wire == WireType::LengthDelimited) {
                    message = r.read_string();
                } else if (field == 3 && wire == WireType::Varint) {
                    grpc_code = r.read_int32();
                } else {
                    r.skip(wire);
                }
            }
            if (message.empty()) {
                message.assign(reinterpret_cast<const char*>(data), n);
            }
            return FfiError(message, code, grpc_code);
        } catch (...) {
            return FfiError(std::string(reinterpret_cast<const char*>(data), n));
        }
    }

private:
    int32_t code_;
    int32_t grpc_code_;
};

// =============================================================================
// Transport — the shape generated lite clients call into.
//
// The user provides one implementation that bridges to whatever native runtime
// they have loaded (e.g. volvoxgrid::Runtime). Generated `XxxLite` clients
// call `invoke` for unary RPCs and `open_stream` for any of the streaming
// kinds.
// =============================================================================

class Stream {
public:
    virtual ~Stream() = default;

    // Send a length-prefixed payload. Throws FfiError on failure.
    virtual void send(const std::vector<uint8_t>& data) = 0;

    // Signal end-of-input (no more send calls). The peer may still send.
    virtual void close_send() = 0;

    // Receive the next payload. Returns true and fills `out` on success;
    // returns false on EOF. Throws FfiError on stream error.
    virtual bool recv(std::vector<uint8_t>& out) = 0;

    // Fully close the stream. Idempotent.
    virtual void close() = 0;
};

class Transport {
public:
    virtual ~Transport() = default;

    // Unary RPC. Returns the response bytes; throws FfiError on error.
    virtual std::vector<uint8_t> invoke(
        const std::string& method, const std::vector<uint8_t>& data) = 0;

    // Open a streaming RPC. The returned Stream is owned by the caller.
    virtual std::unique_ptr<Stream> open_stream(const std::string& method) = 0;
};

} // namespace lite
} // namespace synurang

#endif // SYNURANG_LITE_HPP
