//! Runs the `partition` binary (docs/spec.md §14, Shell). `check` and
//! `render` need the Rive CLI; without it (as on CI) those tests say so and pass.

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

fn partition(cache: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_partition")).args(args).env("PARTITION_CACHE", cache).output().expect("running partition")
}

fn text(o: &Output) -> String {
    format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr))
}

fn has_rive() -> bool {
    let found = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).any(|d| d.join("rive").is_file())).unwrap_or(false);
    if !found {
        eprintln!("skipped: the Rive CLI is not on PATH");
    }
    found
}

#[test]
fn lists_examples() {
    let cache = tempfile::tempdir().unwrap();
    let o = partition(cache.path(), &["examples"]);
    assert!(o.status.success());
    let out = text(&o);
    assert!(out.contains("deep-house"), "{out}");
    assert!(out.contains("empty"), "{out}");
}

#[test]
fn new_pack_unpack_round_trip() {
    let tmp = tempfile::tempdir().unwrap();
    let song = tmp.path().join("song");
    let o = partition(tmp.path(), &["new", song.to_str().unwrap(), "--template", "techno"]);
    assert!(o.status.success(), "{}", text(&o));
    assert!(song.join("song.yaml").is_file());
    assert!(song.join("conductor.ch").is_file());

    let bundle = tmp.path().join("song.song");
    let o = partition(tmp.path(), &["pack", song.to_str().unwrap(), "-o", bundle.to_str().unwrap()]);
    assert!(o.status.success(), "{}", text(&o));
    assert!(fs::read_to_string(&bundle).unwrap().starts_with("%partition-bundle 1\n"));

    let back = tmp.path().join("back");
    let o = partition(tmp.path(), &["unpack", bundle.to_str().unwrap(), "-o", back.to_str().unwrap()]);
    assert!(o.status.success(), "{}", text(&o));
    for entry in ["song.yaml", "conductor.ch", "channels/kick.ch"] {
        assert_eq!(fs::read(song.join(entry)).unwrap(), fs::read(back.join(entry)).unwrap(), "{entry}");
    }

    // A second unpack into the same folder is refused.
    let o = partition(tmp.path(), &["unpack", bundle.to_str().unwrap(), "-o", back.to_str().unwrap()]);
    assert_eq!(o.status.code(), Some(2));
    assert!(text(&o).contains("not empty"));
}

#[test]
fn refuses_unknown_songs_and_templates() {
    let tmp = tempfile::tempdir().unwrap();
    let o = partition(tmp.path(), &["check", "no-such-song"]);
    assert_eq!(o.status.code(), Some(2));
    let o = partition(tmp.path(), &["new", tmp.path().join("x").to_str().unwrap(), "--template", "nope"]);
    assert_eq!(o.status.code(), Some(2));
    let o = partition(tmp.path(), &["render", "techno", "-o", "x.wav", "--rate", "1000"]);
    assert_eq!(o.status.code(), Some(2));
}

#[test]
fn check_reports_errors_with_exit_code_one() {
    if !has_rive() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let song = tmp.path().join("song");
    assert!(partition(tmp.path(), &["new", song.to_str().unwrap()]).status.success());
    let o = partition(tmp.path(), &["check", song.to_str().unwrap()]);
    assert_eq!(o.status.code(), Some(0), "{}", text(&o));
    fs::write(song.join("conductor.ch"), "note(p: C4)\n").unwrap();
    let o = partition(tmp.path(), &["check", song.to_str().unwrap()]);
    assert_eq!(o.status.code(), Some(1), "{}", text(&o));
    assert!(text(&o).contains("conductor.ch:1:1: error"), "{}", text(&o));
}

#[test]
fn render_writes_a_wav_of_the_right_length() {
    if !has_rive() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let out = tmp.path().join("t.wav");
    let o = partition(tmp.path(), &["render", "techno", "-o", out.to_str().unwrap(), "--to", "16", "--tail", "1"]);
    assert!(o.status.success(), "{}", text(&o));
    let bytes = fs::read(&out).unwrap();
    assert_eq!(&bytes[0..4], b"RIFF");
    assert_eq!(u16::from_le_bytes([bytes[22], bytes[23]]), 2); // stereo
    assert_eq!(u32::from_le_bytes([bytes[24], bytes[25], bytes[26], bytes[27]]), 48000);
    let data = u32::from_le_bytes([bytes[40], bytes[41], bytes[42], bytes[43]]) as f64;
    let seconds = data / 4.0 / 48000.0;
    // 16 rows of the techno example: one bar, plus at most a second of release.
    assert!(seconds > 1.5 && seconds < 3.2, "{seconds} s");
    let peak = bytes[44..].as_chunks::<2>().0.iter().map(|c| i16::from_le_bytes([c[0], c[1]]).unsigned_abs()).max().unwrap();
    assert!(peak > 1000, "silent render");
}
