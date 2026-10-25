use std::path::Path;
use std::time::SystemTime;

/// Directories and files whose contents end up inside the Elixir release —
/// the portable QEMU (`qemu/`, from `mix qemu.fetch`) included.
/// Anything newer than the staging stamp means the bundle would ship stale
/// code or assets.
const WATCHED: &[&str] = &[
    "lib", "assets", "config", "priv/static", "qemu", "qemu-esp", "mix.exs", "mix.lock",
];

fn main() {
    check_release_is_current();
    tauri_build::build()
}

/// Fails the build when the staged Elixir release is older than the sources.
///
/// `cargo tauri build` copies `resources/` verbatim and has no idea the
/// Elixir app exists, so editing a LiveView and rebuilding produces an
/// installer carrying the previous release, with nothing to indicate it.
/// That is a silent wrong artifact — worth stopping the build over.
fn check_release_is_current() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let stamp = root.join("resources/staged_at");

    let staged_at = match modified(&stamp) {
        Some(time) => time,
        None => {
            panic!(
                "\n\nA release do Elixir não foi montada.\n\
                 Rode antes de compilar:\n\n    MIX_ENV=prod mix desktop.stage\n"
            )
        }
    };

    let project = root.parent().expect("src-tauri deve ter um diretório pai");
    let mut stale = Vec::new();

    for entry in WATCHED {
        let path = project.join(entry);
        if let Some(newest) = newest_under(&path) {
            if newest > staged_at {
                stale.push(*entry);
            }
        }
    }

    if !stale.is_empty() {
        panic!(
            "\n\nA release staged está mais velha que os fontes: {}.\n\
             O bundle sairia com a versão anterior do app. Rode:\n\n\
             \x20   MIX_ENV=prod mix desktop.stage\n",
            stale.join(", ")
        );
    }

    // Re-run this check when anything watched changes, so a stale bundle is
    // caught on the next build instead of the next release.
    for entry in WATCHED {
        println!("cargo:rerun-if-changed=../{entry}");
    }
    println!("cargo:rerun-if-changed=resources/staged_at");
}

fn modified(path: &Path) -> Option<SystemTime> {
    path.metadata().ok()?.modified().ok()
}

fn newest_under(path: &Path) -> Option<SystemTime> {
    if path.is_file() {
        return modified(path);
    }

    let mut newest: Option<SystemTime> = None;

    for entry in std::fs::read_dir(path).ok()?.flatten() {
        let child = entry.path();

        // Assets pull in a node_modules the size of the rest of the project
        // combined, and nothing in it reaches the release except through
        // files we already watch.
        if child.file_name().is_some_and(|name| name == "node_modules") {
            continue;
        }

        let candidate = if child.is_dir() {
            newest_under(&child)
        } else {
            modified(&child)
        };

        newest = match (newest, candidate) {
            (Some(a), Some(b)) => Some(a.max(b)),
            (a, b) => a.or(b),
        };
    }

    newest
}
