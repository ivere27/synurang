//! protoc plugin entry point.
//!
//! Reads a `CodeGeneratorRequest` from stdin, dispatches to the codegen
//! module per requested language, and writes the encoded
//! `CodeGeneratorResponse` to stdout.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{Read, Write};

use prost::Message;
use prost_types::compiler::{code_generator_response, CodeGeneratorRequest, CodeGeneratorResponse};

mod codegen;
mod funcs_lang;
mod gofmt;
mod model;
mod names;
mod template;
mod value;
mod wire;

use codegen::{
    generate_from_template, generate_from_template_with_generated_files, has_generated_services,
    parse_params, TEMPLATE_FILES,
};
use model::{ActiveXServiceOption, DescriptorIndex, FileInfo};
use template::TemplateEngine;
use wire::parse_active_x_options_from_request;

enum PluginError {
    // Errors from option parsing (mirrors Go's flag.FlagSet path): protogen
    // writes the message to stderr AND populates response.error, then the
    // plugin exits non-zero.
    Flag(String),
    // Errors discovered during codegen (e.g. module-prefix mismatch): protogen
    // sets response.error and exits cleanly; protoc surfaces the message.
    Codegen(String),
}

impl From<String> for PluginError {
    fn from(s: String) -> Self {
        PluginError::Codegen(s)
    }
}

fn main() {
    if let Err(err) = run() {
        let (msg, exit_code, to_stderr) = match err {
            PluginError::Flag(m) => (m, 1, true),
            PluginError::Codegen(m) => (m, 0, false),
        };
        if to_stderr {
            let bin = std::env::args()
                .next()
                .as_deref()
                .map(|s| {
                    std::path::Path::new(s)
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or(s)
                        .to_string()
                })
                .unwrap_or_else(|| "protoc-gen-synurang-ffi".to_string());
            eprintln!("{bin}: {msg}");
        }
        let response = CodeGeneratorResponse {
            error: Some(msg),
            ..Default::default()
        };
        let _ = write_response(response);
        if exit_code != 0 {
            std::process::exit(exit_code);
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn generate_c_files(
    response: &mut CodeGeneratorResponse,
    engine: &TemplateEngine,
    index: &DescriptorIndex,
    file: &FileInfo,
    service_list: &BTreeSet<String>,
    active_x_options: &BTreeMap<(String, String), ActiveXServiceOption>,
    generated_files: &BTreeSet<String>,
    mode: &str,
) -> Result<(), String> {
    if !matches!(mode, "" | "default" | "native" | "activex" | "lite") {
        return Err(format!(
            "unsupported lang/mode: c/{mode}; expected default, native, activex, or lite"
        ));
    }
    if mode == "lite" {
        for output_mode in ["lite_header", "lite_source"] {
            generate_from_template_with_generated_files(
                response,
                engine,
                index,
                file,
                service_list,
                active_x_options,
                generated_files,
                "c",
                output_mode,
            )?;
        }
        return Ok(());
    }
    if matches!(mode, "" | "default" | "native") {
        // The full C binding always contains the dependency-free message
        // codec and, for schema files with selected services, one public
        // service header/source pair. `mode=native` is a compatibility alias;
        // it no longer selects a separate API shape.
        for output_mode in ["lite_header", "lite_source"] {
            generate_from_template_with_generated_files(
                response,
                engine,
                index,
                file,
                service_list,
                active_x_options,
                generated_files,
                "c",
                output_mode,
            )?;
        }
        if has_generated_services(file, service_list) {
            for output_mode in ["ffi_header", "ffi_source"] {
                generate_from_template_with_generated_files(
                    response,
                    engine,
                    index,
                    file,
                    service_list,
                    active_x_options,
                    generated_files,
                    "c",
                    output_mode,
                )?;
            }
        }
        return Ok(());
    }
    generate_from_template_with_generated_files(
        response,
        engine,
        index,
        file,
        service_list,
        active_x_options,
        generated_files,
        "c",
        mode,
    )
}

fn run() -> Result<(), PluginError> {
    let mut input = Vec::new();
    std::io::stdin()
        .read_to_end(&mut input)
        .map_err(|e| PluginError::Codegen(format!("read stdin: {e}")))?;
    let active_x_options = parse_active_x_options_from_request(&input);
    let request = CodeGeneratorRequest::decode(input.as_slice())
        .map_err(|e| PluginError::Codegen(format!("decode CodeGeneratorRequest: {e}")))?;

    let parsed =
        parse_params(request.parameter.as_deref().unwrap_or("")).map_err(PluginError::Flag)?;
    codegen::set_enum_name_style(&parsed.flags).map_err(PluginError::Flag)?;
    let lang = parsed.flags.get("lang").cloned().unwrap_or_default();
    let mode = parsed
        .flags
        .get("mode")
        .cloned()
        .unwrap_or_else(|| "default".to_string());
    let dart_package = parsed
        .flags
        .get("dart_package")
        .cloned()
        .unwrap_or_default();
    let java_package = parsed
        .flags
        .get("java_package")
        .cloned()
        .unwrap_or_default();
    let csharp_namespace = parsed
        .flags
        .get("csharp_namespace")
        .cloned()
        .unwrap_or_default();
    const SUPPORTED_LANGUAGES: &[&str] = &[
        "go",
        "dart",
        "cpp",
        "rust",
        "java",
        "csharp",
        "typescript",
        "ts",
        "c",
        "swift",
        "python",
        "py",
    ];
    if !lang.is_empty() && !SUPPORTED_LANGUAGES.contains(&lang.as_str()) {
        return Err(PluginError::Codegen(format!(
            "unsupported language {lang:?}; expected one of: go, dart, cpp, rust, java, csharp, typescript, c, swift, python"
        )));
    }
    let service_list: BTreeSet<String> = parsed
        .flags
        .get("services")
        .map(|s| {
            s.split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(ToOwned::to_owned)
                .collect()
        })
        .unwrap_or_default();

    let index = DescriptorIndex::new(&request.proto_file, &parsed.import_map);
    let engine = TemplateEngine::new(TEMPLATE_FILES)?;
    let mut response = CodeGeneratorResponse {
        supported_features: Some(code_generator_response::Feature::Proto3Optional as u64),
        ..Default::default()
    };
    let generated_files: BTreeSet<String> = request.file_to_generate.iter().cloned().collect();

    for file_path in &request.file_to_generate {
        let file = index
            .file(file_path)
            .ok_or_else(|| format!("file not found in request: {file_path}"))?;
        if lang == "go" || lang.is_empty() {
            generate_from_template(
                &mut response,
                &engine,
                &index,
                file,
                &service_list,
                &active_x_options,
                "go",
                &mode,
            )?;
        }
        if lang == "dart" || lang.is_empty() {
            generate_from_template(
                &mut response,
                &engine,
                &index,
                file,
                &service_list,
                &active_x_options,
                "dart",
                &dart_package,
            )?;
        }
        if lang == "cpp" {
            generate_from_template(
                &mut response,
                &engine,
                &index,
                file,
                &service_list,
                &active_x_options,
                "cpp",
                &mode,
            )?;
        }
        if lang == "rust" {
            generate_from_template(
                &mut response,
                &engine,
                &index,
                file,
                &service_list,
                &active_x_options,
                "rust",
                &mode,
            )?;
        }
        if lang == "java" {
            generate_from_template(
                &mut response,
                &engine,
                &index,
                file,
                &service_list,
                &active_x_options,
                "java",
                &java_package,
            )?;
        }
        if lang == "python" || lang == "py" {
            let syntax = file.desc.syntax.as_deref().unwrap_or("proto2");
            if syntax != "proto3" {
                return Err(PluginError::Codegen(format!(
                    "Python lite code generation supports proto3 schemas only: {} uses {syntax}",
                    file.path
                )));
            }
            match mode.as_str() {
                "lite" => generate_from_template(
                    &mut response,
                    &engine,
                    &index,
                    file,
                    &service_list,
                    &active_x_options,
                    "python",
                    "lite",
                )?,
                "" | "default" => {
                    generate_from_template(
                        &mut response,
                        &engine,
                        &index,
                        file,
                        &service_list,
                        &active_x_options,
                        "python",
                        "lite",
                    )?;
                    if has_generated_services(file, &service_list) {
                        generate_from_template(
                            &mut response,
                            &engine,
                            &index,
                            file,
                            &service_list,
                            &active_x_options,
                            "python",
                            "default",
                        )?;
                    }
                }
                _ => {
                    return Err(PluginError::Codegen(format!(
                        "unsupported lang/mode: python/{mode}"
                    )));
                }
            }
        }
        if lang == "csharp" {
            let mode_or_opt = if mode == "lite" {
                "lite".to_string()
            } else {
                csharp_namespace.clone()
            };
            generate_from_template(
                &mut response,
                &engine,
                &index,
                file,
                &service_list,
                &active_x_options,
                "csharp",
                &mode_or_opt,
            )?;
        }
        if lang == "typescript" || lang == "ts" {
            if (mode.is_empty() || mode == "default") && has_generated_services(file, &service_list)
            {
                generate_from_template(
                    &mut response,
                    &engine,
                    &index,
                    file,
                    &service_list,
                    &active_x_options,
                    "typescript",
                    "lite",
                )?;
            }
            generate_from_template(
                &mut response,
                &engine,
                &index,
                file,
                &service_list,
                &active_x_options,
                "typescript",
                &mode,
            )?;
        }
        if lang == "c" {
            generate_c_files(
                &mut response,
                &engine,
                &index,
                file,
                &service_list,
                &active_x_options,
                &generated_files,
                &mode,
            )?;
        }
        if lang == "swift" {
            let mode_or_opt = if mode == "lite" { "lite" } else { &mode };
            generate_from_template(
                &mut response,
                &engine,
                &index,
                file,
                &service_list,
                &active_x_options,
                "swift",
                mode_or_opt,
            )?;
        }
    }

    if parsed.annotate_code {
        // protogen emits an empty `.meta` (GeneratedCodeInfo) sidecar next
        // to each Go output when annotate_code is set. Our templates don't
        // track source spans for generated symbols, so the file is empty —
        // matching protogen's output for these generators in practice.
        let mut metas = Vec::new();
        for file in &response.file {
            let Some(name) = file.name.as_deref() else {
                continue;
            };
            if !name.ends_with(".go") {
                continue;
            }
            let meta = code_generator_response::File {
                name: Some(format!("{name}.meta")),
                content: Some(String::new()),
                ..Default::default()
            };
            metas.push(meta);
        }
        response.file.extend(metas);
    }

    if !parsed.module.is_empty() {
        let prefix = format!("{}/", parsed.module);
        for file in &response.file {
            let name = file.name.as_deref().unwrap_or("");
            if !name.starts_with(&prefix) {
                return Err(PluginError::Codegen(format!(
                    "{name}: generated file does not match prefix \"{}\"",
                    parsed.module
                )));
            }
        }
    }

    write_response(response).map_err(PluginError::Codegen)
}

fn write_response(response: CodeGeneratorResponse) -> Result<(), String> {
    let mut out = Vec::new();
    response
        .encode(&mut out)
        .map_err(|e| format!("encode CodeGeneratorResponse: {e}"))?;
    std::io::stdout()
        .write_all(&out)
        .map_err(|e| format!("write stdout: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost_types::{
        field_descriptor_proto, DescriptorProto, FieldDescriptorProto, FileDescriptorProto,
        MethodDescriptorProto, ServiceDescriptorProto,
    };

    fn c_fixture(with_service: bool) -> Vec<FileDescriptorProto> {
        let mut file = FileDescriptorProto {
            name: Some("nested/example.proto".to_string()),
            package: Some("example.v1".to_string()),
            syntax: Some("proto3".to_string()),
            message_type: vec![
                DescriptorProto {
                    name: Some("Request".to_string()),
                    ..Default::default()
                },
                DescriptorProto {
                    name: Some("Response".to_string()),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        if with_service {
            file.service.push(ServiceDescriptorProto {
                name: Some("ExampleService".to_string()),
                method: vec![
                    MethodDescriptorProto {
                        name: Some("Unary".to_string()),
                        input_type: Some(".example.v1.Request".to_string()),
                        output_type: Some(".example.v1.Response".to_string()),
                        ..Default::default()
                    },
                    MethodDescriptorProto {
                        name: Some("Watch".to_string()),
                        input_type: Some(".example.v1.Request".to_string()),
                        output_type: Some(".example.v1.Response".to_string()),
                        server_streaming: Some(true),
                        ..Default::default()
                    },
                ],
                ..Default::default()
            });
        }
        vec![file]
    }

    fn generate_c_fixture(mode: &str, with_service: bool) -> CodeGeneratorResponse {
        // Rendering C reads the process-wide enum name style, so hold it steady
        // against the case that exercises changing it.
        let _guard = codegen::enum_name_style_test_lock();
        let descriptors = c_fixture(with_service);
        let index = DescriptorIndex::new(&descriptors, &BTreeMap::new());
        let file = index.file("nested/example.proto").unwrap();
        let engine = TemplateEngine::new(TEMPLATE_FILES).unwrap();
        let mut response = CodeGeneratorResponse::default();
        generate_c_files(
            &mut response,
            &engine,
            &index,
            file,
            &BTreeSet::new(),
            &BTreeMap::new(),
            &BTreeSet::from(["nested/example.proto".to_string()]),
            mode,
        )
        .unwrap();
        response
    }

    fn output_names(response: &CodeGeneratorResponse) -> Vec<&str> {
        response
            .file
            .iter()
            .map(|file| file.name.as_deref().unwrap())
            .collect()
    }

    fn generate_c_descriptors(
        descriptors: &[FileDescriptorProto],
        file_path: &str,
        mode: &str,
    ) -> Result<CodeGeneratorResponse, String> {
        let _guard = codegen::enum_name_style_test_lock();
        let index = DescriptorIndex::new(descriptors, &BTreeMap::new());
        let file = index.file(file_path).unwrap();
        let engine = TemplateEngine::new(TEMPLATE_FILES).unwrap();
        let mut response = CodeGeneratorResponse::default();
        generate_c_files(
            &mut response,
            &engine,
            &index,
            file,
            &BTreeSet::new(),
            &BTreeMap::new(),
            &BTreeSet::from([file_path.to_string()]),
            mode,
        )?;
        Ok(response)
    }

    #[test]
    fn c_default_and_native_alias_emit_the_same_full_surface() {
        let expected = vec![
            "nested/example_lite.h",
            "nested/example_lite.c",
            "nested/example_ffi.h",
            "nested/example_ffi.c",
        ];
        assert_eq!(output_names(&generate_c_fixture("default", true)), expected);
        assert_eq!(output_names(&generate_c_fixture("native", true)), expected);
    }

    #[test]
    fn c_lite_and_service_free_files_do_not_emit_ffi_files() {
        let lite = vec!["nested/example_lite.h", "nested/example_lite.c"];
        assert_eq!(output_names(&generate_c_fixture("lite", true)), lite);
        assert_eq!(output_names(&generate_c_fixture("default", false)), lite);
    }

    #[test]
    fn c_ffi_header_is_the_single_c_service_surface() {
        let response = generate_c_fixture("default", true);
        let header = response
            .file
            .iter()
            .find(|file| file.name.as_deref() == Some("nested/example_ffi.h"))
            .and_then(|file| file.content.as_deref())
            .unwrap();
        let source = response
            .file
            .iter()
            .find(|file| file.name.as_deref() == Some("nested/example_ffi.c"))
            .and_then(|file| file.content.as_deref())
            .unwrap();

        assert!(header.contains("#include \"example_lite.h\""));
        assert!(header.contains("#include <synurang/c_runtime.h>"));
        assert!(header.contains("typedef struct ExampleServiceHandlers"));
        assert!(header.contains("typedef struct ExampleServiceWatchHandlers"));
        assert!(header.contains("Synurang_Invoke_ExampleService"));
        assert!(header.contains("example_register_with_runtime"));
        assert!(!header.contains("ffi_native_server"));
        assert!(source.contains("#include \"example_ffi.h\""));
        assert!(source.contains("Synurang_Stream_ExampleService_Open"));
    }

    #[test]
    fn c_imported_only_service_includes_source_relative_lite_dependency() {
        let dependency = FileDescriptorProto {
            name: Some("shared/types.proto".to_string()),
            package: Some("dependency.v1".to_string()),
            syntax: Some("proto3".to_string()),
            message_type: vec![
                DescriptorProto {
                    name: Some("Request".to_string()),
                    ..Default::default()
                },
                DescriptorProto {
                    name: Some("Response".to_string()),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        let service = FileDescriptorProto {
            name: Some("api/imported_service.proto".to_string()),
            package: Some("service.v1".to_string()),
            syntax: Some("proto3".to_string()),
            dependency: vec!["shared/types.proto".to_string()],
            service: vec![ServiceDescriptorProto {
                name: Some("ImportedService".to_string()),
                method: vec![MethodDescriptorProto {
                    name: Some("Call".to_string()),
                    input_type: Some(".dependency.v1.Request".to_string()),
                    output_type: Some(".dependency.v1.Response".to_string()),
                    ..Default::default()
                }],
                ..Default::default()
            }],
            ..Default::default()
        };
        let descriptors = vec![dependency, service];
        let response =
            generate_c_descriptors(&descriptors, "api/imported_service.proto", "default").unwrap();

        assert_eq!(
            output_names(&response),
            vec![
                "api/imported_service_lite.h",
                "api/imported_service_lite.c",
                "api/imported_service_ffi.h",
                "api/imported_service_ffi.c",
            ]
        );
        let lite_header = response
            .file
            .iter()
            .find(|file| file.name.as_deref() == Some("api/imported_service_lite.h"))
            .and_then(|file| file.content.as_deref())
            .unwrap();
        let ffi_header = response
            .file
            .iter()
            .find(|file| file.name.as_deref() == Some("api/imported_service_ffi.h"))
            .and_then(|file| file.content.as_deref())
            .unwrap();
        let ffi_source = response
            .file
            .iter()
            .find(|file| file.name.as_deref() == Some("api/imported_service_ffi.c"))
            .and_then(|file| file.content.as_deref())
            .unwrap();

        assert!(!lite_header.contains("../shared/types_lite.h"));
        assert!(ffi_header.contains("#include \"imported_service_lite.h\""));
        assert!(ffi_header.contains("#include \"../shared/types_lite.h\""));
        assert!(ffi_header.contains("#include <synurang/c_runtime.h>"));
        assert!(ffi_header.contains("typedef struct ImportedServiceHandlers"));
        assert!(ffi_source.contains("#include \"imported_service_ffi.h\""));
        assert!(ffi_source.contains("dependency_v1_request_init"));
        assert!(ffi_source.contains("dependency_v1_response_encode"));

        let lite =
            generate_c_descriptors(&descriptors, "api/imported_service.proto", "lite").unwrap();
        assert_eq!(
            output_names(&lite),
            vec!["api/imported_service_lite.h", "api/imported_service_lite.c",]
        );
        let public_lite_header = lite
            .file
            .iter()
            .find(|file| file.name.as_deref() == Some("api/imported_service_lite.h"))
            .and_then(|file| file.content.as_deref())
            .unwrap();
        assert!(!public_lite_header.contains("../shared/types_lite.h"));
        assert!(!public_lite_header.contains("ImportedService"));
        assert!(!public_lite_header.contains("synurang/c_runtime.h"));
    }

    #[test]
    fn c_lite_does_not_validate_rpc_only_service_types() {
        let file = FileDescriptorProto {
            name: Some("message_only.proto".to_string()),
            package: Some("message.only.v1".to_string()),
            syntax: Some("proto3".to_string()),
            message_type: vec![DescriptorProto {
                name: Some("LocalMessage".to_string()),
                ..Default::default()
            }],
            service: vec![ServiceDescriptorProto {
                name: Some("ClockService".to_string()),
                method: vec![MethodDescriptorProto {
                    name: Some("Watch".to_string()),
                    input_type: Some(".google.protobuf.Timestamp".to_string()),
                    output_type: Some(".google.protobuf.Timestamp".to_string()),
                    server_streaming: Some(true),
                    ..Default::default()
                }],
                ..Default::default()
            }],
            ..Default::default()
        };

        let lite = generate_c_descriptors(&[file.clone()], "message_only.proto", "lite").unwrap();
        assert_eq!(
            output_names(&lite),
            vec!["message_only_lite.h", "message_only_lite.c"]
        );
        let error = generate_c_descriptors(&[file], "message_only.proto", "default").unwrap_err();
        assert!(error.contains("google.protobuf.Timestamp"), "{error}");
    }

    #[test]
    fn c_ffi_rejects_method_symbol_collision_with_reserved_service_api() {
        let file = FileDescriptorProto {
            name: Some("collision.proto".to_string()),
            package: Some("collision.v1".to_string()),
            syntax: Some("proto3".to_string()),
            message_type: vec![
                DescriptorProto {
                    name: Some("Request".to_string()),
                    ..Default::default()
                },
                DescriptorProto {
                    name: Some("Response".to_string()),
                    ..Default::default()
                },
            ],
            service: vec![ServiceDescriptorProto {
                name: Some("FooService".to_string()),
                method: vec![MethodDescriptorProto {
                    name: Some("Free".to_string()),
                    input_type: Some(".collision.v1.Request".to_string()),
                    output_type: Some(".collision.v1.Response".to_string()),
                    ..Default::default()
                }],
                ..Default::default()
            }],
            ..Default::default()
        };

        let error = generate_c_descriptors(&[file], "collision.proto", "default").unwrap_err();
        assert!(error.contains("C FFI symbol collision"), "{error}");
        assert!(error.contains("foo_free"), "{error}");
        assert!(error.contains("FooService.Free"), "{error}");
    }

    #[test]
    fn c_ffi_rejects_method_symbol_collision_with_repeated_add_helper() {
        let file = FileDescriptorProto {
            name: Some("repeated_collision.proto".to_string()),
            syntax: Some("proto3".to_string()),
            message_type: vec![
                DescriptorProto {
                    name: Some("FooAdd".to_string()),
                    field: vec![FieldDescriptorProto {
                        name: Some("bars".to_string()),
                        number: Some(1),
                        label: Some(field_descriptor_proto::Label::Repeated as i32),
                        r#type: Some(field_descriptor_proto::Type::Int32 as i32),
                        ..Default::default()
                    }],
                    ..Default::default()
                },
                DescriptorProto {
                    name: Some("Request".to_string()),
                    ..Default::default()
                },
                DescriptorProto {
                    name: Some("Response".to_string()),
                    ..Default::default()
                },
            ],
            service: vec![ServiceDescriptorProto {
                name: Some("FooService".to_string()),
                method: vec![MethodDescriptorProto {
                    name: Some("AddAddBars".to_string()),
                    input_type: Some(".Request".to_string()),
                    output_type: Some(".Response".to_string()),
                    ..Default::default()
                }],
                ..Default::default()
            }],
            ..Default::default()
        };

        let error =
            generate_c_descriptors(&[file], "repeated_collision.proto", "default").unwrap_err();
        assert!(error.contains("C FFI symbol collision"), "{error}");
        assert!(error.contains("foo_add_add_bars"), "{error}");
        assert!(error.contains("FooService.AddAddBars"), "{error}");
        assert!(error.contains("FooAdd.bars"), "{error}");
    }

    #[test]
    fn c_lite_rejects_well_known_type_collisions() {
        for (type_name, proto_name) in [
            ("SynurangProtobufTimestamp", "google.protobuf.Timestamp"),
            ("SynurangProtobufDuration", "google.protobuf.Duration"),
        ] {
            let file = FileDescriptorProto {
                name: Some("well_known_collision.proto".to_string()),
                syntax: Some("proto3".to_string()),
                message_type: vec![DescriptorProto {
                    name: Some(type_name.to_string()),
                    ..Default::default()
                }],
                ..Default::default()
            };

            let error =
                generate_c_descriptors(&[file], "well_known_collision.proto", "lite").unwrap_err();
            assert!(error.contains("C lite symbol collision"), "{error}");
            assert!(error.contains(type_name), "{error}");
            assert!(error.contains(proto_name), "{error}");
        }
    }

    #[test]
    fn c_lite_rejects_reachable_dependency_collision_with_well_known_type() {
        let dependency = FileDescriptorProto {
            name: Some("shared/wkt_collision.proto".to_string()),
            package: Some("synurang.protobuf".to_string()),
            syntax: Some("proto3".to_string()),
            message_type: vec![DescriptorProto {
                name: Some("Timestamp".to_string()),
                ..Default::default()
            }],
            ..Default::default()
        };
        let root = FileDescriptorProto {
            name: Some("api/uses_collision.proto".to_string()),
            package: Some("consumer.v1".to_string()),
            syntax: Some("proto3".to_string()),
            dependency: vec!["shared/wkt_collision.proto".to_string()],
            message_type: vec![DescriptorProto {
                name: Some("Envelope".to_string()),
                field: vec![FieldDescriptorProto {
                    name: Some("timestamp".to_string()),
                    number: Some(1),
                    label: Some(field_descriptor_proto::Label::Optional as i32),
                    r#type: Some(field_descriptor_proto::Type::Message as i32),
                    type_name: Some(".synurang.protobuf.Timestamp".to_string()),
                    ..Default::default()
                }],
                ..Default::default()
            }],
            ..Default::default()
        };

        let error = generate_c_descriptors(&[dependency, root], "api/uses_collision.proto", "lite")
            .unwrap_err();
        assert!(error.contains("has no valid C symbol surface"), "{error}");
        assert!(
            !error.contains("has no valid C enum_names spelling"),
            "{error}"
        );
        assert!(error.contains("C lite symbol collision"), "{error}");
        assert!(error.contains("SynurangProtobufTimestamp"), "{error}");
        assert!(error.contains("google.protobuf.Timestamp"), "{error}");
        assert!(error.contains("synurang.protobuf.Timestamp"), "{error}");
    }

    #[test]
    fn c_ffi_rejects_method_collisions_with_common_lite_helpers() {
        for (service_name, method_name, symbol) in [
            (
                "SynurangLiteService",
                "ReadVarint",
                "synurang_lite_read_varint",
            ),
            (
                "SynurangLiteService",
                "SecondsNanosMerge",
                "synurang_lite_seconds_nanos_merge",
            ),
            (
                "SynurangProtobufService",
                "EmptyMergeAtDepth",
                "synurang_protobuf_empty_merge_at_depth",
            ),
            (
                "SynurangProtobufService",
                "TimestampDecode",
                "synurang_protobuf_timestamp_decode",
            ),
            (
                "SynurangProtobufService",
                "DurationEncode",
                "synurang_protobuf_duration_encode",
            ),
        ] {
            let file = FileDescriptorProto {
                name: Some("runtime_helper_collision.proto".to_string()),
                syntax: Some("proto3".to_string()),
                message_type: vec![
                    DescriptorProto {
                        name: Some("Request".to_string()),
                        ..Default::default()
                    },
                    DescriptorProto {
                        name: Some("Response".to_string()),
                        ..Default::default()
                    },
                ],
                service: vec![ServiceDescriptorProto {
                    name: Some(service_name.to_string()),
                    method: vec![MethodDescriptorProto {
                        name: Some(method_name.to_string()),
                        input_type: Some(".Request".to_string()),
                        output_type: Some(".Response".to_string()),
                        ..Default::default()
                    }],
                    ..Default::default()
                }],
                ..Default::default()
            };

            let error =
                generate_c_descriptors(&[file], "runtime_helper_collision.proto", "default")
                    .unwrap_err();
            assert!(error.contains("C FFI symbol collision"), "{error}");
            assert!(error.contains(symbol), "{error}");
            assert!(
                error.contains(&format!("{service_name}.{method_name}")),
                "{error}"
            );
        }
    }
}
