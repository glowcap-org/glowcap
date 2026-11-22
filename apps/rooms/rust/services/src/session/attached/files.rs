//! File bytes between local paths and a session. A fetch ends with the whole
//! file at its destination or with nothing there. A source is a regular file
//! read in bounded spans, never assembled in memory.
use super::{Attachment, Error};
use rooms_application::{
	content::session::uploads::{Description, Intent, Kind as Upload},
	fields::List,
	files::{CHUNK_BYTES, FileDescription},
	room::line::MAX_MESSAGE_FILES,
};
use rooms_glowcap::client::sources::{Reader, Source};
use std::{
	future::Future,
	os::unix::fs::FileExt,
	path::{Path, PathBuf},
	pin::Pin,
	sync::Arc,
};
use tokio::io::AsyncWriteExt;

/// One regular file, read at the offsets the receiver asks for.
struct Local(Arc<std::fs::File>);
impl Reader for Local {
	fn read(&self, offset: usize, length: usize) -> Pin<Box<dyn Future<Output = Result<Vec<u8>, String>>>> {
		let file = self.0.clone();
		Box::pin(async move {
			tokio::task::spawn_blocking(move || {
				let mut bytes = vec![0; length];
				file.read_exact_at(&mut bytes, offset as u64)
					.map(|()| bytes)
					.map_err(|error| error.to_string())
			})
			.await
			.map_err(|error| error.to_string())?
		})
	}
}
/// The media type a receiver shows. Unknown extensions stay opaque bytes.
fn mime(name: &str) -> &'static str {
	match Path::new(name)
		.extension()
		.and_then(|extension| extension.to_str())
		.map(str::to_ascii_lowercase)
		.as_deref()
	{
		Some("png") => "image/png",
		Some("jpg" | "jpeg") => "image/jpeg",
		Some("gif") => "image/gif",
		Some("webp") => "image/webp",
		Some("txt" | "md") => "text/plain",
		Some("json") => "application/json",
		Some("pdf") => "application/pdf",
		_ => "application/octet-stream",
	}
}
/// One open regular file to post, under the name a receiver sees. The caller
/// decides which file is opened, so a caller that confines what it sends opens
/// the file itself and hands it over here.
pub struct Outgoing {
	name: String,
	file: Arc<std::fs::File>,
}
impl Outgoing {
	/// Open the file at `path`, following links, and name it by its last
	/// component.
	pub fn open(path: &Path) -> Result<Self, Error> {
		let name = path
			.file_name()
			.and_then(|name| name.to_str())
			.ok_or_else(|| Error::Input(format!("{} has no usable file name", path.display())))?;
		Ok(Self::new(name, std::fs::File::open(path)?))
	}
	/// A file the caller already opened.
	pub fn new(name: &str, file: std::fs::File) -> Self {
		Self {
			name: name.into(),
			file: Arc::new(file),
		}
	}
	fn source(&self) -> Result<Source, Error> {
		let metadata = self.file.metadata()?;
		if !metadata.is_file() {
			return Err(Error::Input(format!("{} is not a regular file", self.name)));
		}
		let description = FileDescription::parse(&self.name, mime(&self.name), metadata.len(), 0, 0)
			.map_err(|error| Error::Input(format!("{}: {error:?}", self.name)))?;
		Ok(Source::reader(description, Local(self.file.clone())))
	}
}
/// The sources and the canonical intent that describes them.
pub(super) fn intent(
	operation: &str,
	base: u64,
	conversation: &str,
	caption: &str,
	outgoing: &[Outgoing],
) -> Result<(Intent, Vec<Source>), Error> {
	if outgoing.is_empty() || outgoing.len() > MAX_MESSAGE_FILES {
		return Err(Error::Input(format!(
			"a message carries one to {MAX_MESSAGE_FILES} files"
		)));
	}
	let sources = outgoing.iter().map(Outgoing::source).collect::<Result<Vec<_>, _>>()?;
	let files = sources
		.iter()
		.map(|source| Description::from_file(source.description()))
		.collect();
	let intent = Intent {
		upload: Upload::Post,
		operation: operation.into(),
		base,
		conversation: conversation.into(),
		caption: caption.into(),
		previews: "[]".into(),
		keep: List::default(),
		files: List::new(files).ok_or_else(|| Error::Input("too many files".into()))?,
	};
	Ok((intent, sources))
}
pub(super) fn description(file: &Attachment) -> Result<FileDescription, Error> {
	FileDescription::parse(
		&file.name,
		&file.mime,
		file.size as u64,
		file.width.into(),
		file.height.into(),
	)
	.map_err(|error| Error::Input(format!("{}: {error:?}", file.name)))
}
/// A hidden sibling of `destination`, so the final step stays on one
/// filesystem and an interrupted fetch leaves a name nobody mistakes for it.
fn sibling(destination: &Path) -> Result<PathBuf, Error> {
	let name = destination
		.file_name()
		.ok_or_else(|| Error::Input("the destination names no file".into()))?;
	let mut part = std::ffi::OsString::from(".");
	part.push(name);
	part.push(format!(".{}.part", std::process::id()));
	Ok(destination.with_file_name(part))
}
/// Write what `read` yields, span by span, to `destination`. `read` takes an
/// offset and returns the next span. An existing destination is refused before
/// any byte is written and again at the final step. Failure removes the
/// partial sibling.
pub(super) async fn write<F>(
	destination: &Path,
	size: usize,
	mut read: impl FnMut(u64, usize) -> F,
) -> Result<(), Error>
where
	F: Future<Output = Result<Vec<u8>, Error>>,
{
	if tokio::fs::symlink_metadata(destination).await.is_ok() {
		return Err(Error::Exists(destination.into()));
	}
	let part = sibling(destination)?;
	let mut file = tokio::fs::OpenOptions::new()
		.write(true)
		.create_new(true)
		.open(&part)
		.await?;
	let written = async {
		let mut offset = 0;
		while offset < size {
			let bytes = read(offset as u64, CHUNK_BYTES.min(size - offset)).await?;
			file.write_all(&bytes).await?;
			offset += bytes.len();
		}
		file.sync_all().await?;
		// A hard link fails when the destination appeared meanwhile, where a
		// rename would replace it.
		tokio::fs::hard_link(&part, destination)
			.await
			.map_err(|error| match error.kind() {
				std::io::ErrorKind::AlreadyExists => Error::Exists(destination.into()),
				_ => Error::Io(error),
			})
	}
	.await;
	drop(file);
	// best-effort: a sibling that cannot be removed stays hidden beside the
	// destination and the caller still receives the exact failure or success.
	let _ = tokio::fs::remove_file(&part).await;
	written
}
