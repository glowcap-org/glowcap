//! Browser source identity for immutable production generations. Metadata
//! detects edits, additions, and removals. Content earns the bundle claim,
//! including fonts and the compiled Rust application. Prepared assets carry
//! that identity without requiring the source tree at runtime.
use sha2::{Digest, Sha256};
use std::{
	path::{Path, PathBuf},
	time::UNIX_EPOCH,
};

pub(super) struct Graph {
	entries: Vec<(String, PathBuf)>,
	pub stamp: [u8; 32],
}
impl Graph {
	pub fn scan(root: &Path) -> Result<Self, String> {
		let mut entries = Vec::new();
		for (name, path) in [
			("ui", "ui"),
			("rooms-lib", "../lib"),
			("bindings-ts", "../../../bindings/ts"),
		] {
			walk(&root.join(path), name, &mut entries)?;
		}
		for name in ["deno.json", "deno.lock", "compiler.json"] {
			entries.push((name.into(), root.join(name)));
		}
		for name in super::compiler::Recipe::read(root)?.inputs {
			let path = root.join(&name);
			entries.push((name, path));
		}
		for name in ["rooms_browser.js", "rooms_browser.d.ts", "rooms_browser_bg.wasm"] {
			entries.push((name.into(), root.join("../../../zig-out/wasm/rooms").join(name)));
		}
		entries.push(("fonts/OFL.txt".into(), root.join("../../../ui/fonts/OFL.txt")));
		entries.sort_by(|a, b| a.0.cmp(&b.0));
		let mut hash = Sha256::new();
		for (name, path) in &entries {
			let metadata = std::fs::metadata(path).map_err(|e| e.to_string())?;
			hash.update((name.len() as u64).to_be_bytes());
			hash.update(name);
			hash.update(metadata.len().to_be_bytes());
			hash.update(
				metadata
					.modified()
					.map_err(|e| e.to_string())?
					.duration_since(UNIX_EPOCH)
					.map_err(|e| e.to_string())?
					.as_nanos()
					.to_be_bytes(),
			);
		}
		Ok(Self {
			entries,
			stamp: hash.finalize().into(),
		})
	}
	pub fn version(&self) -> Result<String, String> {
		let mut hash = Sha256::new();
		// Compiler flags and inputs are hashed above. Bump only when the host
		// packaging contract changes.
		hash.update(b"rooms-browser-assets/5");
		for (name, path) in &self.entries {
			let body = std::fs::read(path).map_err(|e| e.to_string())?;
			hash.update((name.len() as u64).to_be_bytes());
			hash.update(name);
			hash.update((body.len() as u64).to_be_bytes());
			hash.update(body);
		}
		Ok(rooms_application::fields::lower_hex(&hash.finalize()))
	}
}
fn walk(directory: &Path, logical: &str, rows: &mut Vec<(String, PathBuf)>) -> Result<(), String> {
	for entry in std::fs::read_dir(directory).map_err(|e| e.to_string())? {
		let entry = entry.map_err(|e| e.to_string())?;
		let name = entry
			.file_name()
			.into_string()
			.map_err(|_| "browser source filename is not Unicode")?;
		let kind = entry.file_type().map_err(|e| e.to_string())?;
		let logical = format!("{logical}/{name}");
		if kind.is_dir() && name != "bundle" && name != "node_modules" {
			walk(&entry.path(), &logical, rows)?;
		} else if (kind.is_file() || kind.is_symlink())
			&& entry
				.path()
				.extension()
				.is_some_and(|ext| matches!(ext.to_str(), Some("css" | "html" | "js" | "ts" | "tsx" | "woff2")))
			&& std::fs::metadata(entry.path()).map_err(|e| e.to_string())?.is_file()
		{
			rows.push((logical, entry.path()));
		}
	}
	Ok(())
}
pub(super) fn revision(value: &str) -> bool {
	let digest = if let Some(digest) = value.strip_prefix("source-") {
		digest
	} else {
		value.strip_suffix("-dirty").unwrap_or(value)
	};
	digest.len() == 12 && digest.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
