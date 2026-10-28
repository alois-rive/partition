//! The window (docs/spec.md §12.2): the `rive` previewer runs the app on a
//! working copy of the project, opened on the song. The app sends its edits,
//! saves and export requests as log lines; the shell writes them to the song,
//! and when the song changes on disk it hands the previewer the new song,
//! which rebuilds and reopens it.

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use notify::{RecursiveMode, Watcher};
use serde_json::Value;

use crate::bundle::{self, SongFile};
use crate::project::{self, Workspace};
use crate::render::{self, RenderOptions};
use crate::rivecli::{self, Output};
use crate::songdir::{self, SongSource, is_song_file};

pub struct OpenOptions {
    pub autosave: bool,
    pub verbose: bool,
}

const DEBOUNCE: Duration = Duration::from_millis(100);

/// The song as the app has it, and what the shell last wrote to disk.
pub struct Session {
    pub source: Option<SongSource>,
    pub files: BTreeMap<String, String>,
    /// Edits not saved yet (`None`: a removed file), with autosave off.
    pub pending: BTreeMap<String, Option<String>>,
    /// What the shell itself last wrote, per path (`None`: removed), to tell
    /// its own writes from other programs'.
    pub own: HashMap<String, Option<String>>,
    pub autosave: bool,
}

impl Session {
    pub fn new(source: Option<SongSource>, files: &[SongFile], autosave: bool) -> Session {
        Session {
            source,
            files: files.iter().map(|f| (f.path.clone(), f.text.clone())).collect(),
            pending: BTreeMap::new(),
            own: HashMap::new(),
            autosave,
        }
    }

    pub fn song_files(&self) -> Vec<SongFile> {
        let mut files: Vec<SongFile> = self.files.iter().map(|(p, t)| SongFile::new(p.clone(), t.clone())).collect();
        songdir::sort_files(&mut files);
        files
    }

    /// An edit from the app: `None` removes the file.
    pub fn edit(&mut self, path: &str, text: Option<String>) -> Result<()> {
        bundle::path_problem(path).map_or(Ok(()), |p| Err(anyhow::anyhow!(p)))?;
        match &text {
            Some(t) => self.files.insert(path.to_string(), t.clone()),
            None => self.files.remove(path),
        };
        self.pending.insert(path.to_string(), text);
        if self.autosave { self.save() } else { Ok(()) }
    }

    /// Writes what is pending to the song.
    pub fn save(&mut self) -> Result<()> {
        let pending = std::mem::take(&mut self.pending);
        match &self.source {
            None => {}
            Some(SongSource::Folder(dir)) => {
                for (path, text) in pending {
                    match &text {
                        Some(t) => songdir::write_file(dir, &path, t)?,
                        None => songdir::remove_file(dir, &path)?,
                    }
                    self.own.insert(path, text);
                }
            }
            Some(SongSource::Bundle(file)) if !pending.is_empty() => {
                let text = bundle::pack(&self.song_files())?;
                songdir::write_atomic(file, &text)?;
                self.own.insert(String::new(), Some(text));
            }
            Some(SongSource::Bundle(_)) => {}
        }
        Ok(())
    }

    /// Changes on disk under the song: whether the app must reopen it. Our
    /// own writes are ignored; an unsaved edit to a file changed elsewhere is
    /// kept beside it as `<file>.partition-backup`, and the disk wins.
    pub fn disk_changed(&mut self, paths: &[PathBuf]) -> Result<Vec<String>> {
        let mut changed = Vec::new();
        match self.source.clone() {
            None => {}
            Some(SongSource::Folder(dir)) => {
                for path in paths {
                    let Ok(rel) = path.strip_prefix(&dir) else { continue };
                    let rel = rel.to_string_lossy().replace('\\', "/");
                    if !is_song_file(&rel) || rel.starts_with("exports/") || rel.split('/').any(|p| p.starts_with('.')) {
                        continue;
                    }
                    let disk = fs::read_to_string(path).ok();
                    if self.own.get(&rel) == Some(&disk) || (self.files.get(&rel) == disk.as_ref() && !self.pending.contains_key(&rel)) {
                        continue;
                    }
                    if let Some(Some(unsaved)) = self.pending.remove(&rel) {
                        let backup = dir.join(format!("{rel}.partition-backup"));
                        songdir::write_atomic(&backup, &unsaved)?;
                    }
                    if !changed.contains(&rel) {
                        changed.push(rel);
                    }
                }
                if !changed.is_empty() {
                    let files = songdir::read_dir(&dir)?;
                    self.files = files.iter().map(|f| (f.path.clone(), f.text.clone())).collect();
                    for f in &files {
                        self.own.insert(f.path.clone(), Some(f.text.clone()));
                    }
                }
            }
            Some(SongSource::Bundle(file)) => {
                if !paths.iter().any(|p| p == &file) {
                    return Ok(changed);
                }
                let disk = fs::read_to_string(&file).ok();
                if self.own.get("") == Some(&disk) {
                    return Ok(changed);
                }
                if let Some(text) = disk {
                    let files = bundle::parse(&file.to_string_lossy(), &text)?;
                    if !self.pending.is_empty() {
                        let backup = file.with_extension("song.partition-backup");
                        songdir::write_atomic(&backup, &bundle::pack(&self.song_files())?)?;
                        self.pending.clear();
                    }
                    self.files = files.iter().map(|f| (f.path.clone(), f.text.clone())).collect();
                    self.own.insert(String::new(), Some(text));
                    changed.push(file.file_name().unwrap_or_default().to_string_lossy().to_string());
                }
            }
        }
        Ok(changed)
    }
}

fn say(message: &str) {
    eprintln!("partition: {message}");
}

/// Renders the app's current song next to it, on a thread of its own.
fn export(session: &Session, title: &str) {
    let files = session.song_files();
    let dir = session.source.as_ref().map(SongSource::export_dir).unwrap_or_else(|| std::env::current_dir().unwrap_or_default());
    let out = dir.join(format!("{}.wav", songdir::slug(title)));
    thread::spawn(move || {
        if let Err(e) = fs::create_dir_all(&dir) {
            say(&format!("export failed: {e}"));
            return;
        }
        say(&format!("exporting {}", out.display()));
        match render::render(&files, &out, &RenderOptions::default(), |_| {}) {
            Ok((_, seconds)) => say(&format!("exported {} ({seconds:.1} s)", out.display())),
            Err(e) => say(&format!("export failed: {e:#}")),
        }
    });
}

/// Opens the window; returns the previewer's exit code.
pub fn open(source: Option<SongSource>, opts: OpenOptions) -> Result<i32> {
    let rive = rivecli::find()?;
    project::sweep();
    let files = match &source {
        Some(s) => s.read()?,
        None => Vec::new(),
    };
    let song_text = if files.is_empty() { None } else { Some(bundle::pack(&files)?) };
    let ws = Workspace::new(song_text.as_deref())?;
    if let Some(s) = &source {
        fs::create_dir_all(project::cache_dir()).ok();
        fs::write(project::cache_dir().join("last-song"), s.path().to_string_lossy().as_bytes()).ok();
        say(&format!("opening {}", s.path().display()));
    }
    let mut session = Session::new(source.clone(), &files, opts.autosave);

    let (tx, rx) = mpsc::channel::<Output>();
    let mut child = rivecli::spawn(&rive, ws.path(), &["--aot".to_string()], tx.clone())?;
    let waiter_tx = tx.clone();
    // The previewer's exit ends the session.
    let (exit_tx, exit_rx) = mpsc::channel::<Option<i32>>();
    thread::spawn(move || {
        let code = child.wait().ok().and_then(|s| s.code());
        let _ = exit_tx.send(code);
        let _ = waiter_tx.send(Output::Exited(code));
    });

    let (fs_tx, fs_rx) = mpsc::channel::<PathBuf>();
    let _watcher = match &source {
        Some(s) => {
            let fs_tx = fs_tx.clone();
            let mut w = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
                if let Ok(event) = event {
                    for p in event.paths {
                        let _ = fs_tx.send(p);
                    }
                }
            })
            .context("watching the song")?;
            match s {
                SongSource::Folder(dir) => w.watch(dir, RecursiveMode::Recursive)?,
                SongSource::Bundle(file) => w.watch(file.parent().unwrap_or(Path::new(".")), RecursiveMode::NonRecursive)?,
            }
            Some(w)
        }
        None => None,
    };

    let mut changed_paths: Vec<PathBuf> = Vec::new();
    let mut last_fs = Instant::now();
    loop {
        match rx.recv_timeout(Duration::from_millis(50)) {
            Ok(Output::Line(line)) => {
                if let Some(msg) = rivecli::host_message(&line) {
                    if let Err(e) = handle(&mut session, &msg) {
                        say(&format!("{e:#}"));
                    }
                } else if opts.verbose || rivecli::is_error(&line) {
                    eprintln!("{line}");
                }
            }
            Ok(Output::Exited(code)) => {
                if !session.pending.is_empty() {
                    say(&format!("{} unsaved change(s) were not written (autosave is off)", session.pending.len()));
                }
                return Ok(code.unwrap_or(0));
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
        while let Ok(p) = fs_rx.try_recv() {
            changed_paths.push(p);
            last_fs = Instant::now();
        }
        if !changed_paths.is_empty() && last_fs.elapsed() >= DEBOUNCE {
            let paths = std::mem::take(&mut changed_paths);
            match session.disk_changed(&paths) {
                Ok(changed) if !changed.is_empty() => {
                    say(&format!("{} changed on disk; reopening", changed.join(", ")));
                    match bundle::pack(&session.song_files()) {
                        Ok(text) => ws.set_song(&text)?,
                        Err(e) => say(&format!("cannot reopen: {e}")),
                    }
                }
                Ok(_) => {}
                Err(e) => say(&format!("{e:#}")),
            }
        }
    }
    Ok(exit_rx.recv().ok().flatten().unwrap_or(0))
}

fn handle(session: &mut Session, msg: &Value) -> Result<()> {
    match msg["op"].as_str() {
        Some("write") => {
            let path = msg["path"].as_str().unwrap_or("");
            let text = msg["text"].as_str().unwrap_or("").to_string();
            session.edit(path, Some(text))
        }
        Some("remove") => session.edit(msg["path"].as_str().unwrap_or(""), None),
        Some("save") => {
            session.save()?;
            if session.source.is_none() {
                say("this song is not from disk; use `partition new DIR` to start one you can save");
            }
            Ok(())
        }
        Some("export") => {
            export(session, msg["title"].as_str().unwrap_or("song"));
            Ok(())
        }
        Some("ready") => {
            let errors = msg["errors"].as_u64().unwrap_or(0);
            let title = msg["title"].as_str().unwrap_or("");
            say(&format!(
                "opened {title} ({:.1} s{})",
                msg["duration"].as_f64().unwrap_or(0.0),
                if errors > 0 { format!(", {errors} error(s)") } else { String::new() }
            ));
            Ok(())
        }
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder() -> (tempfile::TempDir, Session) {
        let dir = tempfile::tempdir().unwrap();
        let files = vec![SongFile::new("song.yaml", "title: T\n"), SongFile::new("channels/a.ch", "x\n")];
        songdir::write_song(&dir.path().join("s"), &files).unwrap();
        let session = Session::new(Some(SongSource::Folder(dir.path().join("s"))), &files, true);
        (dir, session)
    }

    #[test]
    fn autosave_writes_and_ignores_its_own_writes() {
        let (dir, mut s) = folder();
        let song = dir.path().join("s");
        s.edit("channels/a.ch", Some("y\n".into())).unwrap();
        s.edit("patterns/p.pat", Some("z\n".into())).unwrap();
        assert_eq!(fs::read_to_string(song.join("channels/a.ch")).unwrap(), "y\n");
        assert!(s.disk_changed(&[song.join("channels/a.ch"), song.join("patterns/p.pat")]).unwrap().is_empty());
        s.edit("patterns/p.pat", None).unwrap();
        assert!(!song.join("patterns/p.pat").exists());
        assert!(s.disk_changed(&[song.join("patterns/p.pat")]).unwrap().is_empty());
    }

    #[test]
    fn outside_changes_reopen_and_back_up_unsaved_edits() {
        let (dir, mut s) = folder();
        let song = dir.path().join("s");
        s.autosave = false;
        s.edit("channels/a.ch", Some("mine\n".into())).unwrap();
        assert_eq!(fs::read_to_string(song.join("channels/a.ch")).unwrap(), "x\n");
        fs::write(song.join("channels/a.ch"), "theirs\n").unwrap();
        let changed = s.disk_changed(&[song.join("channels/a.ch")]).unwrap();
        assert_eq!(changed, ["channels/a.ch"]);
        assert_eq!(s.files["channels/a.ch"], "theirs\n");
        assert_eq!(fs::read_to_string(song.join("channels/a.ch.partition-backup")).unwrap(), "mine\n");
        assert!(s.pending.is_empty());
        // Saving writes nothing more; other files are not song files.
        s.save().unwrap();
        fs::write(song.join("notes.txt"), "x").unwrap();
        assert!(s.disk_changed(&[song.join("notes.txt")]).unwrap().is_empty());
    }

    #[test]
    fn bundles_are_written_whole() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("a.song");
        let files = vec![SongFile::new("song.yaml", "title: T\n")];
        fs::write(&file, bundle::pack(&files).unwrap()).unwrap();
        let mut s = Session::new(Some(SongSource::Bundle(file.clone())), &files, true);
        s.edit("conductor.ch", Some("bpm(v: 100)\n".into())).unwrap();
        let back = bundle::parse("a", &fs::read_to_string(&file).unwrap()).unwrap();
        assert_eq!(back.len(), 2);
        assert!(s.disk_changed(std::slice::from_ref(&file)).unwrap().is_empty());
        assert!(s.edit("../x", Some(String::new())).is_err());
    }
}
