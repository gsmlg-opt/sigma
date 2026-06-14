use serde::Serialize;
use std::collections::BTreeMap;
use std::hash::Hasher;
use twox_hash::XxHash32;

#[derive(Clone, Debug)]
enum Cursor {
    Before(usize),
    After(usize),
    Head,
    Tail,
}

#[derive(Clone, Debug)]
enum Edit {
    Replace {
        start: usize,
        end: usize,
        body: Vec<String>,
    },
    Delete {
        start: usize,
        end: usize,
    },
    Insert {
        cursor: Cursor,
        body: Vec<String>,
    },
}

#[derive(Clone, Debug)]
enum LineOp {
    Delete,
    Replacement(Vec<String>),
    InsertBefore(Vec<String>),
    InsertAfter(Vec<String>),
}

#[derive(Clone, Debug)]
struct IndexedLineOp {
    index: usize,
    op: LineOp,
}

#[derive(Debug)]
struct ParsedPatch {
    edits: Vec<Edit>,
    warnings: Vec<String>,
}

#[derive(Serialize)]
struct Response<T: Serialize> {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    value: Option<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[derive(Serialize)]
struct Section {
    path: String,
    file_hash: String,
    diff: String,
}

#[derive(Serialize)]
struct ApplyResult {
    text: String,
    first_changed_line: Option<usize>,
    warnings: Vec<String>,
}

#[rustler::nif]
fn compute_file_hash(text: String) -> String {
    compute_hash(&text)
}

#[rustler::nif]
fn parse_sections_json(input: String, cwd: Option<String>) -> String {
    encode(parse_sections(&input, cwd.as_deref()))
}

#[rustler::nif]
fn apply_edits_json(text: String, diff: String) -> String {
    let result = parse_patch(&diff).and_then(|patch| apply_edits(&text, &patch));
    encode(result)
}

fn encode<T: Serialize>(result: Result<T, String>) -> String {
    let response = match result {
        Ok(value) => Response {
            ok: true,
            value: Some(value),
            error: None,
        },
        Err(error) => Response::<T> {
            ok: false,
            value: None,
            error: Some(error),
        },
    };

    serde_json::to_string(&response).unwrap_or_else(|err| {
        format!(
            r#"{{"ok":false,"error":"could not encode hashline response: {}"}}"#,
            err
        )
    })
}

fn compute_hash(text: &str) -> String {
    let normalized = trim_hash_text(text);
    let mut hasher = XxHash32::with_seed(0);
    hasher.write(normalized.as_bytes());
    let low16 = (hasher.finish() as u32) & 0xffff;
    format!("{:04X}", low16)
}

fn trim_hash_text(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut pending_ws = String::new();

    for ch in text.chars() {
        match ch {
            ' ' | '\t' | '\r' => pending_ws.push(ch),
            '\n' => {
                pending_ws.clear();
                out.push('\n');
            }
            _ => {
                out.push_str(&pending_ws);
                pending_ws.clear();
                out.push(ch);
            }
        }
    }

    out
}

fn parse_sections(input: &str, cwd: Option<&str>) -> Result<Vec<Section>, String> {
    let normalized = input.strip_prefix('\u{FEFF}').unwrap_or(input);
    let mut lines: Vec<&str> = normalized.lines().collect();

    while matches!(
        lines.first().map(|line| line.trim()),
        Some("") | Some("*** Begin Patch")
    ) {
        lines.remove(0);
    }

    if lines.is_empty() {
        return Err(
            "input must begin with \"[PATH#HASH]\" on the first non-blank line for anchored edits"
                .to_string(),
        );
    }

    let mut sections: Vec<Section> = Vec::new();
    let mut current: Option<(String, String, Vec<String>)> = None;

    for raw_line in lines {
        let line = raw_line.trim_end_matches('\r');
        let trimmed = line.trim_end();

        if trimmed == "*** End Patch" || trimmed == "*** Abort" {
            break;
        }
        if trimmed == "*** Begin Patch" {
            continue;
        }

        if trimmed.starts_with('[') {
            let header = parse_header(trimmed, cwd)?;
            if let Some((path, file_hash, diff_lines)) = current.take() {
                if diff_lines.iter().any(|line| !line.trim().is_empty()) {
                    sections.push(Section {
                        path,
                        file_hash,
                        diff: diff_lines.join("\n"),
                    });
                }
            }
            current = Some((header.0, header.1, Vec::new()));
            continue;
        }

        if let Some((_path, _file_hash, diff_lines)) = current.as_mut() {
            diff_lines.push(line.to_string());
        } else {
            return Err(format!(
                "input must begin with \"[PATH#HASH]\" on the first non-blank line for anchored edits; got: {:?}",
                line
            ));
        }
    }

    if let Some((path, file_hash, diff_lines)) = current.take() {
        if diff_lines.iter().any(|line| !line.trim().is_empty()) {
            sections.push(Section {
                path,
                file_hash,
                diff: diff_lines.join("\n"),
            });
        }
    }

    if sections.is_empty() {
        return Err("No hashline sections found in input.".to_string());
    }

    merge_sections(sections)
}

fn parse_header(line: &str, cwd: Option<&str>) -> Result<(String, String), String> {
    if !line.ends_with(']') {
        return Err(header_error(line));
    }

    let body = &line[1..line.len() - 1];
    let Some((path, hash)) = body.rsplit_once('#') else {
        return Err(header_error(line));
    };

    if path.trim().is_empty() || hash.len() != 4 || !hash.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return Err(header_error(line));
    }

    Ok((
        normalize_header_path(path.trim(), cwd),
        hash.to_ascii_uppercase(),
    ))
}

fn header_error(line: &str) -> String {
    format!(
        "Input header must be [PATH] or [PATH#TAG] with a 4-hex content-hash tag; got {:?}.",
        line
    )
}

fn normalize_header_path(path: &str, cwd: Option<&str>) -> String {
    if let Some(cwd) = cwd {
        if path.starts_with('/') {
            let cwd = cwd.trim_end_matches('/');
            let prefix = format!("{}/", cwd);
            if path == cwd {
                return ".".to_string();
            }
            if let Some(stripped) = path.strip_prefix(&prefix) {
                return stripped.to_string();
            }
        }
    }
    path.to_string()
}

fn merge_sections(sections: Vec<Section>) -> Result<Vec<Section>, String> {
    let mut merged: Vec<Section> = Vec::new();

    for section in sections {
        if let Some(existing) = merged.iter_mut().find(|entry| entry.path == section.path) {
            if existing.file_hash != section.file_hash {
                return Err(format!(
                    "Conflicting hashline snapshot tags for {}: #{} and #{}. Re-read the file and retry with one current header.",
                    section.path, existing.file_hash, section.file_hash
                ));
            }
            if !existing.diff.is_empty() {
                existing.diff.push('\n');
            }
            existing.diff.push_str(&section.diff);
        } else {
            merged.push(section);
        }
    }

    Ok(merged)
}

fn parse_patch(diff: &str) -> Result<ParsedPatch, String> {
    let lines: Vec<String> = diff
        .lines()
        .map(|line| line.trim_end_matches('\r').to_string())
        .collect();
    let mut edits = Vec::new();
    let mut warnings = Vec::new();
    let mut index = 0;

    while index < lines.len() {
        let line = lines[index].trim_end();
        if line.trim().is_empty() {
            index += 1;
            continue;
        }

        if line.trim_start().starts_with("@@") {
            return Err(
                "unified-diff hunk header (`@@ -N,M +N,M @@` or `@@@ ... @@@`) is not valid in hashline. Use `replace N..M:`, `delete N..M`, or `insert before|after|head|tail:`."
                    .to_string(),
            );
        }
        if line.starts_with("*** ") {
            return Err(
                "apply_patch sentinel lines are not valid inside hashline sections".to_string(),
            );
        }

        let Some(op) = parse_op(line)? else {
            return Err(
                "hunk headers need a verb: use `replace`, `delete`, or `insert`.".to_string(),
            );
        };
        index += 1;

        match op {
            PendingOp::Delete { start, end } => {
                if index < lines.len()
                    && !lines[index].trim().is_empty()
                    && !looks_like_op(&lines[index])
                {
                    return Err("`delete N..M` does not take body rows. Remove the body, or use `replace N..M:`.".to_string());
                }
                edits.push(Edit::Delete { start, end });
            }
            PendingOp::Replace { start, end } => {
                let (body, consumed, body_warnings) = collect_body(&lines[index..])?;
                warnings.extend(body_warnings);
                index += consumed;
                if body.is_empty() {
                    edits.push(Edit::Delete { start, end });
                } else {
                    edits.push(Edit::Replace { start, end, body });
                }
            }
            PendingOp::Insert { cursor } => {
                let (body, consumed, body_warnings) = collect_body(&lines[index..])?;
                warnings.extend(body_warnings);
                index += consumed;
                if body.is_empty() {
                    return Err("`insert` needs at least one `+TEXT` body row.".to_string());
                }
                edits.push(Edit::Insert { cursor, body });
            }
        }
    }

    Ok(ParsedPatch { edits, warnings })
}

enum PendingOp {
    Replace { start: usize, end: usize },
    Delete { start: usize, end: usize },
    Insert { cursor: Cursor },
}

fn parse_op(line: &str) -> Result<Option<PendingOp>, String> {
    let trimmed = line.trim();
    let no_colon = trimmed.strip_suffix(':').unwrap_or(trimmed).trim();
    let parts: Vec<&str> = no_colon.split_whitespace().collect();

    if parts.is_empty() {
        return Ok(None);
    }

    match parts[0] {
        "replace" => {
            if parts.get(1) == Some(&"block") {
                return Err("`replace block` is not available yet; use an explicit `replace N..M:` range.".to_string());
            }
            let range_text = parts[1..].join(" ");
            let (start, end) = parse_range(&range_text)?;
            Ok(Some(PendingOp::Replace { start, end }))
        }
        "delete" => {
            if trimmed.ends_with(':') {
                return Err("`delete N..M` has no colon and does not take body rows.".to_string());
            }
            if parts.get(1) == Some(&"block") {
                return Err("`delete block` is not available yet; use an explicit `delete N..M` range.".to_string());
            }
            let range_text = parts[1..].join(" ");
            let (start, end) = parse_range(&range_text)?;
            Ok(Some(PendingOp::Delete { start, end }))
        }
        "insert" => match parts.as_slice() {
            ["insert", "head"] => Ok(Some(PendingOp::Insert { cursor: Cursor::Head })),
            ["insert", "tail"] => Ok(Some(PendingOp::Insert { cursor: Cursor::Tail })),
            ["insert", "before", line] => Ok(Some(PendingOp::Insert {
                cursor: Cursor::Before(parse_line_number(line)?),
            })),
            ["insert", "after", line] => Ok(Some(PendingOp::Insert {
                cursor: Cursor::After(parse_line_number(line)?),
            })),
            ["insert", "after", "block", _line] => Err(
                "`insert after block` is not available yet; use an explicit `insert after N:` anchor.".to_string(),
            ),
            _ => Err("Invalid insert header. Use `insert before N:`, `insert after N:`, `insert head:`, or `insert tail:`.".to_string()),
        },
        _ if parts[0].chars().all(|ch| ch.is_ascii_digit()) => {
            Err("hunk headers need a verb: use `replace`, `delete`, or `insert`.".to_string())
        }
        _ => Ok(None),
    }
}

fn looks_like_op(line: &str) -> bool {
    parse_op(line).map(|op| op.is_some()).unwrap_or(false)
}

fn parse_range(text: &str) -> Result<(usize, usize), String> {
    let normalized = text.replace('…', "..").replace('-', "..");
    let pieces: Vec<&str> = if normalized.contains("..") {
        normalized.split("..").collect()
    } else {
        normalized.split_whitespace().collect()
    };

    match pieces.as_slice() {
        [single] => {
            let line = parse_line_number(single)?;
            Ok((line, line))
        }
        [start, end] => {
            let start = parse_line_number(start)?;
            let end = parse_line_number(end)?;
            if end < start {
                Err(format!(
                    "Invalid range {}..{}: end must be >= start.",
                    start, end
                ))
            } else {
                Ok((start, end))
            }
        }
        _ => Err("Invalid range. Use `N` or `N..M`.".to_string()),
    }
}

fn parse_line_number(text: &str) -> Result<usize, String> {
    let line = text.trim().parse::<usize>().map_err(|_| {
        format!(
            "Invalid line reference. Expected a bare line number; received {:?}.",
            text
        )
    })?;
    if line == 0 {
        Err("Line number must be >= 1.".to_string())
    } else {
        Ok(line)
    }
}

fn collect_body(lines: &[String]) -> Result<(Vec<String>, usize, Vec<String>), String> {
    let mut consumed = 0;
    let mut rows: Vec<BodyRow> = Vec::new();

    while consumed < lines.len() {
        let line = &lines[consumed];
        if line.trim().is_empty() {
            rows.push(BodyRow::Blank);
            consumed += 1;
            continue;
        }
        if looks_like_op(line) || line.trim_end() == "*** End Patch" {
            break;
        }
        if let Some(rest) = line.strip_prefix('+') {
            rows.push(BodyRow::Literal(rest.to_string()));
        } else if line.starts_with('-') {
            return Err("`-` rows are not valid; the range already names the lines being changed. For a literal `-` line, write `+-...`.".to_string());
        } else {
            rows.push(BodyRow::Bare(line.to_string()));
        }
        consumed += 1;
    }

    while matches!(rows.last(), Some(BodyRow::Blank)) {
        rows.pop();
    }

    let has_bare = rows.iter().any(|row| matches!(row, BodyRow::Bare(_)));
    let strip_number_prefix = should_strip_number_prefix(&rows);
    let mut body = Vec::new();

    for row in rows {
        match row {
            BodyRow::Blank => body.push(String::new()),
            BodyRow::Literal(text) => body.push(text),
            BodyRow::Bare(text) if strip_number_prefix => body.push(strip_one_number_prefix(&text)),
            BodyRow::Bare(text) => body.push(text),
        }
    }

    let warnings = if has_bare {
        vec![
            "Auto-prefixed bare body row(s) with `+`. Body rows must be `+TEXT` literal lines."
                .to_string(),
        ]
    } else {
        Vec::new()
    };

    Ok((body, consumed, warnings))
}

enum BodyRow {
    Blank,
    Literal(String),
    Bare(String),
}

fn should_strip_number_prefix(rows: &[BodyRow]) -> bool {
    let bare_rows: Vec<&str> = rows
        .iter()
        .filter_map(|row| match row {
            BodyRow::Bare(text) if !text.trim().is_empty() => Some(text.as_str()),
            _ => None,
        })
        .collect();

    !bare_rows.is_empty()
        && bare_rows
            .iter()
            .all(|row| split_number_prefix(row).is_some())
}

fn strip_one_number_prefix(text: &str) -> String {
    split_number_prefix(text)
        .map(|(_number, rest)| rest.to_string())
        .unwrap_or_else(|| text.to_string())
}

fn split_number_prefix(text: &str) -> Option<(&str, &str)> {
    let (number, rest) = text.split_once(':')?;
    if number.chars().all(|ch| ch.is_ascii_digit()) && !number.is_empty() {
        Some((number, rest))
    } else {
        None
    }
}

fn apply_edits(text: &str, patch: &ParsedPatch) -> Result<ApplyResult, String> {
    let before_lines = split_lines(text);
    let mut lines = before_lines.clone();
    let (head_inserts, tail_inserts, buckets) = plan_line_edits(&before_lines, &patch.edits)?;

    apply_anchor_buckets(&mut lines, buckets);
    insert_at_start(&mut lines, &head_inserts);
    insert_at_end(&mut lines, &tail_inserts);

    let after = lines.join("\n");
    Ok(ApplyResult {
        first_changed_line: first_changed_line(&before_lines, &lines),
        text: after,
        warnings: patch.warnings.clone(),
    })
}

fn plan_line_edits(
    lines: &[String],
    edits: &[Edit],
) -> Result<
    (
        Vec<String>,
        Vec<String>,
        BTreeMap<usize, Vec<IndexedLineOp>>,
    ),
    String,
> {
    let mut head_inserts = Vec::new();
    let mut tail_inserts = Vec::new();
    let mut buckets: BTreeMap<usize, Vec<IndexedLineOp>> = BTreeMap::new();
    let real = real_line_count(lines);

    for (index, edit) in edits.iter().enumerate() {
        match edit {
            Edit::Delete { start, end } => {
                validate_line(*start, lines)?;
                validate_line(*end, lines)?;

                if *start <= real {
                    for line in *start..=(*end).min(real) {
                        push_line_op(&mut buckets, line, index, LineOp::Delete);
                    }
                }
            }
            Edit::Replace { start, end, body } => {
                validate_line(*start, lines)?;
                validate_line(*end, lines)?;

                if *start <= real {
                    push_line_op(
                        &mut buckets,
                        *start,
                        index,
                        LineOp::Replacement(body.to_vec()),
                    );

                    for line in *start..=(*end).min(real) {
                        push_line_op(&mut buckets, line, index, LineOp::Delete);
                    }
                }
            }
            Edit::Insert { cursor, body } => match cursor {
                Cursor::Head => head_inserts.extend(body.iter().cloned()),
                Cursor::Tail => tail_inserts.extend(body.iter().cloned()),
                Cursor::Before(line) => {
                    validate_line(*line, lines)?;
                    push_line_op(
                        &mut buckets,
                        *line,
                        index,
                        LineOp::InsertBefore(body.to_vec()),
                    );
                }
                Cursor::After(line) => {
                    validate_line(*line, lines)?;
                    push_line_op(
                        &mut buckets,
                        *line,
                        index,
                        LineOp::InsertAfter(body.to_vec()),
                    );
                }
            },
        }
    }

    Ok((head_inserts, tail_inserts, buckets))
}

fn push_line_op(
    buckets: &mut BTreeMap<usize, Vec<IndexedLineOp>>,
    line: usize,
    index: usize,
    op: LineOp,
) {
    buckets
        .entry(line)
        .or_default()
        .push(IndexedLineOp { index, op });
}

fn apply_anchor_buckets(lines: &mut Vec<String>, buckets: BTreeMap<usize, Vec<IndexedLineOp>>) {
    for (line, mut bucket) in buckets.into_iter().rev() {
        bucket.sort_by_key(|entry| entry.index);

        let idx = line - 1;
        let current_line = lines.get(idx).cloned().unwrap_or_default();
        let mut before_insert_lines = Vec::new();
        let mut replacement_lines = Vec::new();
        let mut after_insert_lines = Vec::new();
        let mut delete_line = false;

        for entry in bucket {
            match entry.op {
                LineOp::Delete => delete_line = true,
                LineOp::Replacement(body) => replacement_lines.extend(body),
                LineOp::InsertBefore(body) => before_insert_lines.extend(body),
                LineOp::InsertAfter(body) => after_insert_lines.extend(body),
            }
        }

        if before_insert_lines.is_empty()
            && replacement_lines.is_empty()
            && after_insert_lines.is_empty()
            && !delete_line
        {
            continue;
        }

        let mut replacement = Vec::new();
        replacement.extend(before_insert_lines);
        replacement.extend(replacement_lines);
        if !delete_line {
            replacement.push(current_line);
        }
        replacement.extend(after_insert_lines);

        lines.splice(idx..idx + 1, replacement);
    }
}

fn insert_at_start(lines: &mut Vec<String>, body: &[String]) {
    if body.is_empty() {
        return;
    }

    if lines.len() == 1 && lines[0].is_empty() {
        lines.splice(0..1, body.iter().cloned());
    } else {
        lines.splice(0..0, body.iter().cloned());
    }
}

fn insert_at_end(lines: &mut Vec<String>, body: &[String]) {
    if body.is_empty() {
        return;
    }

    let idx = if lines.len() == 1 && lines[0].is_empty() {
        lines.clear();
        0
    } else if lines.last().is_some_and(|line| line.is_empty()) {
        lines.len() - 1
    } else {
        lines.len()
    };

    lines.splice(idx..idx, body.iter().cloned());
}

fn split_lines(text: &str) -> Vec<String> {
    text.split('\n').map(|line| line.to_string()).collect()
}

fn real_line_count(lines: &[String]) -> usize {
    if lines.last().is_some_and(|line| line.is_empty()) {
        lines.len().saturating_sub(1)
    } else {
        lines.len()
    }
}

fn validate_line(line: usize, lines: &[String]) -> Result<(), String> {
    if line >= 1 && line <= lines.len() {
        Ok(())
    } else {
        Err(format!(
            "Line {} does not exist (file has {} lines)",
            line,
            real_line_count(lines)
        ))
    }
}

fn first_changed_line(before: &[String], after: &[String]) -> Option<usize> {
    let max = before.len().max(after.len());
    for idx in 0..max {
        if before.get(idx) != after.get(idx) {
            return Some(idx + 1);
        }
    }
    None
}

rustler::init!("Elixir.PiTools.Hashline.Native");
