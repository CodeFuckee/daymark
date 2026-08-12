//! 文档解析器：pptx / xlsx / docx / pdf → 纯文本提取。
//!
//! 设计约定（DESIGN.md §5.5）：
//! - 只提取可见文本（`<a:t>` / `<w:t>` / sharedStrings），图形化内容降级跳过
//! - xlsx 限制行数（前 500 行）防爆炸，文本总量截断（5000 字）
//! - 提取失败由调用方降级为"仅记录文件名"，不阻断流水线

use anyhow::{anyhow, Context, Result};
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

/// 提取出的文档内容
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Extracted {
    pub path: String,
    /// pptx | xlsx | docx | pdf
    pub kind: String,
    /// 首段文本（≤60 字），用于日报要点
    pub title: String,
    /// 全文截断后的文本（≤5000 字）
    pub text_excerpt: String,
    /// 全文 sha256 前 16 字节 hex，用于变更去重
    pub text_hash: String,
}

pub const MAX_TEXT_CHARS: usize = 5000;
pub const MAX_XLSX_ROWS: usize = 500;

/// 主入口：按扩展名分派解析器
pub fn extract_document(path: &str) -> Result<Extracted> {
    let kind = kind_of(path)?;
    let full_text = match kind.as_str() {
        "pptx" => extract_pptx(path)?,
        "xlsx" => extract_xlsx(path)?,
        "docx" => extract_docx(path)?,
        "pdf" => extract_pdf(path)?,
        _ => return Err(anyhow!("unsupported kind: {kind}")),
    };
    let title = first_line(&full_text, 60);
    let text_excerpt = truncate(&full_text, MAX_TEXT_CHARS);
    let text_hash = sha256_hex(&full_text);
    Ok(Extracted {
        path: path.to_string(),
        kind,
        title,
        text_excerpt,
        text_hash,
    })
}

fn kind_of(path: &str) -> Result<String> {
    let ext = Path::new(path)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "pptx" => Ok("pptx".into()),
        "xlsx" => Ok("xlsx".into()),
        "docx" => Ok("docx".into()),
        "pdf" => Ok("pdf".into()),
        _ => Err(anyhow!("unsupported document kind: .{ext}")),
    }
}

// ─────────────────────────── zip + xml 通用工具 ───────────────────────────

/// 打开 zip 归档
fn open_zip(path: &str) -> Result<zip::ZipArchive<BufReader<File>>> {
    let file = File::open(path).with_context(|| format!("cannot open {path}"))?;
    zip::ZipArchive::new(BufReader::new(file))
        .map_err(|e| anyhow!("zip open failed for {path}: {e}"))
}

/// 标签名取 local name：`w:t` → `t`
fn local_name(raw: &[u8]) -> String {
    let name = String::from_utf8_lossy(raw);
    name.rsplit(':').next().unwrap_or(&name).to_string()
}

/// 收集单个 xml 条目中指定 local name 标签内的文本。
/// 遇到 [`BREAK_TAGS`] 中的标签（如段落/行）时追加换行。
fn collect_xml_text<R: Read>(
    reader: R,
    tag: &str,
    break_tags: &[&str],
    max_chars: usize,
) -> Result<String> {
    // quick-xml 的 read_event_into 要求 BufRead；
    // 不开启 trim_text：0.38 会把含实体的文本分片并 trim 丢字
    let mut xml = quick_xml::Reader::from_reader(BufReader::new(reader));
    let mut buf = Vec::new();
    let mut out = String::new();
    let mut in_tag = false;
    loop {
        if out.len() >= max_chars {
            break;
        }
        match xml.read_event_into(&mut buf) {
            Ok(quick_xml::events::Event::Start(e)) | Ok(quick_xml::events::Event::Empty(e)) => {
                let name = local_name(e.name().as_ref());
                if name == tag {
                    in_tag = true;
                } else if break_tags.contains(&name.as_str()) {
                    out.push('\n');
                }
            }
            Ok(quick_xml::events::Event::End(e)) => {
                let name = local_name(e.name().as_ref());
                if name == tag {
                    in_tag = false;
                }
            }
            Ok(quick_xml::events::Event::Text(e)) => {
                if in_tag {
                    let text = e.decode().unwrap_or_default();
                    push_chunk(&mut out, &text, max_chars);
                }
            }
            // 实体引用（如 &amp;）被拆为独立事件：补回 & 与 ; 后反转义
            Ok(quick_xml::events::Event::GeneralRef(e)) => {
                if in_tag {
                    if let Ok(name) = e.decode() {
                        if let Ok(decoded) = quick_xml::escape::unescape(&format!("&{name};")) {
                            push_chunk(&mut out, &decoded, max_chars);
                        }
                    }
                }
            }
            Ok(quick_xml::events::Event::Eof) => break,
            Err(e) => return Err(anyhow!("xml parse error: {e}")),
            _ => {}
        }
        buf.clear();
    }
    Ok(out)
}

/// 按 max_chars 截断追加
fn push_chunk(out: &mut String, text: &str, max_chars: usize) {
    let remaining = max_chars.saturating_sub(out.len());
    let chunk: String = text.chars().take(remaining).collect();
    out.push_str(&chunk);
}

/// 首行文本（≤limit 字），标题候选
fn first_line(text: &str, limit: usize) -> String {
    text.lines()
        .map(|l| l.trim())
        .find(|l| !l.is_empty())
        .unwrap_or_default()
        .chars()
        .take(limit)
        .collect()
}

fn truncate(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        text.to_string()
    } else {
        text.chars().take(max).collect()
    }
}

fn sha256_hex(text: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(text.as_bytes());
    let digest = hasher.finalize();
    hex16(&digest)
}

fn hex16(digest: &[u8]) -> String {
    digest
        .iter()
        .take(16)
        .map(|b| format!("{b:02x}"))
        .collect()
}

// ─────────────────────────── docx ───────────────────────────

/// docx：word/document.xml，`<w:t>` 为文本、`<w:p>` 分段
fn extract_docx(path: &str) -> Result<String> {
    let mut archive = open_zip(path)?;
    let entry = archive
        .by_name("word/document.xml")
        .map_err(|_| anyhow!("{path}: no word/document.xml"))?;
    collect_xml_text(entry, "t", &["p"], MAX_TEXT_CHARS)
}

// ─────────────────────────── pptx ───────────────────────────

/// pptx：按幻灯片顺序解析 ppt/slides/slide*.xml，`<a:t>` 文本、`<a:p>` 分段
fn extract_pptx(path: &str) -> Result<String> {
    let mut archive = open_zip(path)?;
    // 收集 slide 文件名并排序（slide1 < slide2 < ... < slide10）
    let mut slides: Vec<String> = archive
        .file_names()
        .filter(|n| n.starts_with("ppt/slides/slide") && n.ends_with(".xml"))
        .map(|n| n.to_string())
        .collect();
    slides.sort_by_key(|n| slide_number(n));
    if slides.is_empty() {
        return Err(anyhow!("{path}: no slides found"));
    }
    let mut out = String::new();
    for name in slides {
        let entry = archive
            .by_name(&name)
            .map_err(|_| anyhow!("{path}: missing {name}"))?;
        let text = collect_xml_text(entry, "t", &["p"], MAX_TEXT_CHARS)?;
        if out.len() < MAX_TEXT_CHARS {
            out.push_str(&text);
            out.push('\n');
        }
    }
    Ok(out)
}

fn slide_number(name: &str) -> u32 {
    name.trim_start_matches("ppt/slides/slide")
        .trim_end_matches(".xml")
        .parse()
        .unwrap_or(u32::MAX)
}

// ─────────────────────────── xlsx ───────────────────────────

/// xlsx：sharedStrings + 各 sheet 单元格文本，制表符连接一行、行间换行。
/// 限制前 500 行（防合并/公式展开导致爆炸）。
fn extract_xlsx(path: &str) -> Result<String> {
    let mut archive = open_zip(path)?;

    // 1. sharedStrings：`<si><t>...` 每 si 一条
    let mut shared: Vec<String> = Vec::new();
    if archive
        .file_names()
        .any(|n| n == "xl/sharedStrings.xml")
    {
        let entry = archive
            .by_name("xl/sharedStrings.xml")
            .map_err(|_| anyhow!("{path}: no sharedStrings"))?;
        // 每 si 内的 t 合并为一条，si 之间用 \n 分隔（占位）
        let raw = collect_xml_text(entry, "t", &["si"], usize::MAX)?;
        shared = raw.split('\n').map(|s| s.trim().to_string()).collect();
    }

    // 2. 每个 sheet：`<c t="s"><v>idx</v></c>` 或 `<c><v>literal</v></c>` 或 inlineStr
    let mut sheets: Vec<String> = archive
        .file_names()
        .filter(|n| {
            n.starts_with("xl/worksheets/sheet") && n.ends_with(".xml") && !n.contains("rels")
        })
        .map(|n| n.to_string())
        .collect();
    sheets.sort();

    let mut out = String::new();
    for sheet in sheets {
        let entry = archive
            .by_name(&sheet)
            .map_err(|_| anyhow!("{path}: missing {sheet}"))?;
        let text = extract_xlsx_sheet(entry, &shared)?;
        if out.len() < MAX_TEXT_CHARS {
            out.push_str(&text);
            out.push('\n');
        }
    }
    Ok(out)
}

fn extract_xlsx_sheet<R: Read>(reader: R, shared: &[String]) -> Result<String> {
    // 同 collect_xml_text：不 trim，实体引用单独处理
    let mut xml = quick_xml::Reader::from_reader(BufReader::new(reader));
    let mut buf = Vec::new();
    let mut out = String::new();
    let mut rows: usize = 0;
    let mut in_row = false;
    let mut in_cell = false;
    let mut cell_is_shared = false;
    let mut cell_value = String::new();

    loop {
        match xml.read_event_into(&mut buf) {
            Ok(quick_xml::events::Event::Start(e)) | Ok(quick_xml::events::Event::Empty(e)) => {
                let name = local_name(e.name().as_ref());
                match name.as_str() {
                    "row" => {
                        if in_row {
                            out.push('\n');
                        }
                        in_row = true;
                        rows += 1;
                        if rows > MAX_XLSX_ROWS {
                            break;
                        }
                    }
                    "c" => {
                        in_cell = true;
                        cell_value.clear();
                        // 检查 t 属性：t="s" → shared string；t="inlineStr" → 内联
                        cell_is_shared = false;
                        for attr in e.attributes().flatten() {
                            if attr.key.as_ref() == b"t" {
                                match attr.value.as_ref() {
                                    b"s" => cell_is_shared = true,
                                    _ => cell_is_shared = false,
                                }
                            }
                        }
                    }
                    "t" => {
                        // 内联字符串直接取文本（共享字符串的 t 也在收集之列，
                        // 但 xlsx 的 v 才是 shared 索引，见下）
                        // no-op：文本由 Event::Text 处理
                    }
                    _ => {}
                }
            }
            Ok(quick_xml::events::Event::End(e)) => {
                let name = local_name(e.name().as_ref());
                match name.as_str() {
                    "c" => {
                        let resolved = if cell_is_shared {
                            cell_value
                                .trim()
                                .parse::<usize>()
                                .ok()
                                .and_then(|i| shared.get(i))
                                .cloned()
                                .unwrap_or_default()
                        } else {
                            cell_value.clone()
                        };
                        if !resolved.is_empty() {
                            if !out.ends_with('\n') && !out.is_empty() {
                                out.push('\t');
                            }
                            out.push_str(&resolved);
                        }
                        in_cell = false;
                    }
                    "row" => {
                        out.push('\n');
                        in_row = false;
                    }
                    _ => {}
                }
            }
            Ok(quick_xml::events::Event::Text(e)) => {
                if in_cell {
                    if let Ok(t) = e.decode() {
                        cell_value.push_str(&t);
                    }
                }
            }
            // 实体引用（如 &amp;）拆为独立事件
            Ok(quick_xml::events::Event::GeneralRef(e)) => {
                if in_cell {
                    if let Ok(name) = e.decode() {
                        if let Ok(decoded) = quick_xml::escape::unescape(&format!("&{name};")) {
                            cell_value.push_str(&decoded);
                        }
                    }
                }
            }
            Ok(quick_xml::events::Event::Eof) => break,
            Err(e) => return Err(anyhow!("xlsx xml error: {e}")),
            _ => {}
        }
        buf.clear();
    }
    Ok(out)
}

// ─────────────────────────── pdf ───────────────────────────

/// pdf：pdf-extract 全文提取
fn extract_pdf(path: &str) -> Result<String> {
    let output = pdf_extract::extract_text(path)
        .map_err(|e| anyhow!("pdf extract failed for {path}: {e}"))?;
    Ok(truncate(&output, MAX_TEXT_CHARS))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// 在内存中构造一个最小 docx（zip + word/document.xml）
    fn make_mini_docx(body: &str) -> Vec<u8> {
        let mut zip = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
        let options = zip::write::SimpleFileOptions::default();
        zip.start_file(
            "word/document.xml",
            options,
        )
        .unwrap();
        zip.write_all(
            format!(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>{body}</w:body>
</w:document>"#
            )
            .as_bytes(),
        )
        .unwrap();
        zip.finish().unwrap().into_inner()
    }

    #[test]
    fn extract_docx_plain_text() {
        let bytes = make_mini_docx(
            "<w:p><w:r><w:t>标题行</w:t></w:r></w:p>\
             <w:p><w:r><w:t>第二段含 &amp; 实体</w:t></w:r></w:p>",
        );
        let dir = std::env::temp_dir();
        let path = dir.join("daymark_test_mini.docx");
        std::fs::write(&path, bytes).unwrap();

        let extracted = extract_document(&path.to_string_lossy()).unwrap();
        assert_eq!(extracted.kind, "docx");
        assert_eq!(extracted.title, "标题行");
        assert!(extracted.text_excerpt.contains("标题行"));
        assert!(extracted.text_excerpt.contains("第二段含 & 实体"));
        assert_eq!(extracted.text_hash.len(), 32);
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn extract_unsupported_kind() {
        assert!(extract_document("/tmp/foo.txt").is_err());
    }

    #[test]
    fn extract_missing_file() {
        let err = extract_document("/tmp/definitely_missing_12345.docx").unwrap_err();
        assert!(err.to_string().contains("cannot open"));
    }

    #[test]
    fn truncate_respects_limit() {
        let text = "x".repeat(10000);
        assert_eq!(truncate(&text, 5000).len(), 5000);
        assert_eq!(truncate(&text, 5000), text[..5000]);
    }
}
