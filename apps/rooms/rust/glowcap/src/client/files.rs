//! Owned transfer capabilities. Upload mutation is exclusive; independent blob
//! readers may share the same session without sharing progress or cancellation.
pub mod capture;
use super::{Client, Deadline, Error};
use glowcap::{Argument, Ref};
use rooms_application::{
	files::{
		transfer::{self, UploadProgress},
		FileDescription, CHUNK_BYTES,
	},
	room::attachment::Attachment,
};

pub struct Upload<D> {
	client: Client<D>,
	reference: Ref,
	description: FileDescription,
	progress: UploadProgress,
}
impl<D: Deadline> Upload<D> {
	pub(super) async fn stage(client: Client<D>, member: &Ref, description: FileDescription) -> Result<Self, Error> {
		let reply = {
			let (width, height) = description.dimensions();
			let args = [
				description.name().into(),
				description.mime().into(),
				Argument::Integer(description.size() as i64),
				Argument::Integer(width.into()),
				Argument::Integer(height.into()),
			];
			client.call(member, "attach", &args, "the room did not answer taking the file")
		}
		.await?;
		let Argument::Reference(reference) = reply.0 else {
			return Err(transfer::Error::UploadReply.into());
		};
		let progress = UploadProgress::new(description.size())?;
		Ok(Self {
			client,
			reference,
			description,
			progress,
		})
	}
	pub fn description(&self) -> &FileDescription {
		&self.description
	}
	pub fn written(&self) -> usize {
		self.progress.written()
	}
	pub fn complete(&self) -> bool {
		self.progress.complete()
	}
	/// Begin only after the membership has posted or refiled its staged files.
	/// A timeout, failure or dropped future leaves progress unacknowledged.
	/// Reusing this handle to write then refuses, preventing duplicate appends.
	pub async fn write(&mut self, bytes: Vec<u8>) -> Result<(), Error> {
		self.progress.begin(bytes.len())?;
		let pending = {
			let arg = Argument::Bytes(bytes);
			self.client.call_with_timeout(
				&self.reference,
				"write",
				&[arg],
				"the file stopped being taken",
				transfer::STALL_MS,
			)
		};
		pending.await?;
		self.progress.acknowledge()?;
		Ok(())
	}
	/// Consume the local write authority. The returned result is the host's
	/// actual discard acknowledgement; cancellation does not synthesize one.
	pub async fn discard(self) -> Result<(), Error> {
		self.client
			.call(
				&self.reference,
				"discard",
				&[],
				"the room did not answer discarding the file",
			)
			.await?;
		Ok(())
	}
}

pub struct File<D> {
	client: Client<D>,
	attachment: Attachment<Ref>,
	exporter: Option<std::cell::OnceCell<Option<glowcap::Session>>>,
}
impl<D: Deadline> File<D> {
	pub fn new(client: Client<D>, attachment: Attachment<Ref>) -> Self {
		Self {
			client,
			attachment,
			exporter: None,
		}
	}
	pub fn attachment(&self) -> &Attachment<Ref> {
		&self.attachment
	}
	/// Bind an incoming attachment to its delivering context. The first read
	/// resolves and retains its actual exporter outside the actor turn; local
	/// references use the delivering client. No guessed directory is involved.
	pub fn received(client: Client<D>, attachment: Attachment<Ref>) -> Self {
		Self {
			client,
			attachment,
			exporter: Some(Default::default()),
		}
	}
	fn session(&self) -> Result<&glowcap::Session, Error> {
		let Some(exporter) = &self.exporter else {
			return Ok(self.client.session());
		};
		if exporter.get().is_none() {
			let owner = self.client.session().host().reference_session(&self.attachment.blob)?;
			let _ = exporter.set(owner);
		}
		Ok(exporter
			.get()
			.expect("resolved exporter")
			.as_ref()
			.unwrap_or(self.client.session()))
	}
	pub async fn read(&self, offset: u64, maximum: usize) -> Result<Vec<u8>, Error> {
		let expected = transfer::read_length(self.attachment.description.size(), offset, maximum)?;
		if expected == 0 {
			return Ok(Vec::new());
		}
		let reply = self
			.client
			.call_on(
				self.session()?,
				&self.attachment.blob,
				"read",
				&[Argument::Integer(offset as i64), Argument::Integer(expected as i64)],
				"the file stopped arriving",
				transfer::STALL_MS,
			)
			.await?;
		transfer::accept_chunk(expected, reply.0.as_bytes().map(<[u8]>::len))?;
		let Argument::Bytes(bytes) = reply.0 else {
			unreachable!("validated byte reply")
		};
		Ok(bytes)
	}
	/// Explicit whole-file assembly. Streaming callers use read and never
	/// allocate the complete declared file at an intermediary.
	pub async fn fetch(&self, mut on_progress: impl FnMut(usize)) -> Result<Vec<u8>, Error> {
		let size = self.attachment.description.size();
		let mut bytes = Vec::with_capacity(size);
		while bytes.len() < size {
			bytes.extend(self.read(bytes.len() as u64, CHUNK_BYTES).await?);
			on_progress(bytes.len());
		}
		Ok(bytes)
	}
}

/// The binding's single renderer for a live Rooms attachment suffix.
pub(crate) fn append_attachment(args: &mut Vec<Argument>, description: &FileDescription, blob: &Ref) {
	let (width, height) = description.dimensions();
	args.extend([
		"file".into(),
		description.name().into(),
		description.mime().into(),
		Argument::Integer(description.size() as i64),
		blob.clone().into(),
		Argument::Integer(width.into()),
		Argument::Integer(height.into()),
	]);
}
