//! protoc plugin entry point.
//!
//! Reads a `CodeGeneratorRequest` from stdin, dispatches to the codegen
//! module per requested language, and writes the encoded
//! `CodeGeneratorResponse` to stdout.

use std::collections::BTreeSet;
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
    generate_from_template, has_generated_services, parse_params, TEMPLATE_FILES,
};
use model::DescriptorIndex;
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
        let mut response = CodeGeneratorResponse::default();
        response.error = Some(msg);
        let _ = write_response(response);
        if exit_code != 0 {
            std::process::exit(exit_code);
        }
    }
}

fn run() -> Result<(), PluginError> {
    let mut input = Vec::new();
    std::io::stdin()
        .read_to_end(&mut input)
        .map_err(|e| PluginError::Codegen(format!("read stdin: {e}")))?;
    let active_x_options = parse_active_x_options_from_request(&input);
    let request = CodeGeneratorRequest::decode(input.as_slice())
        .map_err(|e| PluginError::Codegen(format!("decode CodeGeneratorRequest: {e}")))?;

    let parsed = parse_params(request.parameter.as_deref().unwrap_or("")).map_err(PluginError::Flag)?;
    let lang = parsed.flags.get("lang").cloned().unwrap_or_default();
    let mode = parsed
        .flags
        .get("mode")
        .cloned()
        .unwrap_or_else(|| "default".to_string());
    let dart_package = parsed.flags.get("dart_package").cloned().unwrap_or_default();
    let java_package = parsed.flags.get("java_package").cloned().unwrap_or_default();
    let csharp_namespace = parsed
        .flags
        .get("csharp_namespace")
        .cloned()
        .unwrap_or_default();
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
    let mut response = CodeGeneratorResponse::default();
    response.supported_features = Some(code_generator_response::Feature::Proto3Optional as u64);

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
            generate_from_template(
                &mut response,
                &engine,
                &index,
                file,
                &service_list,
                &active_x_options,
                "c",
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
            let mut meta = code_generator_response::File::default();
            meta.name = Some(format!("{name}.meta"));
            meta.content = Some(String::new());
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
