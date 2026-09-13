//! Freeze once, hash once, then transmit that same immutable storage. Callers
//! reserve their aggregate byte budget before starting this asynchronous work.
use crate::Error;
use rooms_application::files::{CHUNK_BYTES, identity::Identity};
use rooms_glowcap::client::Deadline;
use rooms_glowcap::client::sources::Source;
use sha2::{Digest, Sha256};

pub struct Frozen {
	files: Vec<Source>,
	digests: Vec<[u8; 32]>,
}
impl Frozen {
	pub fn identities(&self) -> Vec<Identity<'_>> {
		self.files
			.iter()
			.zip(&self.digests)
			.map(|(source, digest)| Identity {
				description: source.description(),
				digest: *digest,
			})
			.collect()
	}
	pub fn into_sources(self) -> Vec<Source> {
		self.files
	}
}
/// A source that stops answering before its declared bytes arrive is a
/// closed source; a span the captured bytes cannot cover is a bad request.
pub async fn freeze(platform: &impl Deadline, sources: Vec<Source>) -> Result<Frozen, Error> {
	let mut frozen = Frozen {
		files: Vec::with_capacity(sources.len()),
		digests: Vec::with_capacity(sources.len()),
	};
	for source in sources {
		let captured = source.materialize(platform).await.map_err(Error::closed)?;
		let mut hash = Sha256::new();
		for offset in (0..captured.description().size()).step_by(CHUNK_BYTES) {
			hash.update(
				captured
					.span(offset as u64, CHUNK_BYTES)
					.map_err(Error::invalid)?
					.as_ref(),
			);
			tokio::task::yield_now().await;
		}
		frozen.digests.push(hash.finalize().into());
		frozen.files.push(Source::captured(captured));
	}
	Ok(frozen)
}
