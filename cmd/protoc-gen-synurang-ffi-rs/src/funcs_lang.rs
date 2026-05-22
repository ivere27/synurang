//! Per-language helpers exposed to templates via [`crate::template::eval_function`].
//!
//! All helpers operate on plain [`Value`] arguments. The few that need access
//! to the root context (e.g. `swiftEnumZeroCase` looking up `.Enums`) take
//! `root: &Value` rather than the full `RenderContext`, which lets this module
//! stay independent of the engine.

use std::collections::BTreeMap;

use crate::names::{
    lower_first, pascal_from_snake, to_lower_camel_from_underscored, to_screaming_snake,
};
use crate::value::Value;

pub fn stream_type(prefix: &str, svc: &Value, m: &Value) -> Value {
    Value::s(format!(
        "{}{}{}Stream",
        prefix,
        svc.get("GoName").as_str(),
        m.get("GoName").as_str()
    ))
}

pub fn list_any(v: &Value, field: &str) -> bool {
    match v {
        Value::List(items) => items.iter().any(|item| item.get(field).as_bool()),
        _ => false,
    }
}

pub fn rust_c_type(f: &Value) -> &'static str {
    if f.get("IsHandle").as_bool() {
        return "i64";
    }
    match f.get("ProtoKind").as_str().as_str() {
        "int32" => "i32",
        "int64" => "i64",
        "uint32" => "u32",
        "uint64" => "u64",
        "float" => "f32",
        "double" => "f64",
        "bool" => "i32",
        "string" | "bytes" | "message" => "*const u8",
        "enum" => "i32",
        _ => "i32",
    }
}

pub fn c_header_type(f: &Value) -> &'static str {
    if f.get("IsHandle").as_bool() {
        return "int64_t";
    }
    match f.get("ProtoKind").as_str().as_str() {
        "int32" => "int32_t",
        "int64" => "int64_t",
        "uint32" => "uint32_t",
        "uint64" => "uint64_t",
        "float" => "float",
        "double" => "double",
        "bool" => "int32_t",
        "string" | "bytes" | "message" => "const uint8_t*",
        "enum" => "int32_t",
        _ => "int32_t",
    }
}

pub fn needs_len(f: &Value) -> bool {
    if f.get("IsHandle").as_bool() {
        return false;
    }
    matches!(
        f.get("ProtoKind").as_str().as_str(),
        "string" | "bytes" | "message"
    ) || f.get("IsRepeated").as_bool()
}

pub fn needs_out_len(m: &Value) -> bool {
    if m.get("OutputIsHandle").as_bool() {
        return false;
    }
    !matches!(
        m.get("OutputWKT").as_str().as_str(),
        "Empty" | "Int32Value" | "BoolValue" | "DoubleValue"
    )
}

pub fn rust_return_type(m: &Value) -> &'static str {
    if m.get("OutputIsHandle").as_bool() {
        return "i64";
    }
    match m.get("OutputWKT").as_str().as_str() {
        "Empty" | "Int32Value" | "BoolValue" => "i32",
        "DoubleValue" => "f64",
        _ => "*mut u8",
    }
}

pub fn c_return_type(m: &Value) -> &'static str {
    if m.get("OutputIsHandle").as_bool() {
        return "int64_t";
    }
    match m.get("OutputWKT").as_str().as_str() {
        "Empty" | "Int32Value" | "BoolValue" => "int32_t",
        "DoubleValue" => "double",
        "StringValue" => "uint8_t*",
        _ => "uint8_t*",
    }
}

pub fn native_err_return(m: &Value) -> &'static str {
    if m.get("OutputWKT").as_str() == "Empty" || m.get("OutputIsHandle").as_bool() {
        "return -1;"
    } else {
        match m.get("OutputWKT").as_str().as_str() {
            "Int32Value" => "return i32::MIN;",
            "BoolValue" => "return -1;",
            "DoubleValue" => "return f64::NAN;",
            _ => "if !out_len.is_null() { *out_len = 0; } return std::ptr::null_mut();",
        }
    }
}

pub fn wasm_err_return(m: &Value) -> &'static str {
    if m.get("OutputWKT").as_str() == "Empty" {
        "return;"
    } else if m.get("OutputIsHandle").as_bool() {
        "return -1;"
    } else {
        match m.get("OutputWKT").as_str().as_str() {
            "Int32Value" => "return i32::MIN;",
            "BoolValue" => "return false;",
            "DoubleValue" => "return f64::NAN;",
            "StringValue" => "return String::new();",
            _ => "return Vec::new();",
        }
    }
}

pub fn csharp_type(f: &Value) -> String {
    match f.get("ProtoKind").as_str().as_str() {
        "int32" => "int",
        "int64" => "long",
        "uint32" => "uint",
        "uint64" => "ulong",
        "float" => "float",
        "double" => "double",
        "bool" => "bool",
        "string" => "string",
        "bytes" => "byte[]",
        "enum" | "message" => return f.get("TypeName").as_str(),
        _ => "int",
    }
    .to_string()
}

pub fn oneof_groups(fields: &Value) -> Value {
    let mut groups: BTreeMap<String, (String, Vec<Value>)> = BTreeMap::new();
    let mut order = Vec::new();
    if let Value::List(items) = fields {
        for f in items {
            if !f.get("IsOneof").as_bool() || f.get("IsOptional").as_bool() {
                continue;
            }
            let name = f.get("OneofName").as_str();
            if !groups.contains_key(&name) {
                order.push(name.clone());
                groups.insert(name.clone(), (pascal_from_snake(&name), Vec::new()));
            }
            groups.get_mut(&name).unwrap().1.push(f.clone());
        }
    }
    Value::list(
        order
            .into_iter()
            .map(|name| {
                let (go_name, fields) = groups.remove(&name).unwrap();
                Value::map([
                    ("Name".into(), Value::s(name)),
                    ("GoName".into(), Value::s(go_name)),
                    ("Fields".into(), Value::list(fields)),
                ])
            })
            .collect(),
    )
}

pub fn ts_type(f: &Value) -> String {
    match f.get("ProtoKind").as_str().as_str() {
        "int32" | "uint32" | "float" | "double" => "number".to_string(),
        "int64" | "uint64" => "bigint".to_string(),
        "bool" => "boolean".to_string(),
        "string" => "string".to_string(),
        "bytes" => "Uint8Array".to_string(),
        "enum" => f.get("TypeName").as_str(),
        "message" if f.get("MessageIsLocal").as_bool() => f.get("TypeName").as_str(),
        _ => "unknown".to_string(),
    }
}

pub fn ts_default_value(f: &Value) -> &'static str {
    match f.get("ProtoKind").as_str().as_str() {
        "int32" | "uint32" | "float" | "double" | "enum" => "0",
        "int64" | "uint64" => "0n",
        "bool" => "false",
        "string" => "\"\"",
        _ => "",
    }
}

fn swift_is_keyword(name: &str) -> bool {
    matches!(
        name,
        "associatedtype"
            | "class"
            | "deinit"
            | "enum"
            | "extension"
            | "fileprivate"
            | "func"
            | "import"
            | "init"
            | "inout"
            | "internal"
            | "let"
            | "open"
            | "operator"
            | "private"
            | "protocol"
            | "public"
            | "static"
            | "struct"
            | "subscript"
            | "typealias"
            | "var"
            | "break"
            | "case"
            | "continue"
            | "default"
            | "defer"
            | "do"
            | "else"
            | "fallthrough"
            | "for"
            | "guard"
            | "if"
            | "in"
            | "repeat"
            | "return"
            | "switch"
            | "where"
            | "while"
            | "as"
            | "Any"
            | "catch"
            | "false"
            | "is"
            | "nil"
            | "rethrows"
            | "super"
            | "self"
            | "Self"
            | "throw"
            | "throws"
            | "true"
            | "try"
    )
}

pub fn swift_escape(name: &str) -> String {
    if swift_is_keyword(name) {
        format!("`{name}`")
    } else {
        name.to_string()
    }
}

pub fn swift_type(f: &Value) -> String {
    swift_kind_type(&f.get("ProtoKind").as_str(), &f.get("TypeName").as_str())
}

pub fn swift_kind_type(kind: &str, type_name: &str) -> String {
    match kind {
        "int32" => "Int32",
        "int64" => "Int64",
        "uint32" => "UInt32",
        "uint64" => "UInt64",
        "float" => "Float",
        "double" => "Double",
        "bool" => "Bool",
        "string" => "String",
        "bytes" => "Data",
        "enum" | "message" => return type_name.to_string(),
        _ => "Int32",
    }
    .to_string()
}

pub fn swift_default(f: &Value, root: &Value) -> String {
    match f.get("ProtoKind").as_str().as_str() {
        "int32" | "int64" | "uint32" | "uint64" | "float" | "double" => " = 0".to_string(),
        "bool" => " = false".to_string(),
        "string" => " = \"\"".to_string(),
        "bytes" => " = Data()".to_string(),
        "enum" => {
            let zero = swift_enum_zero_case(root, &f.get("TypeName").as_str());
            if zero.is_empty() {
                String::new()
            } else {
                format!(" = .{zero}")
            }
        }
        _ => String::new(),
    }
}

pub fn swift_enum_case(root: &Value, enum_name: &str, value_name: &str) -> String {
    let prefix = format!("{}_", to_screaming_snake(enum_name));
    let v = if swift_enum_should_strip(root, enum_name, &prefix) {
        value_name.strip_prefix(&prefix).unwrap_or(value_name)
    } else {
        value_name
    };
    let out = to_lower_camel_from_underscored(v);
    let out = if out.is_empty() {
        value_name.to_lowercase()
    } else {
        out
    };
    swift_escape(&out)
}

fn swift_enum_should_strip(root: &Value, enum_name: &str, prefix: &str) -> bool {
    let Value::List(enums) = root.get("Enums") else {
        return false;
    };
    for en in enums {
        if en.get("Name").as_str() != enum_name {
            continue;
        }
        let Value::List(values) = en.get("Values") else {
            return false;
        };
        if values.is_empty() {
            return false;
        }
        for value in values {
            let name = value.get("Name").as_str();
            let Some(rest) = name.strip_prefix(prefix) else {
                return false;
            };
            let first = rest.chars().next();
            match first {
                None => return false,
                Some(c) if c.is_ascii_digit() => return false,
                _ => {}
            }
        }
        return true;
    }
    false
}

pub fn swift_enum_zero_case(root: &Value, enum_type_name: &str) -> String {
    let Value::List(enums) = root.get("Enums") else {
        return String::new();
    };
    for en in enums {
        if en.get("Name").as_str() != enum_type_name {
            continue;
        }
        if let Value::List(values) = en.get("Values") {
            for value in values {
                if value.get("Number").as_i64() == 0 {
                    return swift_enum_case(root, enum_type_name, &value.get("Name").as_str());
                }
            }
        }
    }
    String::new()
}

pub fn swift_kind_default(kind: &str, type_name: &str) -> String {
    match kind {
        "int32" | "int64" | "uint32" | "uint64" | "float" | "double" => "0".to_string(),
        "bool" => "false".to_string(),
        "string" => "\"\"".to_string(),
        "bytes" => "Data()".to_string(),
        "enum" => format!("{type_name}(rawValue: 0)!"),
        "message" => format!("{type_name}()"),
        _ => "0".to_string(),
    }
}

pub fn swift_not_default(kind: &str, expr: &str) -> String {
    match kind {
        "bool" => expr.to_string(),
        "string" | "bytes" => format!("!{expr}.isEmpty"),
        "enum" => format!("{expr}.rawValue != 0"),
        _ => format!("{expr} != 0"),
    }
}

pub fn swift_write_call(wire_kind: &str) -> &'static str {
    match wire_kind {
        "int32" => "writeInt32",
        "sint32" => "writeSInt32",
        "sfixed32" => "writeSFixed32",
        "int64" => "writeInt64",
        "sint64" => "writeSInt64",
        "sfixed64" => "writeSFixed64",
        "uint32" => "writeUInt32",
        "fixed32" => "writeFixed32",
        "uint64" => "writeUInt64",
        "fixed64" => "writeFixed64",
        "float" => "writeFloat",
        "double" => "writeDouble",
        "bool" => "writeBool",
        "string" => "writeString",
        "bytes" => "writeBytes",
        "enum" => "writeInt32",
        _ => "",
    }
}

pub fn swift_read_call(wire_kind: &str) -> &'static str {
    match wire_kind {
        "int32" => "readInt32",
        "sint32" => "readSInt32",
        "sfixed32" => "readSFixed32",
        "int64" => "readInt64",
        "sint64" => "readSInt64",
        "sfixed64" => "readSFixed64",
        "uint32" => "readUInt32",
        "fixed32" => "readFixed32",
        "uint64" => "readUInt64",
        "fixed64" => "readFixed64",
        "float" => "readFloat",
        "double" => "readDouble",
        "bool" => "readBool",
        "string" => "readString",
        "bytes" => "readBytes",
        "enum" => "readInt32",
        _ => "",
    }
}

pub fn swift_scalar_wire(wire_kind: &str) -> &'static str {
    match wire_kind {
        "fixed32" | "sfixed32" | "float" => ".fixed32",
        "fixed64" | "sfixed64" | "double" => ".fixed64",
        "string" | "bytes" | "message" => ".lengthDelimited",
        _ => ".varint",
    }
}

pub fn cpp_field_name(name: &str) -> String {
    const KEYWORDS: &[&str] = &[
        "alignas",
        "alignof",
        "and",
        "and_eq",
        "asm",
        "auto",
        "bitand",
        "bitor",
        "bool",
        "break",
        "case",
        "catch",
        "char",
        "char8_t",
        "char16_t",
        "char32_t",
        "class",
        "compl",
        "concept",
        "const",
        "consteval",
        "constexpr",
        "constinit",
        "const_cast",
        "continue",
        "co_await",
        "co_return",
        "co_yield",
        "decltype",
        "default",
        "delete",
        "do",
        "double",
        "dynamic_cast",
        "else",
        "enum",
        "explicit",
        "export",
        "extern",
        "false",
        "float",
        "for",
        "friend",
        "goto",
        "if",
        "inline",
        "int",
        "long",
        "mutable",
        "namespace",
        "new",
        "noexcept",
        "not",
        "not_eq",
        "nullptr",
        "operator",
        "or",
        "or_eq",
        "private",
        "protected",
        "public",
        "register",
        "reinterpret_cast",
        "requires",
        "return",
        "short",
        "signed",
        "sizeof",
        "static",
        "static_assert",
        "static_cast",
        "struct",
        "switch",
        "template",
        "this",
        "thread_local",
        "throw",
        "true",
        "try",
        "typedef",
        "typeid",
        "typename",
        "union",
        "unsigned",
        "using",
        "virtual",
        "void",
        "volatile",
        "wchar_t",
        "while",
        "xor",
        "xor_eq",
    ];
    if KEYWORDS.contains(&name) {
        format!("{name}_")
    } else {
        name.to_string()
    }
}

pub fn cpp_lite_type(f: &Value) -> String {
    cpp_lite_kind_type(
        &f.get("ProtoKind").as_str(),
        &f.get("TypeName").as_str(),
        &f.get("TypeFQN").as_str(),
        f.get("TypeIsLocal").as_bool(),
    )
}

pub fn cpp_lite_kind_type(kind: &str, type_name: &str, type_fqn: &str, is_local: bool) -> String {
    match kind {
        "int32" => "int32_t".to_string(),
        "int64" => "int64_t".to_string(),
        "uint32" => "uint32_t".to_string(),
        "uint64" => "uint64_t".to_string(),
        "float" => "float".to_string(),
        "double" => "double".to_string(),
        "bool" => "bool".to_string(),
        "string" => "std::string".to_string(),
        "bytes" => "std::vector<uint8_t>".to_string(),
        "enum" | "message" => cpp_lite_qualified_type(type_name, type_fqn, is_local),
        _ => "int32_t".to_string(),
    }
}

pub fn cpp_lite_scalar_default(kind: &str) -> &'static str {
    match kind {
        "bool" => "false",
        "float" => "0.0f",
        "double" => "0.0",
        _ => "0",
    }
}

pub fn cpp_lite_kind_default(kind: &str, type_name: &str, type_fqn: &str, is_local: bool) -> String {
    match kind {
        "bool" => "false".to_string(),
        "float" => "0.0f".to_string(),
        "double" => "0.0".to_string(),
        "string" => "std::string()".to_string(),
        "bytes" => "std::vector<uint8_t>()".to_string(),
        "enum" => format!(
            "static_cast<{}>(0)",
            cpp_lite_qualified_type(type_name, type_fqn, is_local)
        ),
        "message" => format!(
            "{}()",
            cpp_lite_qualified_type(type_name, type_fqn, is_local)
        ),
        _ => "0".to_string(),
    }
}

pub fn cpp_lite_not_default(kind: &str, expr: &str) -> String {
    match kind {
        "bool" => expr.to_string(),
        "float" => format!("{expr} != 0.0f"),
        "double" => format!("{expr} != 0.0"),
        "string" | "bytes" => format!("!{expr}.empty()"),
        "enum" => format!("static_cast<int32_t>({expr}) != 0"),
        _ => format!("{expr} != 0"),
    }
}

pub fn cpp_lite_write_call(wire_kind: &str) -> &'static str {
    match wire_kind {
        "int32" => "write_int32",
        "sint32" => "write_sint32",
        "sfixed32" => "write_sfixed32",
        "int64" => "write_int64",
        "sint64" => "write_sint64",
        "sfixed64" => "write_sfixed64",
        "uint32" => "write_uint32",
        "fixed32" => "write_fixed32",
        "uint64" => "write_uint64",
        "fixed64" => "write_fixed64",
        "float" => "write_float",
        "double" => "write_double",
        "bool" => "write_bool",
        "string" => "write_string",
        "bytes" => "write_bytes",
        "enum" => "write_int32",
        _ => "",
    }
}

pub fn cpp_lite_read_call(wire_kind: &str) -> &'static str {
    match wire_kind {
        "int32" => "read_int32",
        "sint32" => "read_sint32",
        "sfixed32" => "read_sfixed32",
        "int64" => "read_int64",
        "sint64" => "read_sint64",
        "sfixed64" => "read_sfixed64",
        "uint32" => "read_uint32",
        "fixed32" => "read_fixed32",
        "uint64" => "read_uint64",
        "fixed64" => "read_fixed64",
        "float" => "read_float",
        "double" => "read_double",
        "bool" => "read_bool",
        "string" => "read_string",
        "bytes" => "read_bytes",
        "enum" => "read_int32",
        _ => "",
    }
}

pub fn cpp_qualified_type(fqn: &str) -> String {
    if fqn.is_empty() {
        String::new()
    } else {
        format!("::{}", fqn.replace('.', "::"))
    }
}

pub fn well_known_output_type(fqn: &str) -> Option<&'static str> {
    match fqn {
        "google.protobuf.Empty" => Some("Empty"),
        "google.protobuf.Int32Value" => Some("Int32Value"),
        "google.protobuf.BoolValue" => Some("BoolValue"),
        "google.protobuf.DoubleValue" => Some("DoubleValue"),
        "google.protobuf.StringValue" => Some("StringValue"),
        _ => None,
    }
}

pub fn cpp_lite_qualified_type(type_name: &str, type_fqn: &str, is_local: bool) -> String {
    if type_name.is_empty() {
        return "int32_t".to_string();
    }
    if let Some(wkt) = cpp_lite_wkt(type_fqn) {
        return wkt.to_string();
    }
    if is_local || type_fqn.is_empty() {
        return type_name.to_string();
    }
    let mut parts: Vec<&str> = type_fqn.split('.').collect();
    if parts.len() <= 1 {
        return type_name.to_string();
    }
    parts.pop();
    format!("::{}::{type_name}", parts.join("::"))
}

pub fn cpp_lite_wkt(fqn: &str) -> Option<&'static str> {
    match fqn {
        "google.protobuf.Empty" => Some("::synurang::lite::Empty"),
        "google.protobuf.Int32Value" => Some("::synurang::lite::Int32Value"),
        "google.protobuf.Int64Value" => Some("::synurang::lite::Int64Value"),
        "google.protobuf.UInt32Value" => Some("::synurang::lite::UInt32Value"),
        "google.protobuf.UInt64Value" => Some("::synurang::lite::UInt64Value"),
        "google.protobuf.BoolValue" => Some("::synurang::lite::BoolValue"),
        "google.protobuf.FloatValue" => Some("::synurang::lite::FloatValue"),
        "google.protobuf.DoubleValue" => Some("::synurang::lite::DoubleValue"),
        "google.protobuf.StringValue" => Some("::synurang::lite::StringValue"),
        "google.protobuf.BytesValue" => Some("::synurang::lite::BytesValue"),
        "google.protobuf.Timestamp" => Some("::synurang::lite::Timestamp"),
        "google.protobuf.Duration" => Some("::synurang::lite::Duration"),
        _ => None,
    }
}

pub fn cpp_guard_name(filename: &str) -> String {
    let base = filename
        .rsplit_once('.')
        .map(|(b, _)| b)
        .unwrap_or(filename);
    let mut out = String::new();
    for ch in base.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_uppercase());
        } else {
            out.push('_');
        }
    }
    if out.is_empty() {
        "SYNURANG_FFI_H_".to_string()
    } else {
        format!("{out}_H_")
    }
}

/// Format `printf "fmt" args...` the same way Go's `fmt.Sprintf` does *for the
/// verbs our templates actually use*. Returns Err on unknown verbs so future
/// template changes fail loud instead of silently diverging from the Go
/// generator's output.
pub fn template_printf(args: &[Value]) -> Result<String, String> {
    let fmt = args.first().map(Value::as_str).unwrap_or_default();
    let mut out = String::new();
    let mut arg_idx = 1usize;
    let mut chars = fmt.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '%' {
            out.push(ch);
            continue;
        }
        match chars.next() {
            Some('s') => {
                out.push_str(&args.get(arg_idx).map(Value::as_str).unwrap_or_default());
                arg_idx += 1;
            }
            Some('q') => {
                out.push_str(&go_quote(
                    &args.get(arg_idx).map(Value::as_str).unwrap_or_default(),
                ));
                arg_idx += 1;
            }
            Some('d') => {
                out.push_str(
                    &args
                        .get(arg_idx)
                        .map(Value::as_i64)
                        .unwrap_or_default()
                        .to_string(),
                );
                arg_idx += 1;
            }
            Some('v') => {
                out.push_str(&args.get(arg_idx).map(Value::as_str).unwrap_or_default());
                arg_idx += 1;
            }
            Some('%') => out.push('%'),
            Some(other) => {
                return Err(format!("printf: unsupported verb %{other} in {fmt:?}"));
            }
            None => return Err(format!("printf: trailing % in {fmt:?}")),
        }
    }
    Ok(out)
}

pub fn go_quote(s: &str) -> String {
    let mut out = String::from("\"");
    for ch in s.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

pub fn callmethod_name(m: &Value) -> String {
    let name = m.get("GoName").as_str();
    if !m.get("IsUnary").as_bool() {
        format!("{name}Internal")
    } else {
        name
    }
}

pub fn lower_first_value(v: &Value) -> String {
    lower_first(&v.as_str())
}
