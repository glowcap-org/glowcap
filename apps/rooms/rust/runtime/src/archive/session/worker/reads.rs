//! Committed blob callbacks pass ingestion while queued erasure fences them.
use super::*;
impl<P: Platform> ingestion::Request for Pending<P> {
	fn reads_blob(&self) -> bool {
		matches!(self.command, Command::ReadBlob(..) | Command::SharedRead(..))
	}
	fn fences_blob_reads(&self) -> bool {
		matches!(self.command, Command::Clear(_) | Command::Revoke(..))
	}
}
pub(super) struct ReadReplies<'a, R> {
	pub(super) reads: R,
	pub(super) report: &'a mut Report,
	pub(super) erase_required: bool,
}
impl<R: BlobAccess, P: Platform> Reads<Pending<P>> for ReadReplies<'_, R> {
	async fn answer(&mut self, pending: Pending<P>, fenced: bool) {
		let pending = match pending.command {
			Command::SharedRead(work, reader, offset, maximum, mut reply) => {
				let result = if fenced || self.erase_required {
					Err(Error::stale(
						"archive byte reads are fenced by queued erasure or revocation",
					))
				} else {
					async {
						work.check()?;
						let bytes = match reader.as_ref() {
							super::super::shared_blobs::Reader::Local(reader) => {
								self.reads.read(reader.clone(), offset, maximum).await?
							}
							super::super::shared_blobs::Reader::Peer(reader) => reader.read(offset, maximum).await?,
						};
						work.check()?;
						crate::archive::checked_bytes(bytes, maximum)
					}
					.await
				};
				resolve(&mut reply, result.map(glowcap::Argument::Bytes), self.report);
				return;
			}
			command => Pending {
				command,
				_permit: pending._permit,
			},
		};
		let Command::ReadBlob(reader, offset, maximum, answer) = pending.command else {
			unreachable!("classified blob read")
		};
		let result = if fenced || self.erase_required {
			Err(Error::stale(
				"archive byte reads are fenced by queued erasure or revocation",
			))
		} else {
			self.reads
				.read(reader, offset, maximum)
				.await
				.and_then(|bytes| crate::archive::checked_bytes(bytes, maximum))
		};
		complete(answer, result, self.report);
	}
}
