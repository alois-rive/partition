//! The `rive` CLI, which runs the app: the window (its previewer) and the
//! headless runs behind `render` and `check`. The app talks back through its
//! log: one `PARTITION-HOST <json>` line per message (docs/spec.md §12.2).

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::Sender;
use std::thread;

use anyhow::{Context, Result, bail};
use serde_json::Value;

const MARK: &str = "PARTITION-HOST ";

/// The `rive` binary: `PARTITION_RIVE`, else `rive` on PATH, else ~/.rive/bin/rive.
pub fn find() -> Result<PathBuf> {
    if let Some(p) = std::env::var_os("PARTITION_RIVE") {
        let p = PathBuf::from(p);
        if p.is_file() {
            return Ok(p);
        }
        bail!("PARTITION_RIVE is {}, which is not a file", p.display());
    }
    if let Some(paths) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&paths) {
            let p = dir.join("rive");
            if p.is_file() {
                return Ok(p);
            }
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        let p = PathBuf::from(home).join(".rive/bin/rive");
        if p.is_file() {
            return Ok(p);
        }
    }
    bail!(
        "Partition runs on the Rive CLI, and `rive` was not found. Install it, put it on PATH (or set PARTITION_RIVE), and sign in with `rive login`."
    )
}

/// A message from the app, if `line` carries one.
pub fn host_message(line: &str) -> Option<Value> {
    let i = line.find(MARK)?;
    serde_json::from_str(&line[i + MARK.len()..]).ok()
}

/// Whether a log line reports a script or build error.
pub fn is_error(line: &str) -> bool {
    line.contains("] error ") || line.contains(" error   :") || line.contains("errors,") && !line.contains(" 0 errors,")
}

/// A line of output from a running `rive`, from stdout or stderr.
pub enum Output {
    Line(String),
    Exited(Option<i32>),
}

/// Starts `rive <workspace> args…`, sending every output line to `to`.
pub fn spawn(rive: &Path, workspace: &Path, args: &[String], to: Sender<Output>) -> Result<std::process::Child> {
    let mut child = Command::new(rive)
        .arg(workspace)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("starting {}", rive.display()))?;
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let out = to.clone();
    thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if out.send(Output::Line(line)).is_err() {
                break;
            }
        }
    });
    thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            if to.send(Output::Line(line)).is_err() {
                break;
            }
        }
    });
    Ok(child)
}

/// Runs `rive <workspace> args…` to the end: its output lines and exit code.
pub fn run(rive: &Path, workspace: &Path, args: &[String]) -> Result<(Vec<String>, Option<i32>)> {
    let output = Command::new(rive)
        .arg(workspace)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .with_context(|| format!("running {}", rive.display()))?;
    let mut lines: Vec<String> = String::from_utf8_lossy(&output.stdout).lines().map(str::to_string).collect();
    lines.extend(String::from_utf8_lossy(&output.stderr).lines().map(str::to_string));
    Ok((lines, output.status.code()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_messages_from_log_lines() {
        let line = r#"[16:07:19.564] console :0  PARTITION-HOST {"op":"write","path":"a.ch","text":"x\n\ty \"q\""}"#;
        let m = host_message(line).unwrap();
        assert_eq!(m["op"], "write");
        assert_eq!(m["text"], "x\n\ty \"q\"");
        assert!(host_message("[t] console :0  partition: loaded").is_none());
        assert!(host_message("PARTITION-HOST {broken").is_none());
    }

    #[test]
    fn spots_errors() {
        assert!(is_error("[16:03:52.883] error   :0  script error: execution exceeded 200 millisecond timeout"));
        assert!(!is_error("[t] rive  built build/partition.riv (1 bytes, 1ms, 0 errors, 0 warnings)"));
        assert!(is_error("[t] rive  built build/partition.riv (1 bytes, 1ms, 2 errors, 0 warnings)"));
    }
}
