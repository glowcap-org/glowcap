//! Build immutable browser generations and atomically select one for serving.
//! The publication pointer changes only after every asset passes admission.
use super::{assets::Generation, bundle, process::Temporary};
use std::{future::Future, path::PathBuf};
use tokio::sync::watch;

pub struct Preparation {
	source: PathBuf,
	output: PathBuf,
}
impl Preparation {
	pub fn parse(args: &[String]) -> Result<Option<Self>, String> {
		let Some(first) = args.first() else { return Ok(None) };
		let output = if first == "--prepare" {
			"zig-out/rooms-web"
		} else if let Some(path) = first.strip_prefix("--prepare=").filter(|s| !s.is_empty()) {
			path
		} else {
			return Ok(None);
		};
		let source = match &args[1..] {
			[] => "apps/rooms/web",
			[option] => option
				.strip_prefix("--assets=")
				.filter(|s| !s.is_empty())
				.ok_or("browser preparation accepts only --assets=<source-directory>")?,
			_ => return Err("browser preparation accepts only --assets=<source-directory>".into()),
		};
		Ok(Some(Self {
			source: source.into(),
			output: output.into(),
		}))
	}
	pub async fn run(self, halt: impl Future<Output = ()>) -> Result<Option<PathBuf>, String> {
		let (stop, stopping) = watch::channel(false);
		let work = self.prepare(stopping);
		tokio::pin!(work, halt);
		tokio::select! {
			result = &mut work => result,
			_ = &mut halt => { stop.send_replace(true); work.await }
		}
	}
	async fn prepare(self, stop: watch::Receiver<bool>) -> Result<Option<PathBuf>, String> {
		let before = bundle::version(bundle::graph(&self.source).await?).await?;
		if *stop.borrow() {
			return Ok(None);
		}
		tokio::fs::create_dir_all(&self.output)
			.await
			.map_err(|e| e.to_string())?;
		let output = tokio::fs::canonicalize(&self.output).await.map_err(|e| e.to_string())?;
		let name = format!("generation-{before}");
		let destination = output.join(&name);
		let existing = match tokio::fs::metadata(&destination).await {
			Ok(metadata) if metadata.is_dir() => true,
			Ok(_) => return Err("browser generation destination is not a directory".into()),
			Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
			Err(error) => return Err(error.to_string()),
		};
		let staged = if existing {
			None
		} else {
			let Some((path, owner)) = bundle::build(&self.source, &before, stop.clone(), Some(&output)).await? else {
				return Ok(None);
			};
			Some((path, owner))
		};
		let (path, mut owner) = match staged {
			Some((path, owner)) => (path, Some(owner)),
			None => (destination.clone(), None),
		};
		let checked = tokio::task::spawn_blocking(move || Generation::load(&path).map(drop))
			.await
			.map_err(|e| e.to_string())
			.and_then(|r| r);
		let publishing = async {
			checked?;
			if *stop.borrow() {
				return Ok(None);
			}
			if let Some(owner) = &mut owner {
				owner.relocate(destination).await?;
			}
			let planned = Temporary::plan()?;
			let scratch = output.join(planned.file_name().ok_or("temporary path names no leaf")?);
			let (scratch, cleanup) = Temporary::create(scratch).await?;
			let pointer = scratch.join("current");
			let current = output.join("current");
			let published = async {
				tokio::fs::symlink(name, &pointer).await.map_err(|e| e.to_string())?;
				tokio::fs::rename(&pointer, &current).await.map_err(|e| e.to_string())?;
				if let Some(owner) = owner.take() {
					owner.persist();
				}
				Ok(())
			}
			.await;
			crate::cleanup::combine(published, cleanup.close().await)?;
			Ok(Some(current))
		}
		.await;
		let cleanup = match owner {
			Some(owner) => owner.close().await,
			None => Ok(()),
		};
		match publishing {
			Ok(path) => cleanup.map(|()| path),
			Err(error) => Err(crate::cleanup::failed(error, cleanup)),
		}
	}
}
