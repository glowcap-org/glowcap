//! Freeze once, hash once, then transmit that same immutable storage. Callers
//! reserve their aggregate byte budget before starting this asynchronous work.
use rooms_application::files::{identity::Identity, CHUNK_BYTES};
use rooms_glowcap::client::sources::Source;
use rooms_glowcap::client::Deadline;
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
pub async fn freeze(platform: &impl Deadline, sources: Vec<Source>) -> Result<Frozen, String> {
	let mut frozen = Frozen {
		files: Vec::with_capacity(sources.len()),
		digests: Vec::with_capacity(sources.len()),
	};
	for source in sources {
		let captured = source.materialize(platform).await?;
		let mut hash = Sha256::new();
		for offset in (0..captured.description().size()).step_by(CHUNK_BYTES) {
			hash.update(captured.span(offset as u64, CHUNK_BYTES)?.as_ref());
			tokio::task::yield_now().await;
		}
		frozen.digests.push(hash.finalize().into());
		frozen.files.push(Source::captured(captured));
	}
	Ok(frozen)
}
