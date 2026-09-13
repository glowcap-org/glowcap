//! Capture begins at admission. Completed immutable chunks share their original
//! allocations with disk writes; wire replies copy only the requested span.
use super::*;
use crate::archive::{Chunk, Source};
use rooms_application::files::{CHUNK_BYTES, FileDescription};
use rooms_glowcap::client::files::capture::Captured as Bytes;
use std::{future::Future, pin::Pin};
use tokio::task::JoinSet;
pub const MAX_STREAMS: usize = 32;
pub(super) struct Capture {
	tasks: JoinSet<(usize, Result<Captured, Error>)>,
	count: usize,
}
pub(super) struct Captured {
	bytes: Storage,
	_permit: Rc<Permit>,
}
enum Storage {
	Live(Bytes),
	Views(crate::files::media_files::Materialized),
}
impl Storage {
	fn description(&self) -> &FileDescription {
		match self {
			Self::Live(v) => v.description(),
			Self::Views(v) => v.description(),
		}
	}
	/// A span outside the captured bytes is the caller's mistake; the bytes
	/// themselves are all here.
	fn span(&self, offset: u64, length: usize) -> Result<Chunk, Error> {
		match self {
			Self::Live(v) => v.span(offset, length).map_err(Error::invalid),
			Self::Views(v) => v.span(offset, length),
		}
	}
}
struct Stream(Rc<Cell<usize>>);
impl Drop for Stream {
	fn drop(&mut self) {
		self.0.set(self.0.get() - 1);
	}
}
pub(super) fn overhead<P: Platform>(sources: &Sources<P>) -> usize {
	sources
		.descriptions()
		.fold(core::mem::size_of::<Capture>(), |bytes, description| {
			bytes
				.saturating_add(description.retained_bytes())
				.saturating_add(core::mem::size_of::<Captured>())
				.saturating_add(
					description.size().div_ceil(CHUNK_BYTES)
						* (core::mem::size_of::<Arc<Box<[u8]>>>()
							+ core::mem::size_of::<Box<[u8]>>()
							+ 2 * core::mem::size_of::<usize>()),
				)
		})
}
impl Capture {
	pub fn start<P: Platform>(sources: Sources<P>, permit: Rc<Permit>, active: Rc<Cell<usize>>) -> Self {
		let count = sources.len();
		let mut capture = Self {
			tasks: JoinSet::new(),
			count,
		};
		match sources {
			Sources::Live(files) => {
				for (index, file) in files.into_iter().enumerate() {
					capture.push(index, Captured::read_source(file, permit.clone()), active.clone());
				}
			}
			Sources::Views(files) => {
				for (index, file) in files.into_iter().enumerate() {
					// Pin now, before task polling or a later withdrawal can expire
					// the view. No second source read or file-buffer copy is needed.
					let materialized = file.materialize();
					let permit = permit.clone();
					capture.push(
						index,
						async move {
							Ok(Captured {
								bytes: Storage::Views(materialized.await?),
								_permit: permit,
							})
						},
						active.clone(),
					);
				}
			}
		}
		capture
	}
	fn push(
		&mut self,
		index: usize,
		work: impl Future<Output = Result<Captured, Error>> + 'static,
		active: Rc<Cell<usize>>,
	) {
		active.set(active.get() + 1);
		let stream = Stream(active);
		self.tasks.spawn_local(async move {
			let _stream = stream;
			(index, work.await)
		});
	}
	pub async fn discard(mut self) {
		self.tasks.abort_all();
		while self.tasks.join_next().await.is_some() {}
	}
	pub async fn finish(mut self) -> Result<Vec<Captured>, Error> {
		let mut files: Vec<_> = (0..self.count).map(|_| None).collect();
		let mut failure = None;
		while let Some(result) = self.tasks.join_next().await {
			match result {
				Ok((index, Ok(file))) => files[index] = Some(file),
				result => {
					if failure.is_none() {
						failure = Some(match result {
							Ok((_, Err(error))) => error,
							Err(error) => Error::closed(error.to_string()),
							_ => unreachable!(),
						});
						self.tasks.abort_all();
					}
				}
			}
		}
		if let Some(error) = failure {
			return Err(error);
		}
		Ok(files
			.into_iter()
			.map(|file| file.expect("every capture completed"))
			.collect())
	}
}
impl Captured {
	async fn read_source<P: Platform>(source: File<P>, permit: Rc<Permit>) -> Result<Self, Error> {
		Ok(Self {
			bytes: Storage::Live(Bytes::read(&source).await.map_err(Error::closed)?),
			_permit: permit,
		})
	}
	fn span(&self, offset: u64, maximum: usize) -> Result<Chunk, Error> {
		self.bytes.span(offset, maximum)
	}
	pub fn into_source(self) -> rooms_glowcap::client::sources::Source {
		rooms_glowcap::client::sources::Source::reader(self.bytes.description().clone(), Reader(Rc::new(self)))
	}
}
impl Source for Captured {
	fn description(&self) -> &FileDescription {
		self.bytes.description()
	}
	async fn read(&self, offset: u64, length: usize) -> Result<Chunk, Error> {
		self.span(offset, length)
	}
}
struct Reader(Rc<Captured>);
impl rooms_glowcap::client::sources::Reader for Reader {
	fn read(&self, offset: usize, length: usize) -> Pin<Box<dyn Future<Output = Result<Vec<u8>, String>>>> {
		let captured = self.0.clone();
		Box::pin(async move {
			captured
				.span(offset as u64, length)
				.map(Chunk::into_vec)
				.map_err(Error::into_refusal)
		})
	}
}
