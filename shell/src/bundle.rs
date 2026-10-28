//! Song bundles (docs/spec.md §3.2): a song folder packed into one text file.
//! This mirrors `rive/src/lang/bundle.as`, so both sides read and write the
//! same files.

use anyhow::{Result, bail};

pub const MAGIC: &str = "%partition-bundle 1";
const HEADER: &str = "=== ";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SongFile {
    pub path: String,
    pub text: String,
}

impl SongFile {
    pub fn new(path: impl Into<String>, text: impl Into<String>) -> Self {
        SongFile { path: path.into(), text: text.into() }
    }
}

/// Lines without their terminators (LF or CRLF); a final newline adds no empty line.
pub fn split_lines(text: &str) -> Vec<&str> {
    let mut lines = Vec::new();
    let mut rest = text;
    while let Some(i) = rest.find('\n') {
        lines.push(rest[..i].strip_suffix('\r').unwrap_or(&rest[..i]));
        rest = &rest[i + 1..];
    }
    if !rest.is_empty() {
        lines.push(rest.strip_suffix('\r').unwrap_or(rest));
    }
    lines
}

/// Why `path` cannot name a file in a song, or `None` when it can.
pub fn path_problem(path: &str) -> Option<String> {
    if path.is_empty() {
        return Some("a file needs a path".into());
    }
    if path.starts_with('/') || path.contains('\\') {
        return Some(format!("'{path}' must be a relative path with '/' separators"));
    }
    if path.split('/').any(|p| p.is_empty() || p == "." || p == "..") {
        return Some(format!("'{path}' must not contain empty, '.' or '..' segments"));
    }
    None
}

fn join_body(lines: &[&str]) -> String {
    if lines.is_empty() {
        return String::new();
    }
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

/// The files of a bundle; the first problem as an error (`name:line: message`).
pub fn parse(name: &str, text: &str) -> Result<Vec<SongFile>> {
    let lines = split_lines(text);
    if lines.first() != Some(&MAGIC) {
        bail!("{name}:1: a bundle starts with '{MAGIC}'");
    }
    let mut files: Vec<SongFile> = Vec::new();
    let mut body: Vec<&str> = Vec::new();
    let mut open = false;
    for (i, line) in lines.iter().enumerate().skip(1) {
        if let Some(path) = line.strip_prefix(HEADER) {
            if open {
                files.last_mut().unwrap().text = join_body(&body);
            }
            body.clear();
            let path = path.trim();
            if let Some(problem) = path_problem(path) {
                bail!("{name}:{}: {problem}", i + 1);
            }
            if files.iter().any(|f| f.path == path) {
                bail!("{name}:{}: '{path}' appears twice", i + 1);
            }
            files.push(SongFile::new(path, ""));
            open = true;
        } else if open {
            body.push(line);
        } else if !line.trim().is_empty() {
            bail!("{name}:{}: text outside of a file; start a file with '=== <path>'", i + 1);
        }
    }
    if open {
        files.last_mut().unwrap().text = join_body(&body);
    }
    Ok(files)
}

/// Why `files` cannot be packed, or `None` when they can.
pub fn pack_problem(files: &[SongFile]) -> Option<String> {
    for f in files {
        if let Some(problem) = path_problem(&f.path) {
            return Some(problem);
        }
        for (j, line) in split_lines(&f.text).iter().enumerate() {
            if line.starts_with(HEADER) {
                return Some(format!("{}:{} starts with '=== ', which a bundle cannot hold", f.path, j + 1));
            }
        }
    }
    None
}

pub fn pack(files: &[SongFile]) -> Result<String> {
    if let Some(problem) = pack_problem(files) {
        bail!(problem);
    }
    let mut out = format!("{MAGIC}\n");
    for f in files {
        out.push_str(HEADER);
        out.push_str(&f.path);
        out.push('\n');
        let lines = split_lines(&f.text);
        if !lines.is_empty() {
            out.push_str(&lines.join("\n"));
            out.push('\n');
        }
    }
    Ok(out)
}

/// A value of a top-level `key:` in song.yaml, unquoted (enough for listings).
pub fn yaml_value(yaml: &str, key: &str) -> Option<String> {
    for line in split_lines(yaml) {
        if let Some(rest) = line.strip_prefix(key).and_then(|r| r.strip_prefix(':')) {
            let mut v = rest.trim();
            if !v.starts_with('"')
                && let Some(i) = v.find(" #")
            {
                v = v[..i].trim();
            }
            let v = v.strip_prefix('"').and_then(|s| s.strip_suffix('"')).unwrap_or(v);
            return Some(v.replace("\\\"", "\"").replace("\\\\", "\\"));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let files = vec![
            SongFile::new("song.yaml", "title: A\n"),
            SongFile::new("conductor.ch", ""),
            SongFile::new("channels/kick.ch", "note(p: C1)\n\n\nnote(p: C1)\n"),
        ];
        let text = pack(&files).unwrap();
        assert!(text.starts_with(MAGIC));
        assert_eq!(parse("t", &text).unwrap(), files);
    }

    #[test]
    fn crlf_and_missing_final_newline() {
        let files = parse("t", "%partition-bundle 1\r\n=== a.ch\r\nx\r\ny").unwrap();
        assert_eq!(files, vec![SongFile::new("a.ch", "x\ny\n")]);
    }

    #[test]
    fn problems() {
        assert!(parse("t", "nope\n").is_err());
        assert!(parse("t", "%partition-bundle 1\n=== ../x\n").is_err());
        assert!(parse("t", "%partition-bundle 1\n=== a\n=== a\n").is_err());
        assert!(parse("t", "%partition-bundle 1\nstray\n").is_err());
        assert!(pack(&[SongFile::new("a.ch", "=== b\n")]).is_err());
        assert!(path_problem("a/./b").is_some());
        assert!(path_problem("channels/kick.ch").is_none());
    }

    #[test]
    fn yaml_values() {
        let y = "title: \"Late: Night\"\nbpm: 122 # tempo\nauthor: me\n";
        assert_eq!(yaml_value(y, "title").unwrap(), "Late: Night");
        assert_eq!(yaml_value(y, "bpm").unwrap(), "122");
        assert_eq!(yaml_value(y, "swing"), None);
    }
}
