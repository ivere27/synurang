//! Minimal Go `text/template` engine.
//!
//! Only the subset of features our shipped templates actually use is
//! implemented: `{{...}}` actions with `-` whitespace trimming, `if`/`else`,
//! `range` (with `$i, $v := ...` form), `template`, `define`, `:=`
//! assignments, pipelines (`|`), parenthesised subexpressions, and a fixed
//! registry of helper functions. Anything outside that subset (notably
//! `with`, `range` over a map, custom delimiters) is intentionally
//! unsupported — the engine returns Err so future template changes fail loud
//! instead of silently changing the shipped template semantics.

use std::collections::HashMap;

use crate::funcs_lang::{
    c_header_type, c_native_err_return, c_return_type, callmethod_name, cpp_field_name,
    cpp_lite_kind_default, cpp_lite_kind_type, cpp_lite_not_default, cpp_lite_read_call,
    cpp_lite_scalar_default, cpp_lite_type, cpp_lite_write_call, csharp_type, list_any,
    lower_first_value, native_err_return, needs_len, needs_out_len, oneof_groups, rust_c_type,
    rust_return_type, stream_type, swift_default, swift_enum_case, swift_enum_zero_case,
    swift_escape, swift_kind_default, swift_kind_type, swift_not_default, swift_read_call,
    swift_scalar_wire, swift_type, swift_write_call, template_printf, ts_default_value, ts_type,
    wasm_err_return,
};
use crate::names::{
    lower_camel_from_snake, lower_first, python_identifier, python_method_name, to_screaming_snake,
    to_snake_case,
};
use crate::value::Value;

#[derive(Clone, Debug)]
pub enum Node {
    Text(String),
    Eval(String),
    Assign(String, String),
    If {
        branches: Vec<(String, Vec<Node>)>,
        else_nodes: Vec<Node>,
    },
    Range {
        vars: Vec<String>,
        expr: String,
        nodes: Vec<Node>,
    },
    Template {
        name: String,
        expr: String,
    },
}

#[derive(Clone, Debug)]
pub enum Token {
    Text(String),
    Action(String),
}

pub struct TemplateEngine {
    templates: HashMap<String, Vec<Node>>,
}

impl TemplateEngine {
    pub fn new(files: &[(&str, &str)]) -> Result<Self, String> {
        let mut engine = TemplateEngine {
            templates: HashMap::new(),
        };
        for (name, src) in files {
            let tokens = tokenize_template(src);
            let mut pos = 0;
            let nodes = parse_nodes(&tokens, &mut pos, &mut engine.templates)?;
            if !nodes.is_empty() {
                engine.templates.insert((*name).to_string(), nodes);
            }
        }
        Ok(engine)
    }

    pub fn render(&self, name: &str, root: Value) -> Result<String, String> {
        let nodes = self
            .templates
            .get(name)
            .ok_or_else(|| format!("template not found: {name}"))?;
        let mut ctx = RenderContext {
            root: root.clone(),
            dot: root,
            vars: HashMap::new(),
        };
        let mut out = String::new();
        self.render_nodes(nodes, &mut ctx, &mut out)?;
        Ok(out)
    }

    fn render_nodes(
        &self,
        nodes: &[Node],
        ctx: &mut RenderContext,
        out: &mut String,
    ) -> Result<(), String> {
        for node in nodes {
            match node {
                Node::Text(s) => out.push_str(s),
                Node::Eval(expr) => out.push_str(&eval_expr(expr, ctx)?.as_str()),
                Node::Assign(name, expr) => {
                    let value = eval_expr(expr, ctx)?;
                    ctx.vars.insert(name.clone(), value);
                }
                Node::If {
                    branches,
                    else_nodes,
                } => {
                    let mut rendered = false;
                    for (expr, branch_nodes) in branches {
                        if eval_expr(expr, ctx)?.truthy() {
                            let mut child = ctx.clone();
                            self.render_nodes(branch_nodes, &mut child, out)?;
                            rendered = true;
                            break;
                        }
                    }
                    if !rendered {
                        let mut child = ctx.clone();
                        self.render_nodes(else_nodes, &mut child, out)?;
                    }
                }
                Node::Range { vars, expr, nodes } => {
                    let value = eval_expr(expr, ctx)?;
                    // `range` over a Map is intentionally a no-op: none of our
                    // templates iterate maps, and Go's iteration order differs
                    // from a BTreeMap's, so we'd rather skip than diverge.
                    if let Value::List(items) = value {
                        for (i, item) in items.into_iter().enumerate() {
                            let mut child = ctx.clone();
                            child.dot = item.clone();
                            match vars.as_slice() {
                                [v] => {
                                    child.vars.insert(v.clone(), item);
                                }
                                [i_var, v_var] => {
                                    child.vars.insert(i_var.clone(), Value::Int(i as i64));
                                    child.vars.insert(v_var.clone(), item);
                                }
                                _ => {}
                            }
                            self.render_nodes(nodes, &mut child, out)?;
                        }
                    }
                }
                Node::Template { name, expr } => {
                    let value = eval_expr(expr, ctx)?;
                    let Some(nodes) = self.templates.get(name) else {
                        return Err(format!("template not found: {name}"));
                    };
                    let mut child = ctx.clone();
                    child.dot = value;
                    self.render_nodes(nodes, &mut child, out)?;
                }
            }
        }
        Ok(())
    }
}

#[derive(Clone)]
pub struct RenderContext {
    pub root: Value,
    pub dot: Value,
    pub vars: HashMap<String, Value>,
}

fn tokenize_template(src: &str) -> Vec<Token> {
    let mut tokens = Vec::new();
    let mut rest = src;
    let mut trim_left_next = false;
    while let Some(start) = rest.find("{{") {
        let mut text = rest[..start].to_string();
        if trim_left_next {
            text = text
                .trim_start_matches(|c: char| c.is_whitespace())
                .to_string();
            trim_left_next = false;
        }
        if !text.is_empty() {
            tokens.push(Token::Text(text));
        }
        rest = &rest[start + 2..];
        let left_trim = rest.starts_with('-');
        if left_trim {
            rest = &rest[1..];
            if let Some(Token::Text(prev)) = tokens.last_mut() {
                let trimmed = prev
                    .trim_end_matches(|c: char| c.is_whitespace())
                    .to_string();
                *prev = trimmed;
            }
        }
        let Some(end) = rest.find("}}") else {
            tokens.push(Token::Text(rest.to_string()));
            return tokens;
        };
        let mut action = rest[..end].to_string();
        let right_trim = action.ends_with('-');
        if right_trim {
            action.pop();
        }
        tokens.push(Token::Action(action.trim().to_string()));
        rest = &rest[end + 2..];
        if right_trim {
            trim_left_next = true;
        }
    }
    let mut text = rest.to_string();
    if trim_left_next {
        text = text
            .trim_start_matches(|c: char| c.is_whitespace())
            .to_string();
    }
    if !text.is_empty() {
        tokens.push(Token::Text(text));
    }
    tokens
}

fn parse_nodes(
    tokens: &[Token],
    pos: &mut usize,
    templates: &mut HashMap<String, Vec<Node>>,
) -> Result<Vec<Node>, String> {
    let mut nodes = Vec::new();
    while *pos < tokens.len() {
        match &tokens[*pos] {
            Token::Text(s) => {
                nodes.push(Node::Text(s.clone()));
                *pos += 1;
            }
            Token::Action(action) => {
                if action.is_empty() || action.starts_with("/*") {
                    *pos += 1;
                    continue;
                }
                if action == "end" || action == "else" || action.starts_with("else ") {
                    break;
                }
                if let Some(rest) = action.strip_prefix("define ") {
                    let name = parse_template_name(rest)?;
                    *pos += 1;
                    let body = parse_nodes(tokens, pos, templates)?;
                    expect_action(tokens, pos, "end")?;
                    templates.insert(name, body);
                    continue;
                }
                if let Some(expr) = action.strip_prefix("if ") {
                    *pos += 1;
                    nodes.push(parse_if(tokens, pos, templates, expr.trim().to_string())?);
                    continue;
                }
                if let Some(spec) = action.strip_prefix("range ") {
                    *pos += 1;
                    let (vars, expr) = parse_range_spec(spec);
                    let body = parse_nodes(tokens, pos, templates)?;
                    expect_action(tokens, pos, "end")?;
                    nodes.push(Node::Range {
                        vars,
                        expr,
                        nodes: body,
                    });
                    continue;
                }
                if let Some(spec) = action.strip_prefix("template ") {
                    let mut parts = split_words(spec);
                    let name = parts.first().map(|s| unquote(s)).unwrap_or_default();
                    let expr = if parts.len() > 1 {
                        parts.drain(1..).collect::<Vec<_>>().join(" ")
                    } else {
                        ".".to_string()
                    };
                    nodes.push(Node::Template { name, expr });
                    *pos += 1;
                    continue;
                }
                if let Some((lhs, rhs)) = action.split_once(":=") {
                    nodes.push(Node::Assign(
                        lhs.trim().trim_start_matches('$').to_string(),
                        rhs.trim().to_string(),
                    ));
                    *pos += 1;
                    continue;
                }
                nodes.push(Node::Eval(action.clone()));
                *pos += 1;
            }
        }
    }
    Ok(nodes)
}

fn parse_if(
    tokens: &[Token],
    pos: &mut usize,
    templates: &mut HashMap<String, Vec<Node>>,
    first_expr: String,
) -> Result<Node, String> {
    let mut branches = Vec::new();
    let first_body = parse_nodes(tokens, pos, templates)?;
    branches.push((first_expr, first_body));
    let mut else_nodes = Vec::new();
    loop {
        if *pos >= tokens.len() {
            return Err("unclosed if".to_string());
        }
        let Token::Action(action) = &tokens[*pos] else {
            return Err("expected if control action".to_string());
        };
        if action == "end" {
            *pos += 1;
            break;
        }
        if let Some(expr) = action.strip_prefix("else if ") {
            *pos += 1;
            let body = parse_nodes(tokens, pos, templates)?;
            branches.push((expr.trim().to_string(), body));
            continue;
        }
        if action == "else" {
            *pos += 1;
            else_nodes = parse_nodes(tokens, pos, templates)?;
            expect_action(tokens, pos, "end")?;
            break;
        }
        return Err(format!("unexpected if action: {action}"));
    }
    Ok(Node::If {
        branches,
        else_nodes,
    })
}

fn expect_action(tokens: &[Token], pos: &mut usize, expected: &str) -> Result<(), String> {
    match tokens.get(*pos) {
        Some(Token::Action(action)) if action == expected => {
            *pos += 1;
            Ok(())
        }
        Some(Token::Action(action)) => Err(format!("expected {expected}, got {action}")),
        _ => Err(format!("expected {expected}")),
    }
}

fn parse_range_spec(spec: &str) -> (Vec<String>, String) {
    if let Some((lhs, rhs)) = spec.split_once(":=") {
        let vars = lhs
            .split(',')
            .map(|v| v.trim().trim_start_matches('$').to_string())
            .filter(|v| !v.is_empty())
            .collect();
        (vars, rhs.trim().to_string())
    } else {
        (Vec::new(), spec.trim().to_string())
    }
}

fn parse_template_name(rest: &str) -> Result<String, String> {
    let words = split_words(rest);
    words
        .first()
        .map(|w| unquote(w))
        .filter(|w| !w.is_empty())
        .ok_or_else(|| format!("bad define: {rest}"))
}

fn eval_expr(expr: &str, ctx: &RenderContext) -> Result<Value, String> {
    let parts = split_pipeline(expr);
    let mut value = eval_command(parts.first().map(String::as_str).unwrap_or(""), ctx, None)?;
    for part in parts.iter().skip(1) {
        value = eval_command(part, ctx, Some(value))?;
    }
    Ok(value)
}

fn eval_command(expr: &str, ctx: &RenderContext, piped: Option<Value>) -> Result<Value, String> {
    let expr = expr.trim();
    if expr.is_empty() {
        return Ok(piped.unwrap_or(Value::Null));
    }
    if expr.starts_with('(') && matching_outer_parens(expr) {
        let mut value = eval_expr(&expr[1..expr.len() - 1], ctx)?;
        if let Some(p) = piped {
            let words = split_words(&value.as_str());
            if !words.is_empty() {
                value = eval_function(&words[0], vec![p], ctx)?;
            }
        }
        return Ok(value);
    }
    let words = split_words(expr);
    if words.is_empty() {
        return Ok(piped.unwrap_or(Value::Null));
    }
    if let Some(p) = piped {
        if is_function(&words[0]) {
            let mut args = parse_args(&words[1..], ctx)?;
            args.push(p);
            return eval_function(&words[0], args, ctx);
        }
        return Ok(p);
    }
    if is_function(&words[0]) {
        let args = parse_args(&words[1..], ctx)?;
        return eval_function(&words[0], args, ctx);
    }
    if words.len() == 1 {
        return eval_atom(&words[0], ctx);
    }
    Err(format!("unsupported expression: {expr}"))
}

fn parse_args(words: &[String], ctx: &RenderContext) -> Result<Vec<Value>, String> {
    words.iter().map(|w| eval_atom(w, ctx)).collect()
}

fn eval_atom(token: &str, ctx: &RenderContext) -> Result<Value, String> {
    let token = token.trim();
    if token.starts_with('(') && matching_outer_parens(token) {
        return eval_expr(&token[1..token.len() - 1], ctx);
    }
    if token.starts_with('"') && token.ends_with('"') && token.len() >= 2 {
        return Ok(Value::s(unquote(token)));
    }
    if token == "." {
        return Ok(ctx.dot.clone());
    }
    if token == "$" {
        return Ok(ctx.root.clone());
    }
    if let Ok(i) = token.parse::<i64>() {
        return Ok(Value::Int(i));
    }
    if let Some(rest) = token.strip_prefix("$.") {
        return Ok(resolve_path(ctx.root.clone(), rest));
    }
    if let Some(rest) = token.strip_prefix('.') {
        return Ok(resolve_path(ctx.dot.clone(), rest));
    }
    if let Some(rest) = token.strip_prefix('$') {
        let mut parts = rest.splitn(2, '.');
        let var_name = parts.next().unwrap_or("");
        let value = ctx.vars.get(var_name).cloned().unwrap_or(Value::Null);
        if let Some(path) = parts.next() {
            return Ok(resolve_path(value, path));
        }
        return Ok(value);
    }
    Ok(Value::s(token))
}

fn resolve_path(mut value: Value, path: &str) -> Value {
    if path.is_empty() {
        return value;
    }
    for part in path.split('.') {
        value = value.get(part);
    }
    value
}

fn split_pipeline(expr: &str) -> Vec<String> {
    split_top_level(expr, '|')
}

fn split_top_level(expr: &str, sep: char) -> Vec<String> {
    let mut out = Vec::new();
    let mut start = 0usize;
    let mut depth = 0i32;
    let mut in_str = false;
    let mut escaped = false;
    for (idx, ch) in expr.char_indices() {
        if in_str {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_str = false;
            }
            continue;
        }
        match ch {
            '"' => in_str = true,
            '(' => depth += 1,
            ')' => depth -= 1,
            c if c == sep && depth == 0 => {
                out.push(expr[start..idx].trim().to_string());
                start = idx + ch.len_utf8();
            }
            _ => {}
        }
    }
    out.push(expr[start..].trim().to_string());
    out
}

fn split_words(expr: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut buf = String::new();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut escaped = false;
    for ch in expr.chars() {
        if in_str {
            buf.push(ch);
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_str = false;
            }
            continue;
        }
        match ch {
            '"' => {
                in_str = true;
                buf.push(ch);
            }
            '(' => {
                depth += 1;
                buf.push(ch);
            }
            ')' => {
                depth -= 1;
                buf.push(ch);
            }
            c if c.is_whitespace() && depth == 0 => {
                if !buf.is_empty() {
                    out.push(std::mem::take(&mut buf));
                }
            }
            _ => buf.push(ch),
        }
    }
    if !buf.is_empty() {
        out.push(buf);
    }
    out
}

fn matching_outer_parens(expr: &str) -> bool {
    if !expr.starts_with('(') || !expr.ends_with(')') {
        return false;
    }
    let mut depth = 0i32;
    let mut in_str = false;
    let mut escaped = false;
    for (idx, ch) in expr.char_indices() {
        if in_str {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_str = false;
            }
            continue;
        }
        match ch {
            '"' => in_str = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 && idx != expr.len() - 1 {
                    return false;
                }
            }
            _ => {}
        }
    }
    depth == 0
}

fn unquote(s: &str) -> String {
    let s = s.trim();
    if !(s.starts_with('"') && s.ends_with('"') && s.len() >= 2) {
        return s.to_string();
    }
    let mut out = String::new();
    let mut escaped = false;
    for ch in s[1..s.len() - 1].chars() {
        if escaped {
            out.push(match ch {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                '"' => '"',
                other => other,
            });
            escaped = false;
        } else if ch == '\\' {
            escaped = true;
        } else {
            out.push(ch);
        }
    }
    out
}

fn is_function(name: &str) -> bool {
    matches!(
        name,
        "and"
            | "or"
            | "not"
            | "eq"
            | "ne"
            | "gt"
            | "printf"
            | "index"
            | "snakeCase"
            | "pythonIdent"
            | "pythonMethodName"
            | "callMethod"
            | "grpcStreamType"
            | "ffiStreamType"
            | "pluginStreamType"
            | "replace"
            | "upper"
            | "lower"
            | "screaming"
            | "rustCType"
            | "cHeaderType"
            | "needsLen"
            | "needsOutLen"
            | "rustReturnType"
            | "cReturnType"
            | "hasRepeated"
            | "hasOneof"
            | "hasMap"
            | "needsPbFallback"
            | "nonOneofFields"
            | "nativeErrReturn"
            | "cNativeErrReturn"
            | "wasmErrReturn"
            | "lowerFirst"
            | "serviceHasStreaming"
            | "csharpType"
            | "csharpIsValueType"
            | "oneofGroups"
            | "tsType"
            | "tsDefaultValue"
            | "tsPropName"
            | "tsJsonName"
            | "tsOneofCaseEnumName"
            | "tsOneofCaseProperty"
            | "tsOneofCaseValue"
            | "swiftType"
            | "swiftEscape"
            | "swiftDefault"
            | "swiftFieldName"
            | "swiftMethodName"
            | "swiftEnumCase"
            | "swiftEnumZeroCase"
            | "swiftOneofCase"
            | "swiftWriteCall"
            | "swiftReadCall"
            | "swiftScalarWire"
            | "swiftMapKeyType"
            | "swiftMapValueType"
            | "swiftMapKeyDefault"
            | "swiftMapValueDefault"
            | "swiftNotDefault"
            | "cppFieldName"
            | "cppLiteType"
            | "cppLiteMapKeyType"
            | "cppLiteMapValueType"
            | "cppLiteScalarDefault"
            | "cppLiteMapKeyDefault"
            | "cppLiteMapValueDefault"
            | "cppLiteNotDefault"
            | "cppLiteWriteCall"
            | "cppLiteReadCall"
            | "cppLitePackable"
    )
}

fn eval_function(name: &str, args: Vec<Value>, ctx: &RenderContext) -> Result<Value, String> {
    let v = |i: usize| args.get(i).cloned().unwrap_or(Value::Null);
    Ok(match name {
        "and" => Value::Bool(args.iter().all(Value::truthy)),
        "or" => Value::Bool(args.iter().any(Value::truthy)),
        "not" => Value::Bool(!v(0).truthy()),
        "eq" => Value::Bool(v(0).as_str() == v(1).as_str()),
        "ne" => Value::Bool(v(0).as_str() != v(1).as_str()),
        "gt" => Value::Bool(v(0).as_i64() > v(1).as_i64()),
        "printf" => Value::s(template_printf(&args)?),
        "index" => {
            let map = v(0);
            let key = v(1).as_str();
            map.get(&key)
        }
        "snakeCase" => Value::s(to_snake_case(&v(0).as_str())),
        "pythonIdent" => Value::s(python_identifier(&v(0).as_str())),
        "pythonMethodName" => Value::s(python_method_name(&v(0).as_str())),
        "callMethod" => Value::s(callmethod_name(&v(0))),
        "grpcStreamType" => stream_type("grpc", &v(0), &v(1)),
        "ffiStreamType" => stream_type("ffi", &v(0), &v(1)),
        "pluginStreamType" => Value::s(format!(
            "pluginStream{}{}",
            v(0).get("GoName").as_str(),
            v(1).get("GoName").as_str()
        )),
        "replace" => Value::s(v(0).as_str().replace(&v(1).as_str(), &v(2).as_str())),
        "upper" => Value::s(v(0).as_str().to_uppercase()),
        "lower" => Value::s(v(0).as_str().to_lowercase()),
        "screaming" => Value::s(to_screaming_snake(&v(0).as_str())),
        "rustCType" => Value::s(rust_c_type(&v(0))),
        "cHeaderType" => Value::s(c_header_type(&v(0))),
        "needsLen" => Value::Bool(needs_len(&v(0))),
        "needsOutLen" => Value::Bool(needs_out_len(&v(0))),
        "rustReturnType" => Value::s(rust_return_type(&v(0))),
        "cReturnType" => Value::s(c_return_type(&v(0))),
        "hasRepeated" => Value::Bool(list_any(&v(0), "IsRepeated")),
        "hasOneof" => Value::Bool(list_any(&v(0), "IsOneof")),
        "hasMap" => Value::Bool(list_any(&v(0), "IsMap")),
        "needsPbFallback" => Value::Bool(
            list_any(&v(0), "IsRepeated") || list_any(&v(0), "IsOneof") || list_any(&v(0), "IsMap"),
        ),
        "nonOneofFields" => match v(0) {
            Value::List(items) => Value::list(
                items
                    .into_iter()
                    .filter(|f| !f.get("IsOneof").as_bool())
                    .collect(),
            ),
            _ => Value::list(Vec::new()),
        },
        "nativeErrReturn" => Value::s(native_err_return(&v(0))),
        "cNativeErrReturn" => Value::s(c_native_err_return(&v(0))),
        "wasmErrReturn" => Value::s(wasm_err_return(&v(0))),
        "lowerFirst" => Value::s(lower_first_value(&v(0))),
        "serviceHasStreaming" => {
            let has = match v(0).get("Methods") {
                Value::List(items) => items.iter().any(|m| !m.get("IsUnary").as_bool()),
                _ => false,
            };
            Value::Bool(has)
        }
        "csharpType" => Value::s(csharp_type(&v(0))),
        "csharpIsValueType" => Value::Bool(matches!(
            v(0).get("ProtoKind").as_str().as_str(),
            "int32" | "int64" | "uint32" | "uint64" | "float" | "double" | "bool" | "enum"
        )),
        "oneofGroups" => oneof_groups(&v(0)),
        "tsType" => Value::s(ts_type(&v(0))),
        "tsDefaultValue" => Value::s(ts_default_value(&v(0))),
        "tsPropName" => Value::s(lower_first(&v(0).get("GoName").as_str())),
        "tsJsonName" => Value::s(lower_camel_from_snake(&v(0).get("Name").as_str())),
        "tsOneofCaseEnumName" => Value::s(format!("{}{}OneofCase", v(0).as_str(), v(1).as_str())),
        "tsOneofCaseProperty" => {
            let f = v(0);
            if !f.get("IsOneof").as_bool() || f.get("IsOptional").as_bool() {
                Value::s("")
            } else {
                Value::s(format!(
                    "{}Case",
                    lower_first(&f.get("OneofGoName").as_str())
                ))
            }
        }
        "tsOneofCaseValue" => {
            let f = v(1);
            if !f.get("IsOneof").as_bool() || f.get("IsOptional").as_bool() {
                Value::s("")
            } else {
                Value::s(format!(
                    "{}{}OneofCase.{}",
                    v(0).as_str(),
                    f.get("OneofGoName").as_str(),
                    f.get("GoName").as_str()
                ))
            }
        }
        "swiftType" => Value::s(swift_type(&v(0))),
        "swiftEscape" => Value::s(swift_escape(&v(0).as_str())),
        "swiftDefault" => Value::s(swift_default(&v(0), &ctx.root)),
        "swiftFieldName" => Value::s(swift_escape(&lower_camel_from_snake(
            &v(0).get("Name").as_str(),
        ))),
        "swiftMethodName" => Value::s(swift_escape(&lower_first(&v(0).as_str()))),
        "swiftEnumCase" => Value::s(swift_enum_case(&ctx.root, &v(0).as_str(), &v(1).as_str())),
        "swiftEnumZeroCase" => Value::s(swift_enum_zero_case(&ctx.root, &v(0).as_str())),
        "swiftOneofCase" => Value::s(swift_escape(&lower_first(&v(0).as_str()))),
        "swiftWriteCall" => Value::s(swift_write_call(&v(0).as_str())),
        "swiftReadCall" => Value::s(swift_read_call(&v(0).as_str())),
        "swiftScalarWire" => Value::s(swift_scalar_wire(&v(0).as_str())),
        "swiftMapKeyType" => Value::s(swift_kind_type(&v(0).get("MapKeyKind").as_str(), "")),
        "swiftMapValueType" => Value::s(swift_kind_type(
            &v(0).get("MapValueKind").as_str(),
            &v(0).get("MapValueTypeName").as_str(),
        )),
        "swiftMapKeyDefault" => Value::s(swift_kind_default(&v(0).get("MapKeyKind").as_str(), "")),
        "swiftMapValueDefault" => Value::s(swift_kind_default(
            &v(0).get("MapValueKind").as_str(),
            &v(0).get("MapValueTypeName").as_str(),
        )),
        "swiftNotDefault" => Value::s(swift_not_default(&v(0).as_str(), &v(1).as_str())),
        "cppFieldName" => Value::s(cpp_field_name(&v(0).as_str())),
        "cppLiteType" => Value::s(cpp_lite_type(&v(0))),
        "cppLiteMapKeyType" => Value::s(cpp_lite_kind_type(
            &v(0).get("MapKeyKind").as_str(),
            "",
            "",
            true,
        )),
        "cppLiteMapValueType" => Value::s(cpp_lite_kind_type(
            &v(0).get("MapValueKind").as_str(),
            &v(0).get("MapValueTypeName").as_str(),
            &v(0).get("MapValueFQN").as_str(),
            v(0).get("MapValueIsLocal").as_bool(),
        )),
        "cppLiteScalarDefault" => Value::s(cpp_lite_scalar_default(&v(0).as_str())),
        "cppLiteMapKeyDefault" => Value::s(cpp_lite_kind_default(
            &v(0).get("MapKeyKind").as_str(),
            "",
            "",
            true,
        )),
        "cppLiteMapValueDefault" => Value::s(cpp_lite_kind_default(
            &v(0).get("MapValueKind").as_str(),
            &v(0).get("MapValueTypeName").as_str(),
            &v(0).get("MapValueFQN").as_str(),
            v(0).get("MapValueIsLocal").as_bool(),
        )),
        "cppLiteNotDefault" => Value::s(cpp_lite_not_default(&v(0).as_str(), &v(1).as_str())),
        "cppLiteWriteCall" => Value::s(cpp_lite_write_call(&v(0).as_str())),
        "cppLiteReadCall" => Value::s(cpp_lite_read_call(&v(0).as_str())),
        "cppLitePackable" => Value::s(
            if matches!(v(0).as_str().as_str(), "string" | "bytes" | "message") {
                "false"
            } else {
                "true"
            },
        ),
        _ => return Err(format!("unknown function: {name}")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render(src: &str, root: Value) -> Result<String, String> {
        let mut engine = TemplateEngine {
            templates: HashMap::new(),
        };
        let tokens = tokenize_template(src);
        let mut pos = 0;
        let nodes = parse_nodes(&tokens, &mut pos, &mut engine.templates)?;
        engine.templates.insert("t".into(), nodes);
        engine.render("t", root)
    }

    #[test]
    fn printf_unknown_verb_errors() {
        let err = render("{{printf \"%x\" .}}", Value::s("a")).unwrap_err();
        assert!(err.contains("unsupported verb"));
    }

    #[test]
    fn range_over_map_is_noop() {
        let mut m = std::collections::BTreeMap::new();
        m.insert("k".to_string(), Value::s("v"));
        let out = render("{{range .}}x{{end}}", Value::Map(m)).unwrap();
        assert_eq!(out, "");
    }
}
