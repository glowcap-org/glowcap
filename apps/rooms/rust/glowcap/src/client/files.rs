//! Owned transfer capabilities. Upload mutation is exclusive. Independent blob
//! readers may share the same session without sharing progress or cancellation.
pub mod capture;
use super::{Caller, Client, Deadline, Error};
use glowcap::{Argument, Ref};
use rooms_application::{
	files::{
		CHUNK_BYTES, FileDescription,
		transfer::{self, UploadProgress},
	},
	room::attachment::Attachment,
};

pub struct Upload<D> {
	client: Client<D>,
	reference: Ref,
	description: FileDescription,
	progress: UploadProgress,
	blob: Option<Ref>,
}
impl<D: Deadline> Upload<D> {
	pub(super) async fn stage(
		client: Client<D>,
		member: &Ref,
		description: FileDescription,
		retained: bool,
	) -> Result<Self, Error> {
		let reply = {
			let (width, height) = description.dimensions();
			let args = [
				description.name().into(),
				description.mime().into(),
				Argument::Integer(description.size() as i64),
				Argument::Integer(width.into()),
				Argument::Integer(height.into()),
			];
			client.call(
				member,
				if retained {
					rooms_application::room::receipt::ATTACH
				} else {
					rooms_application::protocol_data::ATTACH
				},
				&args,
				"the room did not answer taking the file",
			)
		}
		.await?;
		let (reference, blob) = match reply.0 {
			Argument::Reference(reference) if !retained => (reference, None),
			Argument::List(mut pair) if retained && pair.len() == 2 => {
				let (Some(Argument::Reference(blob)), Some(Argument::Reference(upload))) = (pair.pop(), pair.pop())
				else {
					return Err(transfer::Error::UploadReply.into());
				};
				(upload, Some(blob))
			}
			_ => return Err(transfer::Error::UploadReply.into()),
		};
		let progress = UploadProgress::new(description.size())?;
		Ok(Self {
			client,
			reference,
			description,
			progress,
			blob,
		})
	}
	/// Read-only identity minted by the same file owner as the write authority.
	pub fn blob(&self) -> Option<&Ref> {
		self.blob.as_ref()
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
				rooms_application::protocol_data::WRITE,
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
	/// actual discard acknowledgement. Cancellation does not synthesize one.
	pub async fn discard(self) -> Result<(), Error> {
		self.client
			.call(
				&self.reference,
				rooms_application::protocol_data::DISCARD,
				&[],
				"the room did not answer discarding the file",
			)
			.await?;
		Ok(())
	}
}

pub struct File<D> {
	reader: FileReader<D>,
	attachment: Attachment<Ref>,
}
enum FileReader<D> {
	Capability(Caller<D>),
	Mediated {
		reader: Box<dyn super::sources::Reader>,
		bytes: usize,
	},
}
impl<D: Deadline> File<D> {
	pub fn new(client: Client<D>, attachment: Attachment<Ref>) -> Self {
		Self {
			reader: FileReader::Capability(Caller::Remote(client)),
			attachment,
		}
	}
	/// Read an already mediated capability on the existing Host. This creates
	/// no Session and adds no authority beyond the held attachment.
	pub fn local(host: glowcap::Host, platform: D, attachment: Attachment<Ref>) -> Self {
		Self {
			reader: FileReader::Capability(Caller::Local { host, platform }),
			attachment,
		}
	}
	/// A domain owner can retain exact admission around every source read.
	/// The reader owns that check and its deadline. File validates each chunk.
	pub fn mediated<R: super::sources::Reader + 'static>(
		attachment: Attachment<Ref>,
		reader: R,
		backing_bytes: usize,
	) -> Self {
		Self {
			reader: FileReader::Mediated {
				reader: Box::new(reader),
				bytes: core::mem::size_of::<R>().saturating_add(backing_bytes),
			},
			attachment,
		}
	}
	/// Heap retained beyond this inline File, including a mediated reader's
	/// boxed body and its explicitly supplied shared or owned backing storage.
	pub fn retained_heap_bytes(&self) -> usize {
		self.attachment
			.description
			.retained_bytes()
			.saturating_add(match &self.reader {
				FileReader::Mediated { bytes, .. } => *bytes,
				FileReader::Capability(_) => 0,
			})
	}
	pub fn attachment(&self) -> &Attachment<Ref> {
		&self.attachment
	}
	/// Keep the delivering client alive. The Host routes each held blob to its
	/// actual owner, including local facades and third-party handoffs.
	pub fn received(client: Client<D>, attachment: Attachment<Ref>) -> Self {
		Self::new(client, attachment)
	}
	pub async fn read(&self, offset: u64, maximum: usize) -> Result<Vec<u8>, Error> {
		let expected = transfer::read_length(self.attachment.description.size(), offset, maximum)?;
		if expected == 0 {
			return Ok(Vec::new());
		}
		let bytes = match &self.reader {
			FileReader::Mediated { reader, .. } => reader
				.read(offset as usize, expected)
				.await
				.map_err(glowcap::loam::refusal)?,
			FileReader::Capability(caller) => {
				let reply = caller
					.call_reference(
						&self.attachment.blob,
						rooms_application::protocol_data::READ,
						&[Argument::Integer(offset as i64), Argument::Integer(expected as i64)],
						"the file stopped arriving",
						transfer::STALL_MS,
					)
					.await?;
				transfer::accept_chunk(expected, reply.as_bytes().map(<[u8]>::len))?;
				let Argument::Bytes(bytes) = reply else {
					unreachable!("validated byte reply")
				};
				bytes
			}
		};
		transfer::accept_chunk(expected, Some(bytes.len()))?;
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
