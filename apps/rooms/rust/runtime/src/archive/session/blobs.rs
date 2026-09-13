//! Archived file reads follow the keeper returned by the combined view. A target
//! switch never reinterprets a digest against whichever archive is selected now.
use super::*;
use std::rc::Weak;
pub enum ArchivedBlob<P: Platform> {
	Local(LocalBlob<P>),
	Peer(Blob<P>),
}
pub struct LocalBlob<P: Platform> {
	owner: Weak<State<P>>,
	reader: rooms_application::archive::blobs::Reader,
}
impl<P: Platform> KeptRecord<P> {
	/// Forward this record's exact stored file through a runtime's bounded
	/// source pool. Selection changes cannot substitute a different archive.
	/// The record was read back from the archive, so a file list it cannot
	/// carry is the archive's failure rather than the reader's.
	pub async fn source(&self, index: usize) -> Result<Option<rooms_glowcap::client::sources::Source>, Error> {
		let Some(attachment) = rooms_application::archive::blobs::files(&self.record)
			.map_err(|error| Error::storage_message(error.to_string()))?
			.get(index)
			.filter(|a| a.blob().is_some())
		else {
			return Ok(None);
		};
		let description = attachment
			.live_description()
			.map_err(|error| Error::storage_message(error.to_string()))?;
		let Some(blob) = self.blob(index).await? else {
			return Ok(None);
		};
		Ok(Some(rooms_glowcap::client::sources::Source::reader(
			description,
			SourceReader(Rc::new(blob)),
		)))
	}
	pub async fn blob(&self, index: usize) -> Result<Option<ArchivedBlob<P>>, Error> {
		let Some(digest) = rooms_application::archive::blobs::files(&self.record)
			.map_err(|error| Error::storage_message(error.to_string()))?
			.get(index)
			.and_then(|a| a.blob())
		else {
			return Ok(None);
		};
		match &self.keeper {
			Keeper::Peer(peer) => peer.blob(digest).await.map(|blob| Some(ArchivedBlob::Peer(blob))),
			Keeper::Local(local) => {
				let owner = local
					.owner
					.upgrade()
					.ok_or_else(|| Error::closed("session archive is closed"))?;
				let digest = digest.to_owned();
				let reader = owner
					.admit(digest.len(), 0, |answer| Command::BlobReader(digest, answer))?
					.wait()
					.await?;
				Ok(Some(ArchivedBlob::Local(LocalBlob {
					owner: local.owner.clone(),
					reader,
				})))
			}
		}
	}
}

struct SourceReader<P: Platform>(Rc<ArchivedBlob<P>>);
impl<P: Platform> rooms_glowcap::client::sources::Reader for SourceReader<P> {
	fn read(
		&self,
		offset: usize,
		length: usize,
	) -> std::pin::Pin<Box<dyn core::future::Future<Output = Result<Vec<u8>, String>>>> {
		let blob = self.0.clone();
		Box::pin(async move { blob.read(offset as u64, length).await.map_err(Error::into_refusal) })
	}
}
impl<P: Platform> ArchivedBlob<P> {
	pub async fn read(&self, offset: u64, maximum: usize) -> Result<Vec<u8>, Error> {
		match self {
			Self::Peer(blob) => blob.read(offset, maximum).await,
			Self::Local(blob) => {
				if rooms_application::fields::SafeInteger::<false>::new(offset).is_none()
					|| maximum == 0 || maximum > rooms_application::files::CHUNK_BYTES
				{
					return Err(Error::invalid("invalid archived file read"));
				}
				let owner = blob
					.owner
					.upgrade()
					.ok_or_else(|| Error::closed("session archive is closed"))?;
				let reader = blob.reader.clone();
				owner
					.admit(reader.retained_bytes(), 0, |answer| {
						Command::ReadBlob(reader, offset, maximum, answer)
					})?
					.wait()
					.await
			}
		}
	}
}
