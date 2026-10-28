// Embeds the Rive project (../rive) in the binary: the shell writes it out and
// runs it with the `rive` CLI (docs/spec.md §12.3). Only the sources the CLI
// builds from are taken: rive.yaml, scene.rml, src/ and assets/.

use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};

fn collect(root: &Path, dir: &Path, out: &mut Vec<PathBuf>) {
    let mut entries: Vec<_> =
        fs::read_dir(dir).unwrap_or_else(|e| panic!("reading {}: {e}", dir.display())).map(|e| e.unwrap().path()).collect();
    entries.sort();
    for path in entries {
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        if path.is_dir() {
            collect(root, &path, out);
        } else {
            out.push(path.strip_prefix(root).unwrap().to_path_buf());
        }
    }
}

// FNV-1a: a stable key for the cache folder the project is written to.
fn fnv(hash: &mut u64, bytes: &[u8]) {
    for b in bytes {
        *hash ^= *b as u64;
        *hash = hash.wrapping_mul(0x100000001b3);
    }
}

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let root = manifest.join("../rive").canonicalize().expect("the Rive project at ../rive");
    let mut files = vec![PathBuf::from("rive.yaml"), PathBuf::from("scene.rml")];
    collect(&root, &root.join("src"), &mut files);
    collect(&root, &root.join("assets"), &mut files);

    let mut hash: u64 = 0xcbf29ce484222325;
    let mut code = String::from("pub static FILES: &[(&str, &[u8])] = &[\n");
    for rel in &files {
        let abs = root.join(rel);
        let bytes = fs::read(&abs).unwrap_or_else(|e| panic!("reading {}: {e}", abs.display()));
        let rel = rel.to_string_lossy().replace('\\', "/");
        fnv(&mut hash, rel.as_bytes());
        fnv(&mut hash, &bytes);
        writeln!(code, "    ({rel:?}, include_bytes!({:?})),", abs.to_string_lossy()).unwrap();
    }
    code.push_str("];\n");
    writeln!(code, "pub const HASH: &str = \"{hash:016x}\";").unwrap();
    let out = PathBuf::from(env::var("OUT_DIR").unwrap()).join("project.rs");
    fs::write(out, code).unwrap();

    for dir in ["rive.yaml", "scene.rml", "src", "assets"] {
        println!("cargo:rerun-if-changed={}", root.join(dir).display());
    }
}
