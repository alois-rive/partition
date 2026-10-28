//! The Rive project, embedded at build time (build.rs), and the working
//! copies the `rive` CLI runs: one per window or command, each with the song
//! it should open in `assets/host/song.song` (docs/spec.md §12.2).

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

use anyhow::{Context, Result};

use crate::bundle::{self, SongFile};
use crate::songdir::write_atomic;

mod embedded {
    include!(concat!(env!("OUT_DIR"), "/project.rs"));
}

pub const HOST_SONG: &str = "assets/host/song.song";

pub fn files() -> &'static [(&'static str, &'static [u8])] {
    embedded::FILES
}

pub fn hash() -> &'static str {
    embedded::HASH
}

/// An embedded example (`assets/examples/example-<id>.song`).
pub struct Example {
    pub id: String,
    pub title: String,
    pub bpm: String,
    pub text: &'static str,
}

impl Example {
    pub fn files(&self) -> Result<Vec<SongFile>> {
        bundle::parse(&format!("example-{}.song", self.id), self.text)
    }
}

pub fn examples() -> Vec<Example> {
    let mut out = Vec::new();
    for (path, bytes) in files() {
        let Some(id) = path.strip_prefix("assets/examples/example-").and_then(|p| p.strip_suffix(".song")) else { continue };
        let text = std::str::from_utf8(bytes).unwrap_or("");
        let yaml = bundle::parse(path, text)
            .ok()
            .and_then(|files| files.into_iter().find(|f| f.path == "song.yaml"))
            .map(|f| f.text)
            .unwrap_or_default();
        out.push(Example {
            id: id.to_string(),
            title: bundle::yaml_value(&yaml, "title").unwrap_or_else(|| id.to_string()),
            bpm: bundle::yaml_value(&yaml, "bpm").unwrap_or_default(),
            text,
        });
    }
    out
}

pub fn example(id: &str) -> Option<Example> {
    examples().into_iter().find(|e| e.id == id)
}

/// The shell's cache folder: `PARTITION_CACHE`, else the platform's cache folder.
pub fn cache_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("PARTITION_CACHE") {
        return PathBuf::from(dir);
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    if cfg!(target_os = "macos") {
        home.join("Library/Caches/partition")
    } else if let Some(xdg) = std::env::var_os("XDG_CACHE_HOME") {
        PathBuf::from(xdg).join("partition")
    } else {
        home.join(".cache/partition")
    }
}

/// Removes working copies a day old or more (left behind by a killed shell).
pub fn sweep() {
    let Ok(entries) = fs::read_dir(cache_dir().join("runs")) else { return };
    for entry in entries.flatten() {
        let old =
            entry.metadata().and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).is_some_and(|age| age.as_secs() > 24 * 3600);
        if old {
            fs::remove_dir_all(entry.path()).ok();
        }
    }
}

/// A working copy of the project; removed when dropped.
pub struct Workspace {
    pub dir: PathBuf,
}

static RUNS: AtomicU32 = AtomicU32::new(0);

impl Workspace {
    /// A fresh copy, opening `song` (a packed bundle) if given.
    pub fn new(song: Option<&str>) -> Result<Workspace> {
        let n = RUNS.fetch_add(1, Ordering::Relaxed);
        let dir = cache_dir().join("runs").join(format!("{}-{}-{n}", hash(), std::process::id()));
        if dir.exists() {
            fs::remove_dir_all(&dir).ok();
        }
        for (rel, bytes) in files() {
            let path = dir.join(rel);
            fs::create_dir_all(path.parent().unwrap()).with_context(|| format!("creating {}", dir.display()))?;
            fs::write(&path, bytes).with_context(|| format!("writing {}", path.display()))?;
        }
        let ws = Workspace { dir };
        if let Some(text) = song {
            ws.set_song(text)?;
        }
        Ok(ws)
    }

    /// Replaces the song the app opens; a running previewer rebuilds and reopens it.
    pub fn set_song(&self, bundle_text: &str) -> Result<()> {
        write_atomic(&self.dir.join(HOST_SONG), bundle_text)
    }

    pub fn path(&self) -> &Path {
        &self.dir
    }
}

impl Drop for Workspace {
    fn drop(&mut self) {
        if std::env::var_os("PARTITION_KEEP_WORKSPACE").is_none() {
            fs::remove_dir_all(&self.dir).ok();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embeds_the_project_and_its_examples() {
        assert!(files().iter().any(|(p, _)| *p == "rive.yaml"));
        assert!(files().iter().any(|(p, _)| *p == HOST_SONG));
        assert!(!files().iter().any(|(p, _)| p.starts_with("build/")));
        let all = examples();
        assert!(all.len() >= 20);
        let empty = example("empty").expect("the empty template");
        assert!(empty.files().unwrap().iter().any(|f| f.path == "song.yaml"));
        let house = example("deep-house").unwrap();
        assert!(!house.title.is_empty());
    }

    #[test]
    fn workspaces_hold_the_song_and_clean_up() {
        let cache = tempfile::tempdir().unwrap();
        // SAFETY: tests that read PARTITION_CACHE run in this process only.
        unsafe { std::env::set_var("PARTITION_CACHE", cache.path()) };
        let dir;
        {
            let ws = Workspace::new(Some("%partition-bundle 1\n=== song.yaml\n")).unwrap();
            dir = ws.dir.clone();
            assert!(dir.join("scene.rml").is_file());
            assert_eq!(fs::read_to_string(dir.join(HOST_SONG)).unwrap(), "%partition-bundle 1\n=== song.yaml\n");
        }
        assert!(!dir.exists());
    }
}
