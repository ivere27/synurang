//! Hand-rolled protobuf wire reader.
//!
//! Used to extract the `synurang.v1.activex_service` extension from each
//! `ServiceDescriptorProto.options` block. `prost-types` decodes options as an
//! opaque [`prost_types::ServiceOptions`] without unknown-field retention, so
//! we re-scan the raw `CodeGeneratorRequest` bytes ourselves to recover the
//! extension value.

use std::collections::BTreeMap;

use crate::model::{ActiveXProperty, ActiveXServiceOption};

/// Extension field number registered for `synurang.v1.activex_service`
/// on `google.protobuf.ServiceOptions`. Keep in sync with `api/activex.proto`.
const ACTIVEX_SERVICE_EXT_FIELD: u64 = 50100;

pub fn parse_active_x_options_from_request(
    input: &[u8],
) -> BTreeMap<(String, String), ActiveXServiceOption> {
    let mut out = BTreeMap::new();
    let mut pos = 0usize;
    while pos < input.len() {
        let Some(key) = read_varint(input, &mut pos) else {
            break;
        };
        let field = key >> 3;
        let wire = key & 0x7;
        // CodeGeneratorRequest.proto_file = 15 (repeated FileDescriptorProto)
        if field == 15 && wire == 2 {
            let Some(bytes) = read_len(input, &mut pos) else {
                break;
            };
            parse_active_x_options_from_file(bytes, &mut out);
        } else if !skip_wire(input, &mut pos, wire) {
            break;
        }
    }
    out
}

fn parse_active_x_options_from_file(
    input: &[u8],
    out: &mut BTreeMap<(String, String), ActiveXServiceOption>,
) {
    let mut pos = 0usize;
    let mut file_path = String::new();
    let mut services: Vec<(String, ActiveXServiceOption)> = Vec::new();
    while pos < input.len() {
        let Some(key) = read_varint(input, &mut pos) else {
            break;
        };
        let field = key >> 3;
        let wire = key & 0x7;
        match (field, wire) {
            // FileDescriptorProto.name = 1
            (1, 2) => {
                file_path = read_len(input, &mut pos)
                    .and_then(|b| std::str::from_utf8(b).ok())
                    .unwrap_or("")
                    .to_string();
            }
            // FileDescriptorProto.service = 6
            (6, 2) => {
                if let Some(bytes) = read_len(input, &mut pos) {
                    if let Some((name, option)) = parse_service_descriptor_raw(bytes) {
                        services.push((name, option));
                    }
                } else {
                    break;
                }
            }
            _ => {
                if !skip_wire(input, &mut pos, wire) {
                    break;
                }
            }
        }
    }
    if !file_path.is_empty() {
        for (service, option) in services {
            out.insert((file_path.clone(), service), option);
        }
    }
}

fn parse_service_descriptor_raw(input: &[u8]) -> Option<(String, ActiveXServiceOption)> {
    let mut pos = 0usize;
    let mut service_name = String::new();
    let mut option = None;
    while pos < input.len() {
        let key = read_varint(input, &mut pos)?;
        let field = key >> 3;
        let wire = key & 0x7;
        match (field, wire) {
            // ServiceDescriptorProto.name = 1
            (1, 2) => {
                service_name = read_len(input, &mut pos)
                    .and_then(|b| std::str::from_utf8(b).ok())
                    .unwrap_or("")
                    .to_string();
            }
            // ServiceDescriptorProto.options = 3
            (3, 2) => {
                let bytes = read_len(input, &mut pos)?;
                option = parse_service_options_raw(bytes);
            }
            _ => {
                if !skip_wire(input, &mut pos, wire) {
                    return None;
                }
            }
        }
    }
    option.map(|opt| (service_name, opt))
}

fn parse_service_options_raw(input: &[u8]) -> Option<ActiveXServiceOption> {
    let mut pos = 0usize;
    while pos < input.len() {
        let key = read_varint(input, &mut pos)?;
        let field = key >> 3;
        let wire = key & 0x7;
        if field == ACTIVEX_SERVICE_EXT_FIELD && wire == 2 {
            return read_len(input, &mut pos).map(parse_active_x_service_option_raw);
        }
        if !skip_wire(input, &mut pos, wire) {
            return None;
        }
    }
    None
}

fn parse_active_x_service_option_raw(input: &[u8]) -> ActiveXServiceOption {
    let mut pos = 0usize;
    let mut option = ActiveXServiceOption::default();
    while pos < input.len() {
        let Some(key) = read_varint(input, &mut pos) else {
            break;
        };
        let field = key >> 3;
        let wire = key & 0x7;
        match (field, wire) {
            (1, 2) => {
                option.prefix = read_len(input, &mut pos)
                    .and_then(|b| std::str::from_utf8(b).ok())
                    .unwrap_or("")
                    .to_string();
            }
            (2, 2) => {
                if let Some(bytes) = read_len(input, &mut pos) {
                    option.properties.push(parse_active_x_property_raw(bytes));
                } else {
                    break;
                }
            }
            _ => {
                if !skip_wire(input, &mut pos, wire) {
                    break;
                }
            }
        }
    }
    option
}

fn parse_active_x_property_raw(input: &[u8]) -> ActiveXProperty {
    let mut pos = 0usize;
    let mut prop = ActiveXProperty::default();
    while pos < input.len() {
        let Some(key) = read_varint(input, &mut pos) else {
            break;
        };
        let field = key >> 3;
        let wire = key & 0x7;
        match (field, wire) {
            (1, 0) => prop.dispid = read_varint(input, &mut pos).unwrap_or(0) as i32,
            (2, 2) => {
                prop.name = read_len(input, &mut pos)
                    .and_then(|b| std::str::from_utf8(b).ok())
                    .unwrap_or("")
                    .to_string();
            }
            (3, 0) => prop.custom = read_varint(input, &mut pos).unwrap_or(0) != 0,
            (4, 0) => prop.olecolor = read_varint(input, &mut pos).unwrap_or(0) != 0,
            (5, 2) => {
                prop.set_method = read_len(input, &mut pos)
                    .and_then(|b| std::str::from_utf8(b).ok())
                    .unwrap_or("")
                    .to_string();
            }
            (6, 2) => {
                prop.get_method = read_len(input, &mut pos)
                    .and_then(|b| std::str::from_utf8(b).ok())
                    .unwrap_or("")
                    .to_string();
            }
            _ => {
                if !skip_wire(input, &mut pos, wire) {
                    break;
                }
            }
        }
    }
    prop
}

fn read_varint(input: &[u8], pos: &mut usize) -> Option<u64> {
    let mut value = 0u64;
    let mut shift = 0u32;
    while *pos < input.len() && shift < 64 {
        let byte = input[*pos];
        *pos += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some(value);
        }
        shift += 7;
    }
    None
}

fn read_len<'a>(input: &'a [u8], pos: &mut usize) -> Option<&'a [u8]> {
    let len = read_varint(input, pos)? as usize;
    if *pos + len > input.len() {
        return None;
    }
    let out = &input[*pos..*pos + len];
    *pos += len;
    Some(out)
}

fn skip_wire(input: &[u8], pos: &mut usize, wire: u64) -> bool {
    match wire {
        0 => read_varint(input, pos).is_some(),
        1 => {
            *pos = (*pos).saturating_add(8);
            *pos <= input.len()
        }
        2 => read_len(input, pos).is_some(),
        5 => {
            *pos = (*pos).saturating_add(4);
            *pos <= input.len()
        }
        _ => false,
    }
}
