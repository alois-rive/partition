//! `partition`: the native shell around the Partition app (docs/spec.md §12).
//! It opens songs from disk in a window, keeps them saved, and renders and
//! checks them headless. The app itself runs on the Rive CLI.

mod bundle;
mod host;
mod project;
mod render;
mod rivecli;
mod songdir;
mod wav;

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand, ValueEnum};

use crate::bundle::SongFile;
use crate::render::RenderOptions;
use crate::songdir::SongSource;

#[derive(Parser)]
#[command(name = "partition", version, about = "Compose, play and record music written as text.")]
#[command(args_conflicts_with_subcommands = true)]
struct Cli {
    /// A song folder or .song bundle to open (default: the last one opened, else the examples).
    song: Option<PathBuf>,
    /// Save only on Cmd+S instead of after every edit.
    #[arg(long)]
    no_autosave: bool,
    /// Print the runtime's log.
    #[arg(long, short)]
    verbose: bool,
    #[command(subcommand)]
    command: Option<Cmd>,
}

#[derive(Clone, Copy, ValueEnum)]
enum FormatArg {
    Pcm16,
    Float32,
}

#[derive(Subcommand)]
enum Cmd {
    /// Create a song folder from a template.
    New {
        dir: PathBuf,
        /// An example id (see `partition examples`).
        #[arg(long, default_value = "empty")]
        template: String,
    },
    /// List the embedded examples.
    Examples,
    /// Render a song to a WAV file, headless.
    Render {
        /// A song folder, a .song bundle, or an example id.
        song: String,
        #[arg(short, long)]
        output: PathBuf,
        /// Sample rate: 44100, 48000 or 96000.
        #[arg(long, default_value_t = 48000)]
        rate: u32,
        #[arg(long, value_enum, default_value_t = FormatArg::Pcm16)]
        format: FormatArg,
        /// Extra passes of each endless loop.
        #[arg(long, default_value_t = 1)]
        loops: u32,
        /// First row to play.
        #[arg(long, default_value_t = 0)]
        from: u32,
        /// Last row to play (0: to the end).
        #[arg(long, default_value_t = 0)]
        to: u32,
        /// Most seconds of release kept after the end.
        #[arg(long, default_value_t = 8.0)]
        tail: f64,
    },
    /// Print a song's diagnostics; exit 1 if it has errors.
    Check {
        /// A song folder, a .song bundle, or an example id.
        song: String,
    },
    /// Pack a song folder into a .song bundle.
    Pack {
        dir: PathBuf,
        #[arg(short, long)]
        output: PathBuf,
    },
    /// Unpack a .song bundle into a folder.
    Unpack {
        file: PathBuf,
        #[arg(short, long)]
        output: PathBuf,
    },
}

/// A song to read: a folder, a bundle, or the id of an embedded example.
fn song_files(arg: &str) -> Result<Vec<SongFile>> {
    let path = Path::new(arg);
    if path.exists() {
        return SongSource::from_arg(path)?.read();
    }
    if let Some(example) = project::example(arg) {
        return example.files();
    }
    bail!("{arg}: no such song folder, .song bundle or example")
}

fn last_song() -> Option<SongSource> {
    let text = std::fs::read_to_string(project::cache_dir().join("last-song")).ok()?;
    SongSource::from_arg(Path::new(text.trim())).ok()
}

fn run(cli: Cli) -> Result<u8> {
    let Some(command) = cli.command else {
        let source = match &cli.song {
            Some(p) => Some(SongSource::from_arg(p)?),
            None => last_song(),
        };
        let code = host::open(source, host::OpenOptions { autosave: !cli.no_autosave, verbose: cli.verbose })?;
        return Ok(code.clamp(0, 255) as u8);
    };
    match command {
        Cmd::New { dir, template } => {
            let example =
                project::example(&template).with_context(|| format!("no template named '{template}' (see `partition examples`)"))?;
            songdir::write_song(&dir, &example.files()?)?;
            println!("created {} from '{}'; open it with: partition {}", dir.display(), example.title, dir.display());
        }
        Cmd::Examples => {
            for e in project::examples() {
                println!("{:<14} {:>4} bpm  {}", e.id, e.bpm, e.title);
            }
        }
        Cmd::Render { song, output, rate, format, loops, from, to, tail } => {
            if ![44100, 48000, 96000].contains(&rate) {
                bail!("--rate is 44100, 48000 or 96000");
            }
            let files = song_files(&song)?;
            let opts = RenderOptions {
                rate,
                format: match format {
                    FormatArg::Pcm16 => wav::Format::Pcm16,
                    FormatArg::Float32 => wav::Format::Float32,
                },
                loops,
                from,
                to,
                tail: tail.max(0.0),
            };
            let (report, seconds) = render::render(&files, &output, &opts, |step| eprintln!("partition: {step}"))?;
            for d in &report.diagnostics {
                eprintln!("{d}");
            }
            println!("wrote {} ({seconds:.1} s, {} Hz)", output.display(), rate);
        }
        Cmd::Check { song } => {
            let report = render::check(&song_files(&song)?)?;
            for d in &report.diagnostics {
                println!("{d}");
            }
            let errors = report.errors();
            let warnings = report.diagnostics.len() - errors;
            println!("{}: {errors} error(s), {warnings} warning(s), {:.1} s", report.title, report.duration);
            return Ok(if errors > 0 { 1 } else { 0 });
        }
        Cmd::Pack { dir, output } => {
            let files = songdir::read_dir(&dir)?;
            songdir::write_atomic(&output, &bundle::pack(&files)?)?;
            println!("packed {} files into {}", files.len(), output.display());
        }
        Cmd::Unpack { file, output } => {
            let text = std::fs::read_to_string(&file).with_context(|| format!("reading {}", file.display()))?;
            let files = bundle::parse(&file.to_string_lossy(), &text)?;
            songdir::write_song(&output, &files)?;
            println!("unpacked {} files into {}", files.len(), output.display());
        }
    }
    Ok(0)
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            eprintln!("partition: {e:#}");
            ExitCode::from(2)
        }
    }
}
