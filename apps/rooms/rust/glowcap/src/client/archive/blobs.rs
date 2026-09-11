use super::*;
use rooms_application::{
	archive::blobs::{self as policy, admission},
	files::CHUNK_BYTES,
	room::attachment::Attachment,
};
pub struct Blob<D> {
	client: Client<D>,
	reference: Ref,
}
impl<D: Deadline> Blob<D> {
	pub fn reference(&self) -> &Ref {
		&self.reference
	}
	pub async fn read(&self, offset: u64, maximum: usize) -> Result<Vec<u8>, Error> {
		if SafeInteger::<false>::new(offset).is_none() || maximum == 0 || maximum > CHUNK_BYTES {
			return Err(archive::Error::Blob.into());
		}
		let reply = self
			.client
			.call(
				&self.reference,
				"read",
				&[Argument::Integer(offset as i64), Argument::Integer(maximum as i64)],
				"the archive did not answer reading file bytes",
			)
			.await?;
		match reply.0 {
			Argument::Bytes(bytes) if bytes.len() <= maximum => Ok(bytes),
			_ => Err(archive::Error::Blob.into()),
		}
	}
}
impl<D: Deadline> Archive<D> {
	/// Stream runtime-owned sources through the shared bounded source pool.
	/// This accepts the same metadata as put_files without requiring callers to
	/// build and manage intermediate blob capabilities themselves.
	/// The call's end retires source authority, including after acknowledgement.
	pub async fn put_sources(
		&self,
		pool: &super::super::sources::Sources<D>,
		record: &Record,
		sources: Vec<super::super::sources::Source>,
	) -> Result<u64, Error>
	where
		D: super::super::Tasks + Clone + 'static,
	{
		policy::validate_sources(record, sources.iter().map(super::super::sources::Source::description))?;
		if sources.is_empty() {
			return Err(archive::Error::Blob.into());
		}
		let reply = pool
			.send_scoped(
				&self.client,
				&self.reference,
				admission::PUT_FILES,
				vec![wire::record_row(record)],
				sources,
			)
			.await?;
		acknowledgement(&reply)
	}
	pub async fn put_files(&self, record: &Record, attachments: &[Attachment<Ref>]) -> Result<u64, Error> {
		policy::validate_sources(record, attachments.iter().map(|a| &a.description))?;
		if attachments.is_empty() {
			return Err(archive::Error::Blob.into());
		}
		let pending = {
			let mut args = Vec::with_capacity(1 + attachments.len() * rooms_application::room::attachment::RECORD_SPAN);
			args.push(wire::record_row(record));
			for attachment in attachments {
				super::super::files::append_attachment(&mut args, &attachment.description, &attachment.blob);
			}
			self.client.call(
				&self.reference,
				admission::PUT_FILES,
				&args,
				"the archive did not answer retaining file bytes",
			)
		};
		acknowledgement(&pending.await?.0)
	}
	pub async fn attachment(&self, record: &Record, index: usize) -> Result<Blob<D>, Error>
	where
		D: Clone,
	{
		policy::files(record)?
			.get(index)
			.and_then(|a| a.blob())
			.ok_or(archive::Error::Blob)?;
		let pending = {
			let args = [wire::record_row(record), Argument::Integer(index as i64)];
			self.client.call(
				&self.reference,
				admission::ATTACHMENT,
				&args,
				"the archive did not answer attachment",
			)
		};
		self.blob_reply(pending.await?.0)
	}
	pub async fn blob(&self, digest: &str) -> Result<Blob<D>, Error>
	where
		D: Clone,
	{
		Filter {
			digest: Some(digest.into()),
			..Default::default()
		}
		.validate()?;
		let reply = self
			.client
			.call(
				&self.reference,
				admission::BLOB,
				&[digest.into()],
				"the archive did not answer blob",
			)
			.await?;
		self.blob_reply(reply.0)
	}
	fn blob_reply(&self, reply: Argument) -> Result<Blob<D>, Error>
	where
		D: Clone,
	{
		let Argument::Reference(reference) = reply else {
			return Err(archive::Error::Blob.into());
		};
		Ok(Blob {
			client: self.client.clone(),
			reference,
		})
	}
}
