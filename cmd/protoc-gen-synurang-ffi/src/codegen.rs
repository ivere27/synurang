//! Translates a `CodeGeneratorRequest` into rendered template outputs.
//!
//! Builds a [`FileData`] per proto file from the descriptor index, picks the
//! right template for the target language/mode, renders it, then applies
//! post-processing (e.g. Go fmt normalisation) before handing the file back
//! to the protoc protocol.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use prost_types::compiler::{code_generator_response, CodeGeneratorResponse};
use prost_types::{field_descriptor_proto, FieldDescriptorProto};

use crate::funcs_lang::{cpp_guard_name, cpp_qualified_type, well_known_output_type};
use crate::gofmt::final_content;
use crate::model::{
    fqn_for_top, go_package_alias, ActiveXProperty, ActiveXServiceOption, DescriptorIndex,
    EnumData, EnumInfo, FieldData, FileData, FileInfo, MessageData, MessageInfo, MethodData,
    ServiceData,
};
use crate::names::{
    acronym_aware_snake_case, basename, go_camel, pascal_from_snake, python_identifier,
    to_screaming_snake, to_snake_case, trim_proto_suffix, upper_first,
};
use crate::template::TemplateEngine;
use crate::value::Value;

pub const TEMPLATE_FILES: &[(&str, &str)] = &[
    (
        "_rust_invoke.tmpl",
        include_str!("../templates/_rust_invoke.tmpl"),
    ),
    (
        "_rust_plugin_trait.tmpl",
        include_str!("../templates/_rust_plugin_trait.tmpl"),
    ),
    (
        "c_activex.h.tmpl",
        include_str!("../templates/c_activex.h.tmpl"),
    ),
    (
        "c_native.h.tmpl",
        include_str!("../templates/c_native.h.tmpl"),
    ),
    ("c_lite.h.tmpl", include_str!("../templates/c_lite.h.tmpl")),
    ("c_lite.c.tmpl", include_str!("../templates/c_lite.c.tmpl")),
    ("cpp.h.tmpl", include_str!("../templates/cpp.h.tmpl")),
    (
        "cpp_lite.hpp.tmpl",
        include_str!("../templates/cpp_lite.hpp.tmpl"),
    ),
    (
        "cpp_plugin_server.cc.tmpl",
        include_str!("../templates/cpp_plugin_server.cc.tmpl"),
    ),
    (
        "cpp_plugin_server.h.tmpl",
        include_str!("../templates/cpp_plugin_server.h.tmpl"),
    ),
    (
        "csharp.cs.tmpl",
        include_str!("../templates/csharp.cs.tmpl"),
    ),
    (
        "csharp_lite.cs.tmpl",
        include_str!("../templates/csharp_lite.cs.tmpl"),
    ),
    (
        "dart.dart.tmpl",
        include_str!("../templates/dart.dart.tmpl"),
    ),
    (
        "go_default.go.tmpl",
        include_str!("../templates/go_default.go.tmpl"),
    ),
    (
        "go_plugin_client.go.tmpl",
        include_str!("../templates/go_plugin_client.go.tmpl"),
    ),
    (
        "go_plugin_server.go.tmpl",
        include_str!("../templates/go_plugin_server.go.tmpl"),
    ),
    (
        "java.java.tmpl",
        include_str!("../templates/java.java.tmpl"),
    ),
    (
        "python.py.tmpl",
        include_str!("../templates/python.py.tmpl"),
    ),
    (
        "python_lite.py.tmpl",
        include_str!("../templates/python_lite.py.tmpl"),
    ),
    ("rust.rs.tmpl", include_str!("../templates/rust.rs.tmpl")),
    (
        "rust_native.rs.tmpl",
        include_str!("../templates/rust_native.rs.tmpl"),
    ),
    (
        "rust_plugin_server.rs.tmpl",
        include_str!("../templates/rust_plugin_server.rs.tmpl"),
    ),
    (
        "rust_wasm.rs.tmpl",
        include_str!("../templates/rust_wasm.rs.tmpl"),
    ),
    (
        "swift_lite.swift.tmpl",
        include_str!("../templates/swift_lite.swift.tmpl"),
    ),
    (
        "typescript.ts.tmpl",
        include_str!("../templates/typescript.ts.tmpl"),
    ),
    (
        "typescript_lite.ts.tmpl",
        include_str!("../templates/typescript_lite.ts.tmpl"),
    ),
];

pub struct ParsedParams {
    pub flags: HashMap<String, String>,
    pub import_map: BTreeMap<String, String>,
    pub module: String,
    pub annotate_code: bool,
}

const API_LEVELS: &[&str] = &["API_OPEN", "API_HYBRID", "API_OPAQUE"];

fn validate_api_level(param: &str, v: &str) -> Result<(), String> {
    if API_LEVELS.contains(&v) {
        return Ok(());
    }
    Err(format!(
        "unknown API level \"{v}\" for parameter \"{param}\": want \"API_OPEN\", \"API_HYBRID\" or \"API_OPAQUE\""
    ))
}

const KNOWN_FLAGS: &[&str] = &[
    "lang",
    "mode",
    "dart_package",
    "java_package",
    "csharp_namespace",
    "services",
];

pub fn parse_params(raw: &str) -> Result<ParsedParams, String> {
    let mut flags = HashMap::new();
    let mut import_map = BTreeMap::new();
    let mut module = String::new();
    let mut annotate_code = false;
    for part in raw.split(',') {
        if part.is_empty() {
            continue;
        }
        let (k, v) = match part.split_once('=') {
            Some((k, v)) => (k.to_string(), v.to_string()),
            None => (part.to_string(), String::new()),
        };
        if let Some(proto_path) = k.strip_prefix('M') {
            // protogen skips empty overrides; descriptor go_package wins.
            if !v.is_empty() {
                import_map.insert(proto_path.to_string(), v);
            }
            continue;
        }
        if k.starts_with("apilevelM") {
            validate_api_level(&k, &v)?;
            continue;
        }
        // Protogen-handled flags. We don't use protogen, but accept them so
        // the plugin stays drop-in. Validate the values that protogen itself
        // would reject; otherwise treat as a no-op.
        match k.as_str() {
            "paths" => {
                if v != "import" && v != "source_relative" {
                    return Err(format!(
                        "unknown path type \"{v}\": want \"import\" or \"source_relative\""
                    ));
                }
                continue;
            }
            "annotate_code" => {
                if v.is_empty() || v == "true" {
                    annotate_code = true;
                } else if v == "false" {
                    annotate_code = false;
                } else {
                    return Err(
                        "bad value for parameter \"annotate_code\": want \"true\" or \"false\""
                            .to_string(),
                    );
                }
                continue;
            }
            "module" => {
                module = v;
                continue;
            }
            "default_api_level" => {
                validate_api_level(&k, &v)?;
                continue;
            }
            _ => {}
        }
        if !KNOWN_FLAGS.contains(&k.as_str()) {
            return Err(format!("no such flag -{k}"));
        }
        flags.insert(k, v);
    }
    Ok(ParsedParams {
        flags,
        import_map,
        module,
        annotate_code,
    })
}

#[allow(clippy::too_many_arguments)]
pub fn generate_from_template(
    response: &mut CodeGeneratorResponse,
    engine: &TemplateEngine,
    index: &DescriptorIndex,
    file: &FileInfo,
    service_list: &BTreeSet<String>,
    active_x_options: &BTreeMap<(String, String), ActiveXServiceOption>,
    lang: &str,
    mode_or_opt: &str,
) -> Result<(), String> {
    if lang == "c" && is_c_lite_mode(mode_or_opt) {
        validate_dependency_free_lite_schema(index, file, lang)?;
    }
    let data = build_file_data(
        index,
        file,
        service_list,
        active_x_options,
        lang,
        mode_or_opt,
    );
    if lang == "c" && is_c_lite_mode(mode_or_opt) {
        validate_c_lite_names(&data.enums, &data.local_messages)?;
    }
    let value = data.to_value();

    if lang == "cpp" && mode_or_opt == "plugin_server" {
        let header = engine.render("cpp_plugin_server.h.tmpl", value.clone())?;
        let header_name = output_filename_with_mode(file, lang, mode_or_opt, ".h");
        response.file.push(code_generator_response::File {
            name: Some(header_name.clone()),
            insertion_point: None,
            content: Some(final_content(&header_name, header)),
            generated_code_info: None,
        });

        let implementation = engine.render("cpp_plugin_server.cc.tmpl", value)?;
        let implementation_name = output_filename_with_mode(file, lang, mode_or_opt, ".cc");
        response.file.push(code_generator_response::File {
            name: Some(implementation_name.clone()),
            insertion_point: None,
            content: Some(final_content(&implementation_name, implementation)),
            generated_code_info: None,
        });
        return Ok(());
    }

    let tmpl_name = select_template(lang, mode_or_opt)
        .ok_or_else(|| format!("unsupported lang/mode: {lang}/{mode_or_opt}"))?;
    let content = engine.render(tmpl_name, value)?;
    let filename = output_filename_with_mode(file, lang, mode_or_opt, "");
    response.file.push(code_generator_response::File {
        name: Some(filename.clone()),
        insertion_point: None,
        content: Some(final_content(&filename, content)),
        generated_code_info: None,
    });
    Ok(())
}

fn build_file_data(
    index: &DescriptorIndex,
    file: &FileInfo,
    service_list: &BTreeSet<String>,
    active_x_options: &BTreeMap<(String, String), ActiveXServiceOption>,
    lang: &str,
    mode_or_opt: &str,
) -> FileData {
    let package = file.package.clone();
    let base_proto = basename(&file.path);
    let mut data = FileData {
        package: package.clone(),
        go_package_name: file.go_package_name.clone(),
        services: Vec::new(),
        has_streaming: false,
        dart_package: String::new(),
        java_package: String::new(),
        external_imports: Vec::new(),
        go_imports: Vec::new(),
        python_imports: Vec::new(),
        python_lite_imports: Vec::new(),
        python_lite_module: String::new(),
        c_lite_dep_headers: Vec::new(),
        c_lite_header_file: format!("{}_lite.h", trim_proto_suffix(&base_proto)),
        c_lite_include_guard: c_lite_include_guard(&file.path),
        pb_dart_file: String::new(),
        pb_header_file: String::new(),
        pb_ts_lite_file: String::new(),
        cpp_dep_headers: Vec::new(),
        cpp_lite_dep_headers: Vec::new(),
        cpp_namespace: String::new(),
        cpp_namespace_parts: Vec::new(),
        cpp_guard_name: String::new(),
        rust_mod_path: String::new(),
        csharp_namespace: String::new(),
        messages: BTreeMap::new(),
        local_messages: Vec::new(),
        enums: Vec::new(),
        file_prefix: compute_file_prefix(&file.path),
        com_prefix: String::new(),
        com_properties: Vec::new(),
    };

    match lang {
        "dart" => {
            data.dart_package = mode_or_opt.to_string();
            data.pb_dart_file = format!("{}.pb.dart", trim_proto_suffix(&base_proto));
        }
        "cpp" => {
            data.pb_header_file = format!("{}.pb.h", trim_proto_suffix(&base_proto));
            data.cpp_namespace = package.replace('.', "::");
            if !data.cpp_namespace.is_empty() {
                data.cpp_namespace_parts = data
                    .cpp_namespace
                    .split("::")
                    .map(ToOwned::to_owned)
                    .collect();
            }
            data.cpp_guard_name =
                cpp_guard_name(&output_filename_with_mode(file, "cpp", mode_or_opt, ""));
        }
        "rust" => {
            data.rust_mod_path = package.replace('.', "_");
        }
        "java" => {
            data.java_package = if mode_or_opt.is_empty() {
                package.replace('-', "_")
            } else {
                mode_or_opt.to_string()
            };
        }
        "csharp" => {
            data.csharp_namespace = if !mode_or_opt.is_empty() && mode_or_opt != "lite" {
                mode_or_opt.to_string()
            } else {
                package
                    .split('.')
                    .map(|p| {
                        if p.is_empty() {
                            String::new()
                        } else {
                            format!("{}{}", p[..1].to_uppercase(), &p[1..])
                        }
                    })
                    .collect::<Vec<_>>()
                    .join(".")
            };
        }
        "typescript" | "ts" => {
            data.pb_ts_lite_file = format!("./{}_lite.js", trim_proto_suffix(&base_proto));
        }
        "c" if is_c_lite_mode(mode_or_opt) => {
            data.c_lite_dep_headers = lite_schema_dependencies(index, file)
                .into_iter()
                .map(|dependency| relative_c_lite_header(&file.path, &dependency))
                .collect();
        }
        "python" | "py" => {
            data.python_lite_module = python_lite_module_name(&file.path);
            let mut imports = BTreeMap::new();
            for dependency in &file.desc.dependency {
                if dependency.starts_with("google/protobuf/") {
                    continue;
                }
                let module = python_lite_module_name(dependency);
                imports.insert(module.clone(), python_module_alias(&module));
            }
            data.python_lite_imports = imports
                .into_iter()
                .map(|(module, alias)| (alias, module))
                .collect();
        }
        _ => {}
    }

    let mut go_imports: BTreeMap<String, String> = BTreeMap::new();
    let mut python_imports: BTreeMap<String, String> = BTreeMap::new();
    for service in &file.desc.service {
        let service_name = service.name.clone().unwrap_or_default();
        let service_go_name = go_camel(&service_name);
        if !should_generate_service(&service_go_name, service_list) {
            continue;
        }
        let mut svc = ServiceData {
            name: service_name.clone(),
            go_name: service_go_name,
            native_prefix: String::new(),
            methods: Vec::new(),
        };
        for method in &service.method {
            let input_fqn = method.input_type.clone().unwrap_or_default();
            let output_fqn = method.output_type.clone().unwrap_or_default();
            let input = index.message(&input_fqn);
            let output = index.message(&output_fqn);
            let is_server_stream = method.server_streaming.unwrap_or(false);
            let is_client_stream = method.client_streaming.unwrap_or(false);
            let is_streaming = is_server_stream || is_client_stream;
            if is_streaming {
                data.has_streaming = true;
            }

            let input_go_name = input.map(|m| m.go_name.clone()).unwrap_or_default();
            let output_go_name = output.map(|m| m.go_name.clone()).unwrap_or_default();
            let method_name = method.name.clone().unwrap_or_default();
            let m = MethodData {
                name: method_name.clone(),
                go_name: go_camel(&method_name),
                full_method_name: format!("/{package}.{service_name}/{method_name}"),
                input_type: input_go_name.clone(),
                output_type: output_go_name.clone(),
                input_type_key: input_fqn.trim_start_matches('.').to_string(),
                input_cpp_type: cpp_qualified_type(input.map(|m| m.fqn.as_str()).unwrap_or("")),
                output_cpp_type: cpp_qualified_type(output.map(|m| m.fqn.as_str()).unwrap_or("")),
                input_lite_type: cpp_lite_message_type(input, file),
                output_lite_type: cpp_lite_message_type(output, file),
                input_go_ident: qualify_go_type(index, file, input, true, &mut go_imports),
                output_go_ident: qualify_go_type(
                    index,
                    file,
                    output,
                    is_streaming,
                    &mut go_imports,
                ),
                input_python_type: qualify_python_type(input, &mut python_imports),
                output_python_type: qualify_python_type(output, &mut python_imports),
                is_server_streaming: is_server_stream && !is_client_stream,
                is_client_streaming: is_client_stream && !is_server_stream,
                is_bidi_streaming: is_server_stream && is_client_stream,
                is_unary: !is_server_stream && !is_client_stream,
                output_is_handle: output.map(|m| is_handle_message(index, m)).unwrap_or(false),
                output_wkt: output
                    .and_then(|m| well_known_output_type(&m.fqn))
                    .unwrap_or_default()
                    .to_string(),
            };
            svc.methods.push(m);
        }
        data.services.push(svc);
    }

    let mut prefix_count: BTreeMap<String, usize> = BTreeMap::new();
    for svc in &data.services {
        *prefix_count.entry(native_prefix(svc)).or_default() += 1;
    }
    for svc in &mut data.services {
        let prefix = native_prefix(svc);
        svc.native_prefix = if prefix_count.get(&prefix).copied().unwrap_or(0) > 1 {
            acronym_aware_snake_case(&svc.go_name)
        } else {
            prefix
        };
    }

    data.go_imports = go_imports
        .into_iter()
        .map(|(path, alias)| (alias, path))
        .collect();
    data.python_imports = python_imports
        .into_iter()
        .map(|(module, alias)| (alias, module))
        .collect();

    let mut visited = BTreeSet::new();
    for service in &file.desc.service {
        let service_go_name = go_camel(service.name.as_deref().unwrap_or(""));
        if !should_generate_service(&service_go_name, service_list) {
            continue;
        }
        for method in &service.method {
            if let Some(msg) = method.input_type.as_deref().and_then(|f| index.message(f)) {
                collect_message_data(index, &mut data.messages, msg, &mut visited);
            }
            if let Some(msg) = method.output_type.as_deref().and_then(|f| index.message(f)) {
                collect_message_data(index, &mut data.messages, msg, &mut visited);
            }
        }
    }
    mark_box_fields(&mut data.messages);

    let needs_local_messages = lang == "typescript"
        || lang == "python"
        || (lang == "c" && is_c_lite_mode(mode_or_opt))
        || (lang == "csharp" && mode_or_opt == "lite")
        || (lang == "swift" && mode_or_opt == "lite")
        || (lang == "cpp" && mode_or_opt == "lite");
    if needs_local_messages {
        let mut local_msg_seen = BTreeSet::new();
        for msg in &file.desc.message_type {
            let fqn = fqn_for_top(&file.package, msg.name.as_deref().unwrap_or(""));
            collect_local_messages(index, &mut data.local_messages, &fqn, &mut local_msg_seen);
        }
        data.local_messages.sort_by(|a, b| a.name.cmp(&b.name));
    }

    if needs_local_messages {
        let mut enum_seen = BTreeSet::new();
        for en in &file.desc.enum_type {
            let fqn = fqn_for_top(&file.package, en.name.as_deref().unwrap_or(""));
            collect_enum_data(index, &mut data.enums, &fqn, &mut enum_seen);
        }
        for msg in &file.desc.message_type {
            let fqn = fqn_for_top(&file.package, msg.name.as_deref().unwrap_or(""));
            collect_local_message_enums(index, &mut data.enums, &fqn, &mut enum_seen);
        }
        data.enums.sort_by(|a, b| a.name.cmp(&b.name));
    }

    if lang == "c" && mode_or_opt == "activex" {
        for service in &file.desc.service {
            let service_name = service.name.clone().unwrap_or_default();
            let service_go_name = go_camel(&service_name);
            if !should_generate_service(&service_go_name, service_list) {
                continue;
            }
            let Some(ax) = active_x_options.get(&(file.path.clone(), service_name.clone())) else {
                continue;
            };
            data.com_prefix = ax.prefix.clone();

            let Some(svc_data) = data
                .services
                .iter()
                .find(|svc| svc.go_name == service_go_name)
            else {
                continue;
            };
            let method_map: BTreeMap<String, MethodData> = svc_data
                .methods
                .iter()
                .map(|m| (m.name.clone(), m.clone()))
                .collect();

            for prop in &ax.properties {
                let set_method_name = if prop.set_method.is_empty() {
                    format!("Set{}", prop.name)
                } else {
                    prop.set_method.clone()
                };
                let get_method_name = if prop.get_method.is_empty() {
                    format!("Get{}", prop.name)
                } else {
                    prop.get_method.clone()
                };
                let set_method = method_map.get(&set_method_name);
                let get_method = method_map.get(&get_method_name);
                let dispatch_type = if prop.custom {
                    String::new()
                } else {
                    infer_dispatch_type(prop, set_method, get_method, &data.messages)
                };
                let native_set_fn = set_method
                    .map(|m| format!("{}_{}", svc_data.native_prefix, to_snake_case(&m.name)))
                    .unwrap_or_default();
                let native_get_fn = get_method
                    .map(|m| format!("{}_{}", svc_data.native_prefix, to_snake_case(&m.name)))
                    .unwrap_or_default();
                data.com_properties.push(Value::map([
                    ("DispId".into(), Value::Int(prop.dispid as i64)),
                    ("Name".into(), Value::s(&prop.name)),
                    (
                        "ConstName".into(),
                        Value::s(format!("DISPID_{}_{}", ax.prefix, prop.name.to_uppercase())),
                    ),
                    ("DispatchType".into(), Value::s(dispatch_type)),
                    ("IsCustom".into(), Value::Bool(prop.custom)),
                    ("NativeSetFn".into(), Value::s(native_set_fn)),
                    ("NativeGetFn".into(), Value::s(native_get_fn)),
                ]));
            }
        }
        data.com_properties
            .sort_by_key(|v| v.get("DispId").as_i64());
    }

    if lang == "dart" {
        let mut imports = BTreeSet::new();
        for service in &file.desc.service {
            let service_go_name = go_camel(service.name.as_deref().unwrap_or(""));
            if !should_generate_service(&service_go_name, service_list) {
                continue;
            }
            for method in &service.method {
                if let Some(msg) = method.input_type.as_deref().and_then(|f| index.message(f)) {
                    add_dart_import(&mut imports, file, &msg.file_path, mode_or_opt);
                }
                if let Some(msg) = method.output_type.as_deref().and_then(|f| index.message(f)) {
                    add_dart_import(&mut imports, file, &msg.file_path, mode_or_opt);
                }
            }
        }
        data.external_imports = imports.into_iter().collect();
    }

    if lang == "cpp" {
        let mut dep_files = BTreeSet::new();
        let mut file_visited = BTreeSet::new();
        for service in &file.desc.service {
            let service_go_name = go_camel(service.name.as_deref().unwrap_or(""));
            if !should_generate_service(&service_go_name, service_list) {
                continue;
            }
            for method in &service.method {
                if let Some(msg) = method.input_type.as_deref().and_then(|f| index.message(f)) {
                    collect_message_files(index, msg, &mut dep_files, &mut file_visited);
                }
                if let Some(msg) = method.output_type.as_deref().and_then(|f| index.message(f)) {
                    collect_message_files(index, msg, &mut dep_files, &mut file_visited);
                }
            }
        }
        dep_files.remove(&file.path);
        for dep in dep_files {
            if dep.starts_with("google/protobuf/") && mode_or_opt == "lite" {
                continue;
            }
            if mode_or_opt == "lite" {
                data.cpp_lite_dep_headers
                    .push(format!("{}_lite.hpp", trim_proto_suffix(&basename(&dep))));
            } else {
                data.cpp_dep_headers
                    .push(format!("{}.pb.h", trim_proto_suffix(&dep)));
            }
        }
        data.cpp_dep_headers.sort();
        data.cpp_lite_dep_headers.sort();
    }

    data
}

fn collect_message_data(
    index: &DescriptorIndex,
    out: &mut BTreeMap<String, MessageData>,
    msg: &MessageInfo,
    visited: &mut BTreeSet<String>,
) {
    if !visited.insert(msg.fqn.clone()) {
        return;
    }
    out.insert(msg.fqn.clone(), message_data(index, msg));
    for field in &msg.desc.field {
        if let Some(target) = field.type_name.as_deref().and_then(|f| index.message(f)) {
            collect_message_data(index, out, target, visited);
        }
    }
}

fn message_data(index: &DescriptorIndex, msg: &MessageInfo) -> MessageData {
    MessageData {
        name: msg.go_name.clone(),
        fqn: msg.fqn.clone(),
        python_name: msg.python_name.clone(),
        c_type_name: c_message_type_name(index, msg),
        c_function_prefix: c_message_function_prefix(index, msg),
        fields: msg
            .desc
            .field
            .iter()
            .map(|field| field_data(index, msg, field))
            .collect(),
        is_handle: is_handle_message(index, msg),
    }
}

fn lite_schema_dependencies(index: &DescriptorIndex, file: &FileInfo) -> Vec<String> {
    let mut dependencies = BTreeSet::new();
    for message in index
        .messages
        .values()
        .filter(|message| message.file_path == file.path)
    {
        for field in &message.desc.field {
            let type_name = field.type_name.as_deref().unwrap_or("");
            let defining_file = index
                .message(type_name)
                .map(|target| target.file_path.as_str())
                .or_else(|| {
                    index
                        .enum_info(type_name)
                        .map(|target| target.file_path.as_str())
                });
            if let Some(defining_file) = defining_file {
                if defining_file != file.path && !defining_file.starts_with("google/protobuf/") {
                    dependencies.insert(defining_file.to_string());
                }
            }
        }
    }
    dependencies.into_iter().collect()
}

fn validate_dependency_free_lite_schema(
    index: &DescriptorIndex,
    root: &FileInfo,
    lang: &str,
) -> Result<(), String> {
    let mut pending = vec![root.path.clone()];
    let mut visited = BTreeSet::new();
    while let Some(file_path) = pending.pop() {
        if !visited.insert(file_path.clone()) {
            continue;
        }
        let Some(file) = index.file(&file_path) else {
            continue;
        };
        let syntax = file.desc.syntax.as_deref().unwrap_or("proto2");
        if syntax != "proto3" {
            return Err(format!(
                "{lang} lite code generation supports proto3 schemas only: {} uses {syntax}",
                file.path
            ));
        }

        for message in index
            .messages
            .values()
            .filter(|message| message.file_path == file.path)
        {
            for field in &message.desc.field {
                let type_name = field
                    .type_name
                    .as_deref()
                    .unwrap_or("")
                    .trim_start_matches('.');
                if type_name.starts_with("google.protobuf.") && type_name != "google.protobuf.Empty"
                {
                    return Err(format!(
                        "{lang} lite code generation does not support protobuf type {type_name} referenced by {}",
                        file.path
                    ));
                }
            }
        }
        pending.extend(lite_schema_dependencies(index, file));
    }
    Ok(())
}

fn relative_c_lite_header(current_proto: &str, dependency_proto: &str) -> String {
    let mut current_dir: Vec<&str> = current_proto
        .split('/')
        .filter(|part| !part.is_empty() && *part != ".")
        .collect();
    current_dir.pop();

    let target = format!("{}_lite.h", trim_proto_suffix(dependency_proto));
    let target_parts: Vec<&str> = target
        .split('/')
        .filter(|part| !part.is_empty() && *part != ".")
        .collect();
    let common = current_dir
        .iter()
        .zip(&target_parts)
        .take_while(|(left, right)| left == right)
        .count();

    let mut parts = Vec::new();
    parts.extend(std::iter::repeat("..").take(current_dir.len() - common));
    parts.extend(target_parts[common..].iter().copied());
    parts.join("/")
}

fn c_package_prefix(package: &str) -> String {
    package
        .split('.')
        .filter(|part| !part.is_empty())
        .map(go_camel)
        .collect::<String>()
}

fn c_scope_prefix(package: &str, type_name: &str) -> String {
    package
        .split('.')
        .chain(type_name.split('_'))
        .filter(|part| !part.is_empty())
        .map(acronym_aware_snake_case)
        .collect::<Vec<_>>()
        .join("_")
}

fn c_message_type_name(index: &DescriptorIndex, msg: &MessageInfo) -> String {
    let package = index
        .file(&msg.file_path)
        .map(|file| file.package.as_str())
        .unwrap_or("");
    format!("{}{}", c_package_prefix(package), msg.go_name)
}

fn c_message_function_prefix(index: &DescriptorIndex, msg: &MessageInfo) -> String {
    let package = index
        .file(&msg.file_path)
        .map(|file| file.package.as_str())
        .unwrap_or("");
    c_scope_prefix(package, &msg.go_name)
}

fn c_field_type_name(index: &DescriptorIndex, field: &FieldDescriptorProto) -> String {
    use field_descriptor_proto::Type;

    match field.r#type() {
        Type::Bool => "int".to_string(),
        Type::Int32 | Type::Sint32 | Type::Sfixed32 => "int32_t".to_string(),
        Type::Int64 | Type::Sint64 | Type::Sfixed64 => "int64_t".to_string(),
        Type::Uint32 | Type::Fixed32 => "uint32_t".to_string(),
        Type::Uint64 | Type::Fixed64 => "uint64_t".to_string(),
        Type::Float => "float".to_string(),
        Type::Double => "double".to_string(),
        Type::String => "SynurangLiteString".to_string(),
        Type::Bytes => "SynurangLiteBytes".to_string(),
        Type::Enum => field
            .type_name
            .as_deref()
            .and_then(|fqn| index.enum_info(fqn))
            .map(|en| c_enum_type_name(index, en))
            .unwrap_or_else(|| "int32_t".to_string()),
        Type::Message | Type::Group => field
            .type_name
            .as_deref()
            .and_then(|fqn| index.message(fqn))
            .map(|msg| {
                if msg.fqn == "google.protobuf.Empty" {
                    "SynurangProtobufEmpty".to_string()
                } else {
                    c_message_type_name(index, msg)
                }
            })
            .unwrap_or_else(|| "SynurangLiteMessage".to_string()),
    }
}

fn c_field_function_prefix(index: &DescriptorIndex, field: &FieldDescriptorProto) -> String {
    field
        .type_name
        .as_deref()
        .and_then(|fqn| index.message(fqn))
        .map(|msg| {
            if msg.fqn == "google.protobuf.Empty" {
                "synurang_protobuf_empty".to_string()
            } else {
                c_message_function_prefix(index, msg)
            }
        })
        .unwrap_or_default()
}

fn is_c_lite_mode(mode: &str) -> bool {
    matches!(mode, "lite" | "lite_header" | "lite_source")
}

fn field_data(
    index: &DescriptorIndex,
    parent: &MessageInfo,
    field: &FieldDescriptorProto,
) -> FieldData {
    let name = field.name.clone().unwrap_or_default();
    let type_name = field.type_name.clone().unwrap_or_default();
    let target_msg = index.message(&type_name);
    let is_map = target_msg.map(is_map_entry).unwrap_or(false);
    let is_repeated = field.label() == field_descriptor_proto::Label::Repeated && !is_map;
    let (kind, wire, field_type_name, field_type_fqn, type_is_local) =
        classify_field(index, field, &parent.file_path);
    let is_packed = is_repeated
        && !matches!(kind.as_str(), "string" | "bytes" | "message")
        && field
            .options
            .as_ref()
            .and_then(|options| options.packed)
            .unwrap_or(true);
    let mut fd = FieldData {
        name: name.clone(),
        go_name: go_camel(&name),
        number: field.number.unwrap_or_default(),
        proto_kind: kind,
        wire_kind: wire,
        type_name: field_type_name,
        type_fqn: field_type_fqn,
        type_is_local,
        is_repeated,
        is_packed,
        is_map,
        is_oneof: field.oneof_index.is_some(),
        oneof_name: String::new(),
        oneof_go_name: String::new(),
        is_optional: field.proto3_optional.unwrap_or(false),
        is_handle: target_msg
            .map(|m| is_handle_message(index, m))
            .unwrap_or(false),
        message_fqn: target_msg.map(|m| m.fqn.clone()).unwrap_or_default(),
        needs_box: false,
        message_is_local: target_msg
            .map(|m| m.file_path == parent.file_path && !is_map_entry(m))
            .unwrap_or(false),
        map_key_kind: String::new(),
        map_key_wire_kind: String::new(),
        map_value_kind: String::new(),
        map_value_wire_kind: String::new(),
        map_value_type_name: String::new(),
        map_value_fqn: String::new(),
        map_value_is_local: false,
        c_type_name: c_field_type_name(index, field),
        c_function_prefix: c_field_function_prefix(index, field),
        map_value_c_type_name: String::new(),
        map_value_c_function_prefix: String::new(),
    };
    if let Some(idx) = field.oneof_index {
        if let Some(oneof) = parent.desc.oneof_decl.get(idx as usize) {
            fd.oneof_name = oneof.name.clone().unwrap_or_default();
            fd.oneof_go_name = pascal_from_snake(&fd.oneof_name);
        }
    }
    if fd.is_map {
        if let Some(entry) = target_msg {
            for sub in &entry.desc.field {
                let (k, w, tn, tf, local) = classify_field(index, sub, &parent.file_path);
                match sub.number.unwrap_or_default() {
                    1 => {
                        fd.map_key_kind = k;
                        fd.map_key_wire_kind = w;
                    }
                    2 => {
                        fd.map_value_kind = k;
                        fd.map_value_wire_kind = w;
                        fd.map_value_type_name = tn;
                        fd.map_value_fqn = tf;
                        fd.map_value_is_local = local;
                        fd.map_value_c_type_name = c_field_type_name(index, sub);
                        fd.map_value_c_function_prefix = c_field_function_prefix(index, sub);
                    }
                    _ => {}
                }
            }
        }
    }
    fd
}

fn classify_field(
    index: &DescriptorIndex,
    field: &FieldDescriptorProto,
    current_file_path: &str,
) -> (String, String, String, String, bool) {
    fn scalar(kind: &str, wire: &str) -> (String, String, String, String, bool) {
        (
            kind.into(),
            wire.into(),
            String::new(),
            String::new(),
            false,
        )
    }

    let t = field.r#type();
    match t {
        field_descriptor_proto::Type::Bool => scalar("bool", "bool"),
        field_descriptor_proto::Type::Int32 => scalar("int32", "int32"),
        field_descriptor_proto::Type::Sint32 => scalar("int32", "sint32"),
        field_descriptor_proto::Type::Sfixed32 => scalar("int32", "sfixed32"),
        field_descriptor_proto::Type::Int64 => scalar("int64", "int64"),
        field_descriptor_proto::Type::Sint64 => scalar("int64", "sint64"),
        field_descriptor_proto::Type::Sfixed64 => scalar("int64", "sfixed64"),
        field_descriptor_proto::Type::Uint32 => scalar("uint32", "uint32"),
        field_descriptor_proto::Type::Fixed32 => scalar("uint32", "fixed32"),
        field_descriptor_proto::Type::Uint64 => scalar("uint64", "uint64"),
        field_descriptor_proto::Type::Fixed64 => scalar("uint64", "fixed64"),
        field_descriptor_proto::Type::Float => scalar("float", "float"),
        field_descriptor_proto::Type::Double => scalar("double", "double"),
        field_descriptor_proto::Type::String => scalar("string", "string"),
        field_descriptor_proto::Type::Bytes => scalar("bytes", "bytes"),
        field_descriptor_proto::Type::Enum => {
            if let Some(en) = field.type_name.as_deref().and_then(|f| index.enum_info(f)) {
                (
                    "enum".into(),
                    "enum".into(),
                    en.go_name.clone(),
                    en.fqn.clone(),
                    en.file_path == current_file_path,
                )
            } else {
                scalar("enum", "enum")
            }
        }
        field_descriptor_proto::Type::Message | field_descriptor_proto::Type::Group => {
            if let Some(msg) = field.type_name.as_deref().and_then(|f| index.message(f)) {
                (
                    "message".into(),
                    "message".into(),
                    msg.go_name.clone(),
                    msg.fqn.clone(),
                    msg.file_path == current_file_path,
                )
            } else {
                scalar("message", "message")
            }
        }
    }
}

fn collect_local_messages(
    index: &DescriptorIndex,
    out: &mut Vec<MessageData>,
    fqn: &str,
    visited: &mut BTreeSet<String>,
) {
    let Some(msg) = index.message(fqn) else {
        return;
    };
    if is_map_entry(msg) || !visited.insert(msg.fqn.clone()) {
        return;
    }
    out.push(message_data(index, msg));
    for nested in &msg.desc.nested_type {
        let nested_fqn = format!("{}.{}", msg.fqn, nested.name.as_deref().unwrap_or(""));
        collect_local_messages(index, out, &nested_fqn, visited);
    }
}

fn collect_enum_data(
    index: &DescriptorIndex,
    out: &mut Vec<EnumData>,
    fqn: &str,
    visited: &mut BTreeSet<String>,
) {
    let Some(en) = index.enum_info(fqn) else {
        return;
    };
    if !visited.insert(en.fqn.clone()) {
        return;
    }
    out.push(EnumData {
        name: en.go_name.clone(),
        fqn: en.fqn.clone(),
        python_name: en.python_name.clone(),
        c_type_name: c_enum_type_name(index, en),
        c_function_prefix: c_enum_function_prefix(index, en),
        c_constant_prefix: c_enum_constant_prefix(index, en),
        values: en
            .desc
            .value
            .iter()
            .map(|v| {
                (
                    v.name.clone().unwrap_or_default(),
                    v.number.unwrap_or_default(),
                )
            })
            .collect(),
    });
}

fn c_enum_package<'a>(index: &'a DescriptorIndex, en: &EnumInfo) -> &'a str {
    index
        .file(&en.file_path)
        .map(|file| file.package.as_str())
        .unwrap_or("")
}

fn c_enum_type_name(index: &DescriptorIndex, en: &EnumInfo) -> String {
    let package_prefix = c_enum_package(index, en)
        .split('.')
        .filter(|part| !part.is_empty())
        .map(go_camel)
        .collect::<String>();
    format!("{package_prefix}{}", en.go_name)
}

fn c_enum_scope_parts<'a>(index: &'a DescriptorIndex, en: &'a EnumInfo) -> Vec<&'a str> {
    c_enum_package(index, en)
        .split('.')
        .chain(en.go_name.split('_'))
        .filter(|part| !part.is_empty())
        .collect()
}

fn c_enum_function_prefix(index: &DescriptorIndex, en: &EnumInfo) -> String {
    c_enum_scope_parts(index, en)
        .into_iter()
        .map(acronym_aware_snake_case)
        .collect::<Vec<_>>()
        .join("_")
}

fn c_enum_constant_prefix(index: &DescriptorIndex, en: &EnumInfo) -> String {
    c_enum_scope_parts(index, en)
        .into_iter()
        .map(to_screaming_snake)
        .collect::<Vec<_>>()
        .join("_")
}

fn validate_c_lite_names(enums: &[EnumData], messages: &[MessageData]) -> Result<(), String> {
    let mut type_names = BTreeMap::new();
    let mut function_prefixes = BTreeMap::new();
    let mut constant_prefixes = BTreeMap::new();
    for runtime_type in [
        "SynurangLiteStatus",
        "SynurangLiteAllocateFn",
        "SynurangLiteDeallocateFn",
        "SynurangLiteAllocator",
        "SynurangLiteBytes",
        "SynurangProtobufEmpty",
    ] {
        type_names.insert(runtime_type.to_string(), "the C lite runtime".to_string());
    }
    for en in enums {
        for (kind, name, names) in [
            ("type", &en.c_type_name, &mut type_names),
            (
                "function prefix",
                &en.c_function_prefix,
                &mut function_prefixes,
            ),
            (
                "constant prefix",
                &en.c_constant_prefix,
                &mut constant_prefixes,
            ),
        ] {
            if let Some(previous) = names.insert(name.clone(), en.fqn.clone()) {
                return Err(format!(
                    "C lite {kind} {name:?} collides between {previous} and {}",
                    en.fqn
                ));
            }
        }
    }
    for message in messages {
        for (kind, name, names) in [
            ("type", &message.c_type_name, &mut type_names),
            (
                "function prefix",
                &message.c_function_prefix,
                &mut function_prefixes,
            ),
        ] {
            if let Some(previous) = names.insert(name.clone(), message.fqn.clone()) {
                return Err(format!(
                    "C lite {kind} {name:?} collides between {previous} and {}",
                    message.fqn
                ));
            }
        }
    }
    Ok(())
}

fn collect_local_message_enums(
    index: &DescriptorIndex,
    out: &mut Vec<EnumData>,
    fqn: &str,
    visited: &mut BTreeSet<String>,
) {
    let Some(msg) = index.message(fqn) else {
        return;
    };
    if is_map_entry(msg) {
        return;
    }
    for en in &msg.desc.enum_type {
        let enum_fqn = format!("{}.{}", msg.fqn, en.name.as_deref().unwrap_or(""));
        collect_enum_data(index, out, &enum_fqn, visited);
    }
    for nested in &msg.desc.nested_type {
        let nested_fqn = format!("{}.{}", msg.fqn, nested.name.as_deref().unwrap_or(""));
        collect_local_message_enums(index, out, &nested_fqn, visited);
    }
}

fn collect_message_files(
    index: &DescriptorIndex,
    msg: &MessageInfo,
    files: &mut BTreeSet<String>,
    visited: &mut BTreeSet<String>,
) {
    if !visited.insert(msg.fqn.clone()) {
        return;
    }
    files.insert(msg.file_path.clone());
    for field in &msg.desc.field {
        if let Some(target) = field.type_name.as_deref().and_then(|f| index.message(f)) {
            collect_message_files(index, target, files, visited);
        }
        if let Some(en) = field.type_name.as_deref().and_then(|f| index.enum_info(f)) {
            files.insert(en.file_path.clone());
        }
    }
}

fn mark_box_fields(messages: &mut BTreeMap<String, MessageData>) {
    let keys: Vec<String> = messages.keys().cloned().collect();
    for key in keys {
        let Some(mut md) = messages.get(&key).cloned() else {
            continue;
        };
        for field in &mut md.fields {
            if field.proto_kind != "message"
                || field.is_repeated
                || field.is_map
                || field.message_fqn.is_empty()
            {
                continue;
            }
            field.needs_box = can_reach(messages, &field.message_fqn, &key, &mut BTreeSet::new());
        }
        messages.insert(key, md);
    }
}

fn can_reach(
    messages: &BTreeMap<String, MessageData>,
    from: &str,
    target: &str,
    visited: &mut BTreeSet<String>,
) -> bool {
    if from == target {
        return true;
    }
    if !visited.insert(from.to_string()) {
        return false;
    }
    let Some(md) = messages.get(from) else {
        return false;
    };
    for f in &md.fields {
        if f.proto_kind != "message" || f.is_repeated || f.is_map || f.message_fqn.is_empty() {
            continue;
        }
        if can_reach(messages, &f.message_fqn, target, visited) {
            return true;
        }
    }
    false
}

fn is_handle_message(index: &DescriptorIndex, msg: &MessageInfo) -> bool {
    if msg.desc.field.len() != 1 {
        return false;
    }
    let f = &msg.desc.field[0];
    f.name.as_deref() == Some("id")
        && f.r#type() == field_descriptor_proto::Type::Int64
        && f.label() != field_descriptor_proto::Label::Repeated
        && !f
            .type_name
            .as_deref()
            .and_then(|name| index.message(name))
            .map(is_map_entry)
            .unwrap_or(false)
}

fn is_map_entry(msg: &MessageInfo) -> bool {
    msg.desc
        .options
        .as_ref()
        .and_then(|o| o.map_entry)
        .unwrap_or(false)
}

fn qualify_go_type(
    index: &DescriptorIndex,
    file: &FileInfo,
    msg: Option<&MessageInfo>,
    add_import: bool,
    imports: &mut BTreeMap<String, String>,
) -> String {
    let Some(msg) = msg else {
        return String::new();
    };
    let Some(msg_file) = index.file(&msg.file_path) else {
        return msg.go_name.clone();
    };
    if msg_file.go_import_path == file.go_import_path {
        return msg.go_name.clone();
    }
    let alias = go_package_alias(&msg_file.go_import_path);
    if add_import {
        imports.insert(msg_file.go_import_path.clone(), alias.clone());
    }
    format!("{alias}.{}", msg.go_name)
}

fn python_lite_module_name(proto_path: &str) -> String {
    if proto_path.starts_with("google/protobuf/") {
        return "synurang.proto".to_string();
    }
    let stem = trim_proto_suffix(&basename(proto_path)).replace('-', "_");
    format!("{stem}_lite")
}

fn python_module_alias(module: &str) -> String {
    module.replace('_', "__").replace('.', "_dot_")
}

fn qualify_python_type(
    msg: Option<&MessageInfo>,
    imports: &mut BTreeMap<String, String>,
) -> String {
    let Some(msg) = msg else {
        return "object".to_string();
    };
    let module = python_lite_module_name(&msg.file_path);
    let alias = python_module_alias(&module);
    imports.insert(module, alias.clone());
    format!("{alias}.{}", python_identifier(&msg.go_name))
}

fn cpp_lite_message_type(msg: Option<&MessageInfo>, current_file: &FileInfo) -> String {
    let Some(msg) = msg else {
        return "int32_t".to_string();
    };
    let is_local = msg.file_path == current_file.path;
    crate::funcs_lang::cpp_lite_qualified_type(&msg.go_name, &msg.fqn, is_local)
}

pub fn select_template(lang: &str, mode_or_opt: &str) -> Option<&'static str> {
    Some(match lang {
        "go" => match mode_or_opt {
            "plugin_server" => "go_plugin_server.go.tmpl",
            "plugin_client" => "go_plugin_client.go.tmpl",
            _ => "go_default.go.tmpl",
        },
        "dart" => "dart.dart.tmpl",
        "cpp" => match mode_or_opt {
            "plugin_server" => "cpp_plugin_server.cc.tmpl",
            "lite" => "cpp_lite.hpp.tmpl",
            _ => "cpp.h.tmpl",
        },
        "rust" => match mode_or_opt {
            "plugin_server" => "rust_plugin_server.rs.tmpl",
            "native" => "rust_native.rs.tmpl",
            "wasm" => "rust_wasm.rs.tmpl",
            _ => "rust.rs.tmpl",
        },
        "c" => match mode_or_opt {
            "activex" => "c_activex.h.tmpl",
            "lite_header" => "c_lite.h.tmpl",
            "lite_source" => "c_lite.c.tmpl",
            "" | "default" | "native" => "c_native.h.tmpl",
            _ => return None,
        },
        "java" => "java.java.tmpl",
        "python" | "py" => {
            if mode_or_opt == "lite" {
                "python_lite.py.tmpl"
            } else {
                "python.py.tmpl"
            }
        }
        "csharp" => {
            if mode_or_opt == "lite" {
                "csharp_lite.cs.tmpl"
            } else {
                "csharp.cs.tmpl"
            }
        }
        "typescript" | "ts" => {
            if mode_or_opt == "lite" {
                "typescript_lite.ts.tmpl"
            } else {
                "typescript.ts.tmpl"
            }
        }
        "swift" => "swift_lite.swift.tmpl",
        _ => return None,
    })
}

fn output_filename_with_mode(file: &FileInfo, lang: &str, mode: &str, ext: &str) -> String {
    let source_relative_base = trim_proto_suffix(&file.path);
    let mut base = source_relative_base.clone();
    if let Some(idx) = base.rfind('/') {
        base = base[idx + 1..].to_string();
    }
    if mode == "plugin_server" {
        return match lang {
            "go" => format!("{base}_ffi_plugin.pb.go"),
            "cpp" => {
                if ext.is_empty() {
                    format!("{base}_ffi_plugin.cc")
                } else {
                    format!("{base}_ffi_plugin{ext}")
                }
            }
            "rust" => format!("{base}_ffi_plugin.rs"),
            _ => format!("{base}_ffi"),
        };
    }
    if mode == "activex" && lang == "c" {
        return format!("{base}_activex.h");
    }
    if mode == "lite_header" && lang == "c" {
        return format!("{source_relative_base}_lite.h");
    }
    if mode == "lite_source" && lang == "c" {
        return format!("{source_relative_base}_lite.c");
    }
    if mode == "native" {
        return match lang {
            "rust" => format!("{base}_ffi_native.rs"),
            "c" => format!("{base}_ffi_native.h"),
            _ => format!("{base}_ffi"),
        };
    }
    if mode == "wasm" && lang == "rust" {
        return format!("{base}_wasm.rs");
    }
    if mode == "lite" {
        return match lang {
            "csharp" => format!("{base}_lite.cs"),
            "typescript" | "ts" => format!("{base}_lite.ts"),
            "swift" => format!("{base}_lite.swift"),
            "cpp" => format!("{base}_lite.hpp"),
            "python" | "py" => format!("{base}_lite.py"),
            _ => format!("{base}_ffi"),
        };
    }
    match lang {
        "go" => format!("{base}_ffi.pb.go"),
        "dart" => format!("{base}_ffi.pb.dart"),
        "cpp" => format!("{base}_ffi.h"),
        "c" => format!("{base}_ffi_native.h"),
        "rust" => format!("{base}_ffi.rs"),
        "java" => format!("{base}_ffi.java"),
        "csharp" => format!("{base}_ffi.cs"),
        "typescript" | "ts" => format!("{base}_ffi.ts"),
        "swift" => format!("{base}_ffi.swift"),
        "python" | "py" => format!("{base}_ffi.py"),
        _ => format!("{base}_ffi"),
    }
}

fn should_generate_service(service_name: &str, service_list: &BTreeSet<String>) -> bool {
    service_list.is_empty() || service_list.contains(service_name)
}

pub fn has_generated_services(file: &FileInfo, service_list: &BTreeSet<String>) -> bool {
    file.desc.service.iter().any(|svc| {
        should_generate_service(&go_camel(svc.name.as_deref().unwrap_or("")), service_list)
    })
}

fn add_dart_import(
    imports: &mut BTreeSet<String>,
    file: &FileInfo,
    proto_path: &str,
    dart_package: &str,
) {
    if proto_path == file.path {
        return;
    }
    let target = format!("{}.pb.dart", trim_proto_suffix(proto_path));
    let imp = if target.starts_with("google/protobuf/") {
        format!("package:protobuf/well_known_types/{target}")
    } else if !dart_package.is_empty() {
        format!("package:{dart_package}/{target}")
    } else {
        target
    };
    imports.insert(imp);
}

fn compute_file_prefix(path: &str) -> String {
    let base = trim_proto_suffix(&basename(path));
    upper_first(&base)
}

fn c_lite_include_guard(path: &str) -> String {
    let mut guard = String::from("SYNURANG_");
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    for byte in path.as_bytes() {
        guard.push(HEX[(byte >> 4) as usize] as char);
        guard.push(HEX[(byte & 0x0f) as usize] as char);
    }
    guard.push_str("_LITE_H_INCLUDED");
    guard
}

fn native_prefix(svc: &ServiceData) -> String {
    let name = svc.go_name.strip_suffix("Service").unwrap_or(&svc.go_name);
    acronym_aware_snake_case(name)
}

fn infer_dispatch_type(
    prop: &ActiveXProperty,
    set_method: Option<&MethodData>,
    get_method: Option<&MethodData>,
    messages: &BTreeMap<String, MessageData>,
) -> String {
    if set_method.is_none() && get_method.is_none() {
        return String::new();
    }
    let has_get = get_method.is_some();
    let has_put = set_method.is_some();
    if prop.olecolor {
        return if has_get && has_put {
            "color_getput".to_string()
        } else {
            String::new()
        };
    }
    let is_indexed = set_method
        .and_then(|m| messages.get(&m.input_type_key))
        .map(|msg| msg.fields.len() >= 3)
        .unwrap_or(false);
    if is_indexed {
        if has_get && has_put {
            return "indexed_int_getput".to_string();
        }
        if has_put {
            return "indexed_int_put".to_string();
        }
    }
    if has_get && has_put {
        "int_getput".to_string()
    } else if has_put {
        "int_put".to_string()
    } else {
        String::new()
    }
}
