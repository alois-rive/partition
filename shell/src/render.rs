//! Headless runs (docs/spec.md §12.1): `check` prints a song's diagnostics,
//! `render` plays it through the app's audio processor in a headless `rive`
//! and keeps what it hears, which is bit-exact with the app's own export.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde_json::Value;

use crate::bundle::{self, SongFile};
use crate::project::Workspace;
use crate::rivecli;
use crate::wav::{self, Format};

#[derive(Debug, Clone)]
pub struct RenderOptions {
    pub rate: u32,
    pub format: Format,
    /// Extra passes of each endless loop.
    pub loops: u32,
    /// First source row to play (0: the start).
    pub from: u32,
    /// Last source row to play (0: the end).
    pub to: u32,
    /// Most seconds of release kept after the song ends.
    pub tail: f64,
}

impl Default for RenderOptions {
    fn default() -> Self {
        RenderOptions { rate: 48000, format: Format::Pcm16, loops: 1, from: 0, to: 0, tail: 8.0 }
    }
}

#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub path: String,
    pub line: u64,
    pub col: u64,
    pub error: bool,
    pub code: String,
    pub message: String,
}

impl std::fmt::Display for Diagnostic {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let severity = if self.error { "error" } else { "warning" };
        write!(f, "{}:{}:{}: {severity} [{}] {}", self.path, self.line, self.col, self.code, self.message)
    }
}

/// What the app reported about a song once it had compiled it.
#[derive(Debug, Clone, Default)]
pub struct Report {
    pub title: String,
    pub duration: f64,
    pub diagnostics: Vec<Diagnostic>,
    /// Integrated loudness of the rendered file (renders only).
    pub lufs: f64,
}

pub fn loudness_text(lufs: f64) -> String {
    if lufs.is_finite() { format!("{lufs:.1} LUFS") } else { "silent".into() }
}

impl Report {
    pub fn errors(&self) -> usize {
        self.diagnostics.iter().filter(|d| d.error).count()
    }
}

pub fn diagnostics_of(msg: &Value) -> Vec<Diagnostic> {
    let Some(items) = msg["diagnostics"].as_array() else { return Vec::new() };
    items
        .iter()
        .map(|d| Diagnostic {
            path: d["path"].as_str().unwrap_or("").to_string(),
            line: d["line"].as_u64().unwrap_or(0),
            col: d["col"].as_u64().unwrap_or(0),
            error: d["severity"] == "error",
            code: d["code"].as_str().unwrap_or("").to_string(),
            message: d["message"].as_str().unwrap_or("").to_string(),
        })
        .collect()
}

fn data_args(opts: &RenderOptions) -> Vec<String> {
    vec![
        "--data=render/realtime=true".into(),
        format!("--data=render/loops={}", opts.loops),
        format!("--data=render/fromRow={}", opts.from),
        format!("--data=render/toRow={}", opts.to),
        "--data=song/autoplay=true".into(),
    ]
}

/// Runs the song headless for a moment and collects the app's report.
fn query(rive: &Path, ws: &Workspace, opts: &RenderOptions) -> Result<Report> {
    let dump = ws.path().join("build/query.json");
    let mut args = vec!["--aot".to_string(), format!("--data-dump={}", dump.display())];
    args.extend(data_args(opts));
    args.push("--advance=3".into());
    let (lines, code) = rivecli::run(rive, ws.path(), &args)?;
    let mut report = Report::default();
    let mut ready = false;
    let mut playing = false;
    for line in &lines {
        let Some(msg) = rivecli::host_message(line) else { continue };
        match msg["op"].as_str() {
            Some("ready") => {
                ready = true;
                report.title = msg["title"].as_str().unwrap_or("").to_string();
                report.duration = msg["duration"].as_f64().unwrap_or(0.0);
                report.diagnostics = diagnostics_of(&msg);
            }
            Some("playing") => {
                playing = true;
                report.duration = msg["duration"].as_f64().unwrap_or(report.duration);
            }
            _ => {}
        }
    }
    if !ready || !playing {
        let problems: Vec<&String> = lines.iter().filter(|l| rivecli::is_error(l)).collect();
        if problems.is_empty() {
            bail!("the app did not open the song (rive exited with {code:?})");
        }
        bail!("the app did not open the song:\n{}", problems.iter().map(|l| l.as_str()).collect::<Vec<_>>().join("\n"));
    }
    Ok(report)
}

/// Compiles the song in the app and returns its report.
pub fn check(files: &[SongFile]) -> Result<Report> {
    let rive = rivecli::find()?;
    let ws = Workspace::new(Some(&bundle::pack(files)?))?;
    query(&rive, &ws, &RenderOptions::default())
}

/// Renders the song to `out`; returns the report and the length written, in seconds.
pub fn render(files: &[SongFile], out: &Path, opts: &RenderOptions, progress: impl Fn(&str)) -> Result<(Report, f64)> {
    let rive = rivecli::find()?;
    let ws = Workspace::new(Some(&bundle::pack(files)?))?;
    progress("compiling");
    let report = query(&rive, &ws, opts)?;
    if report.duration <= 0.0 {
        bail!("the song is empty: nothing plays");
    }
    progress(&format!("rendering {:.1} s", report.duration));
    let raw: PathBuf = ws.path().join("build/render.wav");
    // Room for the frames before playback starts, too.
    let ms = ((report.duration + opts.tail) * 1000.0).ceil() as u64 + 250;
    let mut args = vec![
        "--aot".to_string(),
        format!("--render-audio={}", raw.display()),
        format!("--audio-rate={}", opts.rate),
        "--audio-channels=2".into(),
    ];
    args.extend(data_args(opts));
    args.push(format!("--advance={ms}ms"));
    let (lines, _) = rivecli::run(&rive, ws.path(), &args)?;
    let bytes = fs::read(&raw).map_err(|_| {
        let problems: Vec<&str> = lines.iter().filter(|l| rivecli::is_error(l)).map(String::as_str).collect();
        anyhow::anyhow!("rive wrote no audio{}", if problems.is_empty() { String::new() } else { format!(":\n{}", problems.join("\n")) })
    })?;
    let mut audio = wav::read(&bytes).context("reading the rendered audio")?;
    // The capture starts with the processor; playback starts at the frame the
    // app reports (a frame or so later when it waited for its samples).
    let started = lines
        .iter()
        .filter_map(|l| rivecli::host_message(l))
        .find(|m| m["op"] == "started")
        .and_then(|m| m["frame"].as_f64())
        .unwrap_or(0.0)
        .max(0.0) as usize;
    audio.skip(started);
    // Keep the song, then its release until it falls silent (at most `tail` seconds).
    let song_frames = (report.duration * audio.rate as f64).ceil() as usize;
    let most = ((report.duration + opts.tail) * audio.rate as f64).ceil() as usize;
    audio.truncate(most);
    let end = audio.end_of_sound(song_frames, 1.0e-5);
    audio.truncate(end);
    let seconds = audio.seconds();
    let mut report = report;
    report.lufs = crate::loudness::integrated(&audio);
    let part = out.with_extension("wav.part");
    fs::write(&part, wav::write(&audio, opts.format)).with_context(|| format!("writing {}", part.display()))?;
    fs::rename(&part, out).with_context(|| format!("writing {}", out.display()))?;
    Ok((report, seconds))
}
