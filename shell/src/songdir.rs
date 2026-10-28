//! Songs on disk (docs/spec.md §3): a folder of files, or a `.song` bundle.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

use crate::bundle::{self, SongFile, path_problem};

/// Whether a path inside a song folder is one of the song's files.
pub fn is_song_file(rel: &str) -> bool {
    rel == "song.yaml" || rel.ends_with(".ch") || rel.ends_with(".pat") || rel.ends_with(".inst")
}

/// Folders the shell writes into a song folder that are not part of the song.
const SKIPPED_DIRS: [&str; 1] = ["exports"];

fn walk(root: &Path, dir: &Path, out: &mut Vec<String>) -> Result<()> {
    let mut entries: Vec<PathBuf> =
        fs::read_dir(dir).with_context(|| format!("reading {}", dir.display()))?.filter_map(|e| e.ok().map(|e| e.path())).collect();
    entries.sort();
    for path in entries {
        let name = path.file_name().unwrap_or_default().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        let rel = path.strip_prefix(root).unwrap().to_string_lossy().replace('\\', "/");
        if path.is_dir() {
            if dir == root && SKIPPED_DIRS.contains(&name.as_str()) {
                continue;
            }
            walk(root, &path, out)?;
        } else if is_song_file(&rel) {
            out.push(rel);
        }
    }
    Ok(())
}

/// Song files in the canonical order: song.yaml, conductor.ch, then by path.
pub fn sort_files(files: &mut [SongFile]) {
    fn rank(path: &str) -> u8 {
        match path {
            "song.yaml" => 0,
            "conductor.ch" => 1,
            _ => 2,
        }
    }
    files.sort_by(|a, b| rank(&a.path).cmp(&rank(&b.path)).then_with(|| a.path.cmp(&b.path)));
}

/// Every song file in `dir`.
pub fn read_dir(dir: &Path) -> Result<Vec<SongFile>> {
    if !dir.join("song.yaml").is_file() {
        bail!("{} is not a song: it has no song.yaml", dir.display());
    }
    let mut paths = Vec::new();
    walk(dir, dir, &mut paths)?;
    let mut files = Vec::new();
    for rel in paths {
        let abs = dir.join(&rel);
        let text = fs::read_to_string(&abs).with_context(|| format!("reading {} (song files are UTF-8)", abs.display()))?;
        files.push(SongFile::new(rel, text));
    }
    sort_files(&mut files);
    Ok(files)
}

/// The path of a song file inside `dir`, refusing anything that would leave it.
pub fn resolve(dir: &Path, rel: &str) -> Result<PathBuf> {
    if let Some(problem) = path_problem(rel) {
        bail!(problem);
    }
    Ok(dir.join(rel))
}

/// Writes `text` through a temporary file and a rename, so readers never see half a file.
pub fn write_atomic(path: &Path, text: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    let tmp = path.with_file_name(format!(".{name}.partition-tmp"));
    fs::write(&tmp, text).with_context(|| format!("writing {}", tmp.display()))?;
    fs::rename(&tmp, path).with_context(|| format!("replacing {}", path.display()))?;
    Ok(())
}

pub fn write_file(dir: &Path, rel: &str, text: &str) -> Result<()> {
    write_atomic(&resolve(dir, rel)?, text)
}

pub fn remove_file(dir: &Path, rel: &str) -> Result<()> {
    let path = resolve(dir, rel)?;
    match fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e).with_context(|| format!("removing {}", path.display())),
    }
}

/// Writes a whole song into `dir`, which must be new or empty.
pub fn write_song(dir: &Path, files: &[SongFile]) -> Result<()> {
    if dir.exists() && fs::read_dir(dir)?.next().is_some() {
        bail!("{} is not empty", dir.display());
    }
    fs::create_dir_all(dir)?;
    for f in files {
        write_file(dir, &f.path, &f.text)?;
    }
    Ok(())
}

/// Where a song lives: a folder, or a bundle file.
#[derive(Debug, Clone)]
pub enum SongSource {
    Folder(PathBuf),
    Bundle(PathBuf),
}

impl SongSource {
    pub fn from_arg(arg: &Path) -> Result<SongSource> {
        let abs = if arg.is_absolute() { arg.to_path_buf() } else { std::env::current_dir()?.join(arg) };
        if abs.is_dir() {
            Ok(SongSource::Folder(abs))
        } else if abs.extension().is_some_and(|e| e == "song") {
            if !abs.is_file() {
                bail!("{} does not exist", abs.display());
            }
            Ok(SongSource::Bundle(abs))
        } else {
            bail!("{} is neither a song folder nor a .song bundle", arg.display())
        }
    }

    pub fn path(&self) -> &Path {
        match self {
            SongSource::Folder(p) | SongSource::Bundle(p) => p,
        }
    }

    pub fn read(&self) -> Result<Vec<SongFile>> {
        match self {
            SongSource::Folder(dir) => read_dir(dir),
            SongSource::Bundle(file) => {
                let text = fs::read_to_string(file).with_context(|| format!("reading {}", file.display()))?;
                bundle::parse(&file.to_string_lossy(), &text)
            }
        }
    }

    /// Where exports go: `exports/` in a folder, or next to a bundle.
    pub fn export_dir(&self) -> PathBuf {
        match self {
            SongSource::Folder(dir) => dir.join("exports"),
            SongSource::Bundle(file) => file.parent().map(Path::to_path_buf).unwrap_or_default(),
        }
    }
}

/// A file name from a song title: lowercase, words joined by '-'.
pub fn slug(title: &str) -> String {
    let mut out = String::new();
    for c in title.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if !out.is_empty() && !out.ends_with('-') {
            out.push('-');
        }
    }
    let out = out.trim_end_matches('-').to_string();
    if out.is_empty() { "song".into() } else { out }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_folder_in_order_and_skips_the_rest() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        write_file(d, "channels/b.ch", "x\n").unwrap();
        write_file(d, "channels/a.ch", "y\n").unwrap();
        write_file(d, "conductor.ch", "").unwrap();
        write_file(d, "song.yaml", "title: T\n").unwrap();
        write_file(d, "patterns/p.pat", "z\n").unwrap();
        fs::create_dir_all(d.join("exports")).unwrap();
        fs::write(d.join("exports/x.ch"), "ignored").unwrap();
        fs::write(d.join("notes.txt"), "ignored").unwrap();
        fs::write(d.join(".hidden.ch"), "ignored").unwrap();
        let paths: Vec<String> = read_dir(d).unwrap().into_iter().map(|f| f.path).collect();
        assert_eq!(paths, ["song.yaml", "conductor.ch", "channels/a.ch", "channels/b.ch", "patterns/p.pat"]);
    }

    #[test]
    fn refuses_escapes_and_non_empty_targets() {
        let dir = tempfile::tempdir().unwrap();
        assert!(write_file(dir.path(), "../x.ch", "").is_err());
        write_file(dir.path(), "a.ch", "").unwrap();
        assert!(write_song(dir.path(), &[]).is_err());
        assert!(read_dir(dir.path()).is_err()); // no song.yaml
    }

    #[test]
    fn slugs() {
        assert_eq!(slug("Late Night Deep House"), "late-night-deep-house");
        assert_eq!(slug("  !!"), "song");
    }
}
