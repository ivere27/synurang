//! Strongly-typed model of the descriptor data the templates consume.
//!
//! Each `*Data` struct knows how to convert itself into the dynamic [`Value`]
//! tree that the template engine sees as `dot`/`$`.

use std::collections::BTreeMap;

use prost_types::{DescriptorProto, EnumDescriptorProto, FileDescriptorProto};

use crate::names::go_camel;
use crate::value::Value;

#[derive(Clone, Debug)]
pub struct FieldData {
    pub name: String,
    pub go_name: String,
    pub number: i32,
    pub proto_kind: String,
    pub wire_kind: String,
    pub type_name: String,
    pub type_fqn: String,
    pub type_is_local: bool,
    pub is_repeated: bool,
    pub is_map: bool,
    pub is_oneof: bool,
    pub oneof_name: String,
    pub oneof_go_name: String,
    pub is_optional: bool,
    pub is_handle: bool,
    pub message_fqn: String,
    pub needs_box: bool,
    pub message_is_local: bool,
    pub map_key_kind: String,
    pub map_key_wire_kind: String,
    pub map_value_kind: String,
    pub map_value_wire_kind: String,
    pub map_value_type_name: String,
    pub map_value_fqn: String,
    pub map_value_is_local: bool,
}

impl FieldData {
    pub fn to_value(&self) -> Value {
        Value::map([
            ("Name".into(), Value::s(&self.name)),
            ("GoName".into(), Value::s(&self.go_name)),
            ("Number".into(), Value::Int(self.number as i64)),
            ("ProtoKind".into(), Value::s(&self.proto_kind)),
            ("WireKind".into(), Value::s(&self.wire_kind)),
            ("TypeName".into(), Value::s(&self.type_name)),
            ("TypeFQN".into(), Value::s(&self.type_fqn)),
            ("TypeIsLocal".into(), Value::Bool(self.type_is_local)),
            ("IsRepeated".into(), Value::Bool(self.is_repeated)),
            ("IsMap".into(), Value::Bool(self.is_map)),
            ("IsOneof".into(), Value::Bool(self.is_oneof)),
            ("OneofName".into(), Value::s(&self.oneof_name)),
            ("OneofGoName".into(), Value::s(&self.oneof_go_name)),
            ("IsOptional".into(), Value::Bool(self.is_optional)),
            ("IsHandle".into(), Value::Bool(self.is_handle)),
            ("MessageFQN".into(), Value::s(&self.message_fqn)),
            ("NeedsBox".into(), Value::Bool(self.needs_box)),
            ("MessageIsLocal".into(), Value::Bool(self.message_is_local)),
            ("MapKeyKind".into(), Value::s(&self.map_key_kind)),
            ("MapKeyWireKind".into(), Value::s(&self.map_key_wire_kind)),
            ("MapValueKind".into(), Value::s(&self.map_value_kind)),
            (
                "MapValueWireKind".into(),
                Value::s(&self.map_value_wire_kind),
            ),
            (
                "MapValueTypeName".into(),
                Value::s(&self.map_value_type_name),
            ),
            ("MapValueFQN".into(), Value::s(&self.map_value_fqn)),
            (
                "MapValueIsLocal".into(),
                Value::Bool(self.map_value_is_local),
            ),
        ])
    }
}

#[derive(Clone, Debug)]
pub struct MessageData {
    pub name: String,
    pub fields: Vec<FieldData>,
    pub is_handle: bool,
}

impl MessageData {
    pub fn to_value(&self) -> Value {
        Value::map([
            ("Name".into(), Value::s(&self.name)),
            (
                "Fields".into(),
                Value::list(self.fields.iter().map(FieldData::to_value).collect()),
            ),
            ("IsHandle".into(), Value::Bool(self.is_handle)),
        ])
    }
}

#[derive(Clone, Debug)]
pub struct EnumData {
    pub name: String,
    pub values: Vec<(String, i32)>,
}

impl EnumData {
    pub fn to_value(&self) -> Value {
        Value::map([
            ("Name".into(), Value::s(&self.name)),
            (
                "Values".into(),
                Value::list(
                    self.values
                        .iter()
                        .map(|(name, number)| {
                            Value::map([
                                ("Name".into(), Value::s(name)),
                                ("Number".into(), Value::Int(*number as i64)),
                            ])
                        })
                        .collect(),
                ),
            ),
        ])
    }
}

#[derive(Clone, Debug)]
pub struct MethodData {
    pub name: String,
    pub go_name: String,
    pub full_method_name: String,
    pub input_type: String,
    pub output_type: String,
    pub input_type_key: String,
    pub input_cpp_type: String,
    pub output_cpp_type: String,
    pub input_lite_type: String,
    pub output_lite_type: String,
    pub input_go_ident: String,
    pub output_go_ident: String,
    pub is_server_streaming: bool,
    pub is_client_streaming: bool,
    pub is_bidi_streaming: bool,
    pub is_unary: bool,
    pub output_is_handle: bool,
    pub output_wkt: String,
}

impl MethodData {
    pub fn to_value(&self) -> Value {
        Value::map([
            ("Name".into(), Value::s(&self.name)),
            ("GoName".into(), Value::s(&self.go_name)),
            ("FullMethodName".into(), Value::s(&self.full_method_name)),
            ("InputType".into(), Value::s(&self.input_type)),
            ("OutputType".into(), Value::s(&self.output_type)),
            ("InputTypeKey".into(), Value::s(&self.input_type_key)),
            ("InputCppType".into(), Value::s(&self.input_cpp_type)),
            ("OutputCppType".into(), Value::s(&self.output_cpp_type)),
            ("InputLiteType".into(), Value::s(&self.input_lite_type)),
            ("OutputLiteType".into(), Value::s(&self.output_lite_type)),
            ("InputGoIdent".into(), Value::s(&self.input_go_ident)),
            ("OutputGoIdent".into(), Value::s(&self.output_go_ident)),
            (
                "IsServerStreaming".into(),
                Value::Bool(self.is_server_streaming),
            ),
            (
                "IsClientStreaming".into(),
                Value::Bool(self.is_client_streaming),
            ),
            (
                "IsBidiStreaming".into(),
                Value::Bool(self.is_bidi_streaming),
            ),
            ("IsUnary".into(), Value::Bool(self.is_unary)),
            ("OutputIsHandle".into(), Value::Bool(self.output_is_handle)),
            ("OutputWKT".into(), Value::s(&self.output_wkt)),
        ])
    }
}

#[derive(Clone, Debug)]
pub struct ServiceData {
    pub name: String,
    pub go_name: String,
    pub native_prefix: String,
    pub methods: Vec<MethodData>,
}

impl ServiceData {
    pub fn to_value(&self) -> Value {
        Value::map([
            ("Name".into(), Value::s(&self.name)),
            ("GoName".into(), Value::s(&self.go_name)),
            ("NativePrefix".into(), Value::s(&self.native_prefix)),
            (
                "Methods".into(),
                Value::list(self.methods.iter().map(MethodData::to_value).collect()),
            ),
        ])
    }
}

#[derive(Clone, Debug)]
pub struct FileData {
    pub package: String,
    pub go_package_name: String,
    pub services: Vec<ServiceData>,
    pub has_streaming: bool,
    pub dart_package: String,
    pub java_package: String,
    pub external_imports: Vec<String>,
    pub go_imports: Vec<(String, String)>,
    pub pb_dart_file: String,
    pub pb_header_file: String,
    pub pb_ts_lite_file: String,
    pub cpp_dep_headers: Vec<String>,
    pub cpp_lite_dep_headers: Vec<String>,
    pub cpp_namespace: String,
    pub cpp_namespace_parts: Vec<String>,
    pub cpp_guard_name: String,
    pub rust_mod_path: String,
    pub csharp_namespace: String,
    pub messages: BTreeMap<String, MessageData>,
    pub local_messages: Vec<MessageData>,
    pub enums: Vec<EnumData>,
    pub file_prefix: String,
    pub com_prefix: String,
    pub com_properties: Vec<Value>,
}

impl FileData {
    pub fn to_value(&self) -> Value {
        let mut messages = BTreeMap::new();
        for (k, v) in &self.messages {
            messages.insert(k.clone(), v.to_value());
        }
        Value::map([
            ("Package".into(), Value::s(&self.package)),
            ("GoPackageName".into(), Value::s(&self.go_package_name)),
            (
                "Services".into(),
                Value::list(self.services.iter().map(ServiceData::to_value).collect()),
            ),
            ("HasStreaming".into(), Value::Bool(self.has_streaming)),
            ("DartPackage".into(), Value::s(&self.dart_package)),
            ("JavaPackage".into(), Value::s(&self.java_package)),
            (
                "ExternalImports".into(),
                Value::list(self.external_imports.iter().map(Value::s).collect()),
            ),
            (
                "GoImports".into(),
                Value::list(
                    self.go_imports
                        .iter()
                        .map(|(alias, path)| {
                            Value::map([
                                ("Alias".into(), Value::s(alias)),
                                ("Path".into(), Value::s(path)),
                            ])
                        })
                        .collect(),
                ),
            ),
            ("PbDartFile".into(), Value::s(&self.pb_dart_file)),
            ("PbHeaderFile".into(), Value::s(&self.pb_header_file)),
            ("PbTsLiteFile".into(), Value::s(&self.pb_ts_lite_file)),
            (
                "CppDepHeaders".into(),
                Value::list(self.cpp_dep_headers.iter().map(Value::s).collect()),
            ),
            (
                "CppLiteDepHeaders".into(),
                Value::list(self.cpp_lite_dep_headers.iter().map(Value::s).collect()),
            ),
            ("CppNamespace".into(), Value::s(&self.cpp_namespace)),
            (
                "CppNamespaceParts".into(),
                Value::list(self.cpp_namespace_parts.iter().map(Value::s).collect()),
            ),
            ("CppGuardName".into(), Value::s(&self.cpp_guard_name)),
            ("RustModPath".into(), Value::s(&self.rust_mod_path)),
            ("CSharpNamespace".into(), Value::s(&self.csharp_namespace)),
            ("Messages".into(), Value::Map(messages)),
            (
                "LocalMessages".into(),
                Value::list(
                    self.local_messages
                        .iter()
                        .map(MessageData::to_value)
                        .collect(),
                ),
            ),
            (
                "Enums".into(),
                Value::list(self.enums.iter().map(EnumData::to_value).collect()),
            ),
            ("FilePrefix".into(), Value::s(&self.file_prefix)),
            ("ComPrefix".into(), Value::s(&self.com_prefix)),
            (
                "ComProperties".into(),
                Value::list(self.com_properties.clone()),
            ),
        ])
    }
}

#[derive(Clone, Debug, Default)]
pub struct ActiveXServiceOption {
    pub prefix: String,
    pub properties: Vec<ActiveXProperty>,
}

#[derive(Clone, Debug, Default)]
pub struct ActiveXProperty {
    pub dispid: i32,
    pub name: String,
    pub custom: bool,
    pub olecolor: bool,
    pub set_method: String,
    pub get_method: String,
}

#[derive(Clone, Debug)]
pub struct MessageInfo {
    pub fqn: String,
    pub go_name: String,
    pub file_path: String,
    pub desc: DescriptorProto,
}

#[derive(Clone, Debug)]
pub struct EnumInfo {
    pub fqn: String,
    pub go_name: String,
    pub file_path: String,
    pub desc: EnumDescriptorProto,
}

#[derive(Clone, Debug)]
pub struct FileInfo {
    pub desc: FileDescriptorProto,
    pub path: String,
    pub package: String,
    pub go_import_path: String,
    pub go_package_name: String,
}

pub struct DescriptorIndex {
    pub files: BTreeMap<String, FileInfo>,
    pub messages: BTreeMap<String, MessageInfo>,
    pub enums: BTreeMap<String, EnumInfo>,
}

impl DescriptorIndex {
    pub fn new(
        files: &[FileDescriptorProto],
        import_map: &BTreeMap<String, String>,
    ) -> Self {
        let mut index = DescriptorIndex {
            files: BTreeMap::new(),
            messages: BTreeMap::new(),
            enums: BTreeMap::new(),
        };
        for desc in files {
            let path = desc.name.clone().unwrap_or_default();
            let package = desc.package.clone().unwrap_or_default();
            let (go_import_path, go_package_name) = resolve_go_package(desc, &path, import_map);
            index.files.insert(
                path.clone(),
                FileInfo {
                    desc: desc.clone(),
                    path: path.clone(),
                    package: package.clone(),
                    go_import_path,
                    go_package_name,
                },
            );
        }
        for desc in files {
            let path = desc.name.clone().unwrap_or_default();
            let package = desc.package.clone().unwrap_or_default();
            for msg in &desc.message_type {
                index.collect_message(&path, &package, "", "", msg);
            }
            for en in &desc.enum_type {
                index.collect_enum(&path, &package, "", "", en);
            }
        }
        index
    }

    fn collect_message(
        &mut self,
        file_path: &str,
        package: &str,
        parent_fqn: &str,
        parent_go_prefix: &str,
        desc: &DescriptorProto,
    ) {
        let name = desc.name.clone().unwrap_or_default();
        let fqn = qualify_fqn(package, parent_fqn, &name);
        let go_name = format!("{parent_go_prefix}{}", go_camel(&name));
        self.messages.insert(
            fqn.clone(),
            MessageInfo {
                fqn: fqn.clone(),
                go_name: go_name.clone(),
                file_path: file_path.to_string(),
                desc: desc.clone(),
            },
        );
        let nested_prefix = format!("{go_name}_");
        for nested in &desc.nested_type {
            self.collect_message(file_path, package, &fqn, &nested_prefix, nested);
        }
        for en in &desc.enum_type {
            self.collect_enum(file_path, package, &fqn, &nested_prefix, en);
        }
    }

    fn collect_enum(
        &mut self,
        file_path: &str,
        package: &str,
        parent_fqn: &str,
        parent_go_prefix: &str,
        desc: &EnumDescriptorProto,
    ) {
        let name = desc.name.clone().unwrap_or_default();
        let fqn = qualify_fqn(package, parent_fqn, &name);
        let go_name = format!("{parent_go_prefix}{}", go_camel(&name));
        self.enums.insert(
            fqn.clone(),
            EnumInfo {
                fqn,
                go_name,
                file_path: file_path.to_string(),
                desc: desc.clone(),
            },
        );
    }

    pub fn file(&self, path: &str) -> Option<&FileInfo> {
        self.files.get(path)
    }

    pub fn message(&self, fqn: &str) -> Option<&MessageInfo> {
        self.messages.get(fqn.trim_start_matches('.'))
    }

    pub fn enum_info(&self, fqn: &str) -> Option<&EnumInfo> {
        self.enums.get(fqn.trim_start_matches('.'))
    }
}

fn split_go_package(raw: &str) -> (String, String) {
    if let Some((path, name)) = raw.split_once(';') {
        return (path.to_string(), name.to_string());
    }
    let name = raw
        .rsplit('/')
        .next()
        .unwrap_or(raw)
        .replace('-', "_");
    (raw.to_string(), name)
}

pub fn resolve_go_package(
    desc: &FileDescriptorProto,
    file_path: &str,
    import_map: &BTreeMap<String, String>,
) -> (String, String) {
    let raw = desc
        .options
        .as_ref()
        .and_then(|o| o.go_package.clone())
        .unwrap_or_default();
    let (orig_path, orig_name) = if raw.is_empty() {
        let package = desc.package.clone().unwrap_or_default();
        (
            package.clone(),
            package.rsplit('.').next().unwrap_or("").to_string(),
        )
    } else {
        split_go_package(&raw)
    };

    let Some(override_raw) = import_map.get(file_path) else {
        return (orig_path, orig_name);
    };
    // protogen rule: an M-mapping without an explicit `;pkg` only overrides
    // the import path. The Go package name still comes from the descriptor's
    // go_package option (or the proto package's last segment).
    if let Some((path, name)) = override_raw.split_once(';') {
        return (path.to_string(), name.to_string());
    }
    (override_raw.clone(), orig_name)
}

pub fn go_package_alias(import_path: &str) -> String {
    import_path
        .rsplit('/')
        .next()
        .unwrap_or(import_path)
        .replace('-', "_")
}

pub fn qualify_fqn(package: &str, parent_fqn: &str, name: &str) -> String {
    if parent_fqn.is_empty() {
        if package.is_empty() {
            name.to_string()
        } else {
            format!("{package}.{name}")
        }
    } else {
        format!("{parent_fqn}.{name}")
    }
}

pub fn fqn_for_top(package: &str, name: &str) -> String {
    if package.is_empty() {
        name.to_string()
    } else {
        format!("{package}.{name}")
    }
}
