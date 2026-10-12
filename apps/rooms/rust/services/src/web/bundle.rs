//! The host front owns the bundle claim and compiler lifetime. The app's
//! compiler recipe selects the bundler and flags without changing publication.
use super::{process::Temporary, source::Graph};
use std::{
	path::{Path, PathBuf},
	process::Stdio,
	time::Duration,
};
use tokio::{process::Command, sync::watch};

pub(super) async fn graph(root: &Path) -> Result<Graph, String> {
	let root = root.to_owned();
	tokio::task::spawn_blocking(move || Graph::scan(&root))
		.await
		.map_err(|e| e.to_string())?
}
pub(super) async fn version(graph: Graph) -> Result<String, String> {
	tokio::task::spawn_blocking(move || graph.version())
		.await
		.map_err(|e| e.to_string())?
}
pub(super) async fn build(
	root: &Path,
	before: &str,
	stop: watch::Receiver<bool>,
	parent: Option<&Path>,
) -> Result<Option<(PathBuf, Temporary)>, String> {
	if *stop.borrow() {
		return Ok(None);
	}
	let planned = Temporary::plan()?;
	let path = match parent {
		Some(parent) => parent.join(planned.file_name().ok_or("temporary path names no leaf")?),
		None => planned,
	};
	let (outdir, owner) = Temporary::create(path).await?;
	let result = compile(root, &outdir, before, stop).await;
	match result {
		Ok(true) => Ok(Some((outdir, owner))),
		Ok(false) => {
			owner.close().await?;
			Ok(None)
		}
		Err(error) => Err(crate::cleanup::failed(error, owner.close().await)),
	}
}
async fn compile(root: &Path, outdir: &Path, before: &str, mut stop: watch::Receiver<bool>) -> Result<bool, String> {
	if *stop.borrow() {
		return Ok(false);
	}
	let source = root.to_owned();
	let recipe = tokio::task::spawn_blocking(move || super::compiler::Recipe::read(&source))
		.await
		.map_err(|e| e.to_string())??;
	let mut child = Command::new("deno")
		.args(recipe.arguments(outdir)?)
		.current_dir(root)
		.stdin(Stdio::null())
		.stdout(Stdio::inherit())
		.stderr(Stdio::inherit())
		.kill_on_drop(true)
		.spawn()
		.map_err(|e| format!("starting the browser compiler failed: {e}"))?;
	let waited = tokio::select! {
		biased;
		_ = super::stopped(&mut stop) => { child.kill().await.map_err(|e| e.to_string())?; return Ok(false); },
		waited = tokio::time::timeout(Duration::from_secs(120), child.wait()) => waited,
	};
	let status = match waited {
		Ok(Ok(status)) => status,
		result => {
			let error = match result {
				Ok(Err(error)) => error.to_string(),
				_ => "browser compiler timed out".into(),
			};
			return Err(crate::cleanup::failed(
				error,
				child.kill().await.map_err(|e| e.to_string()),
			));
		}
	};
	if !status.success() {
		return Err(format!("browser compiler failed: {status}"));
	}
	let source = root.to_owned();
	let target = outdir.to_owned();
	tokio::task::spawn_blocking(move || package(&source, &target))
		.await
		.map_err(|e| e.to_string())??;
	let after = version(graph(root).await?).await?;
	if after != before {
		return Err("browser sources changed during compilation".into());
	}
	// Development builds identify the actual source state. A commit-plus-dirty
	// label cannot distinguish successive edits and therefore cannot drive
	// reliable browser refresh.
	let revision = format!("source-{}", &after[..12]);
	tokio::fs::write(outdir.join("source.version"), format!("{after}\n"))
		.await
		.map_err(|e| e.to_string())?;
	tokio::fs::write(outdir.join("revision"), format!("{revision}\n"))
		.await
		.map_err(|e| e.to_string())?;
	Ok(true)
}

/// A generation owns every served byte. Copying linked source assets happens
/// once during the build. The serving process needs neither links nor sources.
fn package(root: &Path, outdir: &Path) -> Result<(), String> {
	let copy = |from: &Path, to: &Path| {
		let bytes = super::assets::read(from, 64 * 1024 * 1024)?;
		std::fs::write(to, bytes).map_err(|e| e.to_string())
	};
	copy(&root.join("ui/page.html"), &outdir.join("page.html"))?;
	copy(
		&root.join("../../../zig-out/wasm/rooms/rooms_browser_bg.wasm"),
		&outdir.join("rooms_browser_bg.wasm"),
	)?;
	std::fs::create_dir(outdir.join("fonts")).map_err(|e| e.to_string())?;
	copy(&root.join("../../../ui/fonts/OFL.txt"), &outdir.join("fonts/OFL.txt"))?;
	for (source, destination, extension) in [("ui", "", "css"), ("ui/fonts", "fonts", "woff2")] {
		for entry in std::fs::read_dir(root.join(source)).map_err(|e| e.to_string())? {
			let entry = entry.map_err(|e| e.to_string())?;
			if entry.path().extension().is_some_and(|ext| ext == extension) {
				copy(&entry.path(), &outdir.join(destination).join(entry.file_name()))?;
			}
		}
	}
	Ok(())
}
