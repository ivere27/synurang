//! Post-processing passes applied to generated Go files so the byte output
//! matches canonical `gofmt` output.

pub fn final_content(filename: &str, content: String) -> String {
    if filename.ends_with(".go") {
        let content = format_go_generated(&content);
        format!("{}\n", content.trim_end_matches('\n'))
    } else {
        format!("{content}\n")
    }
}

fn format_go_generated(content: &str) -> String {
    let mut lines: Vec<String> = content.lines().map(ToOwned::to_owned).collect();
    lines = format_go_comment_examples(&lines);
    lines = align_go_decl_blocks(&lines);
    collapse_blank_lines(&lines)
}

fn format_go_comment_examples(lines: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut in_purego_example = false;
    for line in lines {
        if line.starts_with("// Example with purego:") {
            in_purego_example = true;
            out.push(line.clone());
        } else if in_purego_example && line.starts_with("//   ") {
            if matches!(out.last(), Some(prev) if prev.starts_with("// Example with purego:")) {
                out.push("//".to_string());
            }
            out.push(format!("//\t{}", &line[5..]));
        } else {
            if in_purego_example && !line.trim().is_empty() && !line.starts_with("//") {
                in_purego_example = false;
            }
            out.push(line.clone());
        }
    }
    out
}

fn align_go_decl_blocks(lines: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < lines.len() {
        let line = &lines[i];
        out.push(line.clone());
        if line.trim_end().ends_with("struct {") {
            let mut block = Vec::new();
            i += 1;
            while i < lines.len() {
                if lines[i].trim() == "}" {
                    out.extend(align_go_simple_decl_lines(&block));
                    out.push(lines[i].clone());
                    break;
                }
                block.push(lines[i].clone());
                i += 1;
            }
        } else if line.trim() == "var (" || line.trim() == "const (" || line.trim() == "type (" {
            let mut block = Vec::new();
            i += 1;
            while i < lines.len() {
                if lines[i].trim() == ")" {
                    out.extend(align_go_simple_decl_lines(&block));
                    out.push(lines[i].clone());
                    break;
                }
                block.push(lines[i].clone());
                i += 1;
            }
        }
        i += 1;
    }
    out
}

fn align_go_simple_decl_lines(lines: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    let mut group: Vec<String> = Vec::new();

    fn flush(group: &mut Vec<String>, out: &mut Vec<String>) {
        if group.is_empty() {
            return;
        }
        let parsed: Vec<(String, String, String)> = group
            .iter()
            .filter_map(|line| parse_go_decl_line(line))
            .collect();
        if parsed.len() != group.len() {
            out.append(group);
            return;
        }
        let max_name = parsed
            .iter()
            .map(|(_, name, _)| name.len())
            .max()
            .unwrap_or(0);
        for (indent, name, rest) in parsed {
            let spaces = " ".repeat(max_name.saturating_sub(name.len()) + 1);
            out.push(format!("{indent}{name}{spaces}{rest}"));
        }
        group.clear();
    }

    for line in lines {
        if parse_go_decl_line(line).is_some() {
            group.push(line.clone());
        } else {
            flush(&mut group, &mut out);
            out.push(line.clone());
        }
    }
    flush(&mut group, &mut out);
    out
}

fn parse_go_decl_line(line: &str) -> Option<(String, String, String)> {
    let indent_len = line.len() - line.trim_start_matches(['\t', ' ']).len();
    let indent = line[..indent_len].to_string();
    let rest = &line[indent_len..];
    if rest.is_empty()
        || rest.starts_with("//")
        || rest.contains(":=")
        || rest.contains('=')
        || rest.starts_with("case ")
        || rest.starts_with("default:")
    {
        return None;
    }
    let mut split = rest.splitn(2, char::is_whitespace);
    let name = split.next()?.to_string();
    if name.is_empty()
        || !name
            .chars()
            .next()
            .map(|c| c == '_' || c.is_ascii_alphabetic())
            .unwrap_or(false)
    {
        return None;
    }
    let tail = split.next()?.trim_start().to_string();
    if tail.is_empty() || tail.starts_with('{') || tail.starts_with('}') {
        return None;
    }
    Some((indent, name, tail))
}

fn collapse_blank_lines(lines: &[String]) -> String {
    let mut out = Vec::new();
    let mut blank = 0usize;
    for line in lines {
        if line.trim().is_empty() {
            blank += 1;
            if blank <= 1 {
                out.push(String::new());
            }
        } else {
            blank = 0;
            out.push(line.clone());
        }
    }
    out.join("\n")
}
