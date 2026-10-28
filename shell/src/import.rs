//! Importing sample files (docs/spec.md §10.11): the app's Import button asks
//! the shell, which can read the disk. A native dialog picks the files; WAV
//! files are copied as they are, and on macOS other audio files (AIFF, MP3,
//! M4A, CAF, FLAC) are converted with `afconvert`.

use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};

/// Asks the user for audio files. An empty list when they cancel.
pub fn pick_files() -> Result<Vec<PathBuf>> {
    let output = if cfg!(target_os = "macos") {
        Command::new("osascript")
            .args([
                "-e",
                "set fs to choose file with prompt \"Import samples into Partition\" of type {\"public.audio\"} with multiple selections allowed",
                "-e",
                "set out to \"\"",
                "-e",
                "repeat with f in fs",
                "-e",
                "set out to out & POSIX path of f & linefeed",
                "-e",
                "end repeat",
                "-e",
                "return out",
            ])
            .output()
            .context("opening the file dialog (osascript)")?
    } else {
        Command::new("zenity")
            .args([
                "--file-selection",
                "--multiple",
                "--separator=\n",
                "--title=Import samples into Partition",
                "--file-filter=Audio | *.wav *.WAV *.aif *.aiff *.mp3 *.m4a *.flac",
            ])
            .output()
            .context("opening the file dialog (zenity); copy WAV files into the song's samples/ folder instead")?
    };
    // Cancelling exits with an error status and prints nothing useful.
    if !output.status.success() {
        return Ok(Vec::new());
    }
    Ok(String::from_utf8_lossy(&output.stdout).lines().map(str::trim).filter(|l| !l.is_empty()).map(PathBuf::from).collect())
}

fn is_wav(bytes: &[u8]) -> bool {
    bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WAVE"
}

/// The file as WAV bytes: as it is, or converted (macOS).
pub fn to_wav(path: &Path) -> Result<Vec<u8>> {
    let bytes = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
    if is_wav(&bytes) {
        return Ok(bytes);
    }
    if !cfg!(target_os = "macos") {
        bail!("{} is not a WAV file; convert it to WAV first", path.display());
    }
    let out = std::env::temp_dir().join(format!("partition-import-{}.wav", std::process::id()));
    let status = Command::new("afconvert")
        .arg("-f")
        .arg("WAVE")
        .arg("-d")
        .arg("LEI16")
        .arg(path)
        .arg(&out)
        .status()
        .context("converting with afconvert")?;
    if !status.success() {
        bail!("{} could not be converted to WAV", path.display());
    }
    let converted = std::fs::read(&out).with_context(|| format!("reading {}", out.display()))?;
    std::fs::remove_file(&out).ok();
    if !is_wav(&converted) {
        bail!("{} did not convert to WAV", path.display());
    }
    Ok(converted)
}

/// A sample name from a file name: lowercase letters, digits and '_',
/// starting with a letter, and not one of `taken`.
pub fn sample_name(path: &Path, taken: &dyn Fn(&str) -> bool) -> String {
    let stem = path.file_stem().unwrap_or_default().to_string_lossy().to_lowercase();
    let mut name = String::new();
    for c in stem.chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            name.push(c);
        } else if !name.is_empty() && !name.ends_with('_') {
            name.push('_');
        }
    }
    let mut name = name.trim_end_matches('_').to_string();
    if !name.starts_with(|c: char| c.is_ascii_lowercase()) {
        name = format!("s_{name}").trim_end_matches('_').to_string();
    }
    let base = name.clone();
    let mut n = 2;
    while taken(&name) {
        name = format!("{base}_{n}");
        n += 1;
    }
    name
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_from_files() {
        let none = |_: &str| false;
        assert_eq!(sample_name(Path::new("/x/Big Kick-02.wav"), &none), "big_kick_02");
        assert_eq!(sample_name(Path::new("909 hat.aif"), &none), "s_909_hat");
        assert_eq!(sample_name(Path::new("---.wav"), &none), "s");
        let taken = |n: &str| n == "snare" || n == "snare_2";
        assert_eq!(sample_name(Path::new("Snare.wav"), &taken), "snare_3");
    }

    #[test]
    fn wav_files_pass_through() {
        let dir = tempfile::tempdir().unwrap();
        let wav = dir.path().join("a.wav");
        std::fs::write(&wav, b"RIFF\0\0\0\0WAVEdata").unwrap();
        assert_eq!(to_wav(&wav).unwrap(), b"RIFF\0\0\0\0WAVEdata");
    }
}
