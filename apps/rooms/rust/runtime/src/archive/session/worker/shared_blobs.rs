//! Deferred attachment selection and reads remain owned by the archive worker.
use super::super::shared_blobs::{Reader, Request, Selection};
use super::*;
use glowcap::Ref;
use rooms_application::archive::{Access, Facet};
impl<B: Backend, P: Platform> Worker<B, P> {
	pub(super) async fn shared_reader(&mut self, request: &Request<P>) -> Result<Ref, Error> {
		request.work.check()?;
		let reader = match &request.work.source {
			Keeper::Local(_) => {
				self.local_ready().await?;
				Reader::Local(match &request.selection {
					Selection::Attachment { reader, .. } => reader.clone(),
					Selection::Digest { scope, digest } => {
						self.backend
							.blob_reader(
								Facet::new(scope.clone(), Access::Read).map_err(Error::invalid_by)?,
								digest.clone(),
							)
							.await?
					}
				})
			}
			Keeper::Peer(peer) => Reader::Peer(peer.scoped_blob(&request.selection).await?),
		};
		request.work.check()?;
		request
			.work
			.spawn_reader(&request.host, request.session.as_ref(), reader)
	}
	pub(super) async fn shared_read(
		&mut self,
		work: &Work<P>,
		reader: &Reader<P>,
		offset: u64,
		maximum: usize,
	) -> Result<Vec<u8>, Error> {
		work.check()?;
		let bytes = match reader {
			Reader::Local(reader) => {
				self.local_ready().await?;
				self.backend.read_blob(reader.clone(), offset, maximum).await?
			}
			Reader::Peer(reader) => reader.read(offset, maximum).await?,
		};
		work.check()?;
		crate::archive::checked_bytes(bytes, maximum)
	}
}
