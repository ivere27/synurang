//! Identifier/case helpers shared by the generator and the template builtins.

use std::path::Path;

pub fn basename(path: &str) -> String {
    Path::new(path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(path)
        .to_string()
}

pub fn trim_proto_suffix(path: &str) -> String {
    path.strip_suffix(".proto").unwrap_or(path).to_string()
}

pub fn upper_first(s: &str) -> String {
    if s.is_empty() {
        String::new()
    } else {
        format!("{}{}", s[..1].to_uppercase(), &s[1..])
    }
}

pub fn lower_first(s: &str) -> String {
    if s.is_empty() {
        String::new()
    } else {
        format!("{}{}", s[..1].to_lowercase(), &s[1..])
    }
}

pub fn pascal_from_snake(s: &str) -> String {
    s.split('_')
        .filter(|p| !p.is_empty())
        .map(upper_first)
        .collect::<String>()
}

pub fn lower_camel_from_snake(s: &str) -> String {
    let mut parts = s.split('_');
    let mut out = parts.next().unwrap_or("").to_string();
    for p in parts {
        if !p.is_empty() {
            out.push_str(&upper_first(p));
        }
    }
    out
}

pub fn go_camel(s: &str) -> String {
    let mut out = String::new();
    let mut cap_next = true;
    for ch in s.chars() {
        if ch == '_' || ch == '-' || ch == '.' {
            cap_next = true;
            continue;
        }
        if out.is_empty() && ch.is_ascii_digit() {
            out.push('X');
        }
        if cap_next {
            out.extend(ch.to_uppercase());
            cap_next = false;
        } else {
            out.push(ch);
        }
    }
    out
}

pub fn to_snake_case(s: &str) -> String {
    let mut out = String::new();
    for (i, ch) in s.chars().enumerate() {
        if i > 0 && ch.is_ascii_uppercase() {
            out.push('_');
        }
        out.extend(ch.to_lowercase());
    }
    out
}

pub fn acronym_aware_snake_case(s: &str) -> String {
    let runes: Vec<char> = s.chars().collect();
    let mut out = String::new();
    for (i, &ch) in runes.iter().enumerate() {
        if i > 0 && ch.is_ascii_uppercase() {
            let prev = runes[i - 1];
            if prev.is_ascii_lowercase()
                || (i + 1 < runes.len() && runes[i + 1].is_ascii_lowercase())
            {
                out.push('_');
            }
        }
        out.extend(ch.to_lowercase());
    }
    out
}

pub fn to_screaming_snake(s: &str) -> String {
    acronym_aware_snake_case(s).to_uppercase()
}

pub fn to_lower_camel_from_underscored(s: &str) -> String {
    let mut out = String::new();
    let mut first = true;
    for part in s.to_lowercase().split('_') {
        if part.is_empty() {
            continue;
        }
        if first {
            out.push_str(part);
            first = false;
        } else {
            out.push_str(&upper_first(part));
        }
    }
    out
}
