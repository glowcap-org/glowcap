//! The directory stand-in for a session that process tests serve against. The
//! `--rooms-dir` flag selects it, and it exists only in a build with the
//! `test-support` feature, so a release build has no flag, no directory, and
//! nothing to start. The stand-in stores no link, so its first start and its
//! later starts differ only in the settings stored.
use super::Prepared;
#[cfg(feature = "test-support")]
use super::{Serving, Start, serve};
use crate::bot::{error::Error, request::Request};
use tokio::sync::watch;

/// The flags a build with the stand-in adds to `serve`'s.
#[cfg(feature = "test-support")]
pub const FLAGS: [&str; 1] = ["rooms-dir"];
#[cfg(not(feature = "test-support"))]
pub const FLAGS: [&str; 0] = [];

/// The directory the stand-in keeps its session in. A release build has no
/// such value, so a start with one cannot be written.
#[cfg(feature = "test-support")]
pub type Directory = std::path::PathBuf;
#[cfg(not(feature = "test-support"))]
pub type Directory = std::convert::Infallible;

/// The stand-in's directory when the start asks for it.
#[cfg(feature = "test-support")]
pub fn directory(request: &Request) -> Result<Option<Directory>, Error> {
	Ok(request.single("rooms-dir")?.map(Directory::from))
}

#[cfg(not(feature = "test-support"))]
pub fn directory(_request: &Request) -> Result<Option<Directory>, Error> {
	Ok(None)
}

/// Serve against the stand-in in `directory`.
#[cfg(feature = "test-support")]
pub async fn run(directory: Directory, prepared: Prepared, shutdown: watch::Receiver<bool>) -> Result<(), Error> {
	let Prepared {
		store,
		stored,
		config,
		harness,
		facts,
		linking: _,
	} = prepared;
	crate::bot::identity::seed(&store)?;
	let rooms = crate::bot::rooms::files::Files::open(&directory);
	let start = if stored.is_none() {
		Start::First(None)
	} else {
		Start::Stored
	};
	let serving = Serving { facts, start };
	serve(&rooms, &store, stored, &config, &*harness, shutdown, serving).await
}

#[cfg(not(feature = "test-support"))]
pub async fn run(directory: Directory, _prepared: Prepared, _shutdown: watch::Receiver<bool>) -> Result<(), Error> {
	match directory {}
}
