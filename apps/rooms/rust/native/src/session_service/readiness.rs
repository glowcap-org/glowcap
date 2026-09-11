//! The administrator sturdyref mirror. It is readiness evidence for an
//! operator and a healthcheck, never a second authority: a prior incarnation's
//! file is cleared before any work that can fail, and the exact published
//! sturdyref is installed only after the durable owner, listener, grants, and
//! administrator publication are all admitted. Every touch of the file runs
//! on a blocking thread, like every other disk write the peer makes.
use super::error::Error;
use rooms_application::documents::WriteFailure;
use std::path::{Path, PathBuf};

pub struct Readiness {
	path: PathBuf,
}

impl Readiness {
	/// Claim the path by clearing whatever a previous incarnation left there.
	pub async fn clear(path: PathBuf) -> Result<Self, Error> {
		blocking({
			let path = path.clone();
			move || remove(&path)
		})
		.await?;
		Ok(Self { path })
	}
	/// Install the published sturdyref durably, so a healthcheck that reads it
	/// after a crash sees either the whole link or nothing.
	pub async fn publish(&self, link: &str) -> Result<(), Error> {
		let path = self.path.clone();
		let line = format!("{link}\n");
		blocking(move || {
			let directory = path.parent().unwrap_or_else(|| Path::new("."));
			let name = path
				.file_name()
				.and_then(|name| name.to_str())
				.ok_or_else(|| Error::refused("the readiness file needs a file name"))?;
			std::fs::create_dir_all(directory).map_err(Error::io("readiness directory"))?;
			crate::storage::atomic::replace_at(directory, name, core::iter::once(line.as_bytes())).map_err(|failure| {
				match failure {
					WriteFailure::Unchanged(e) | WriteFailure::Indeterminate(e) => Error::from(e),
				}
			})
		})
		.await
	}
	pub async fn remove(&self) -> Result<(), Error> {
		let path = self.path.clone();
		blocking(move || remove(&path)).await
	}
}

async fn blocking(work: impl FnOnce() -> Result<(), Error> + Send + 'static) -> Result<(), Error> {
	tokio::task::spawn_blocking(work)
		.await
		.map_err(|join| Error::runtime(format!("the readiness file worker failed: {join}")))?
}

fn remove(path: &Path) -> Result<(), Error> {
	match std::fs::remove_file(path) {
		Ok(()) => Ok(()),
		Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
		Err(e) => Err(Error::io("readiness file removal")(e)),
	}
}
