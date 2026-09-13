//! Attachment-byte admission reserves bounded archive capacity before reads.
use super::*;
use crate::{
	archive::protocol,
	room::{
		ListArgument,
		attachment::{self, AttachmentArgument},
	},
};
use alloc::vec::Vec;
pub const PUT_FILES: &str = "putFiles";
pub const ATTACHMENT: &str = "attachment";
pub const BLOB: &str = "blob";
pub const MAX_ARGUMENTS: usize = 1 + crate::room::line::MAX_MESSAGE_FILES * attachment::RECORD_SPAN;
pub enum Request<C> {
	Put {
		record: Record,
		files: Vec<attachment::Attachment<C>>,
	},
	Attachment(Reader),
	Digest {
		scope: Filter,
		digest: String,
	},
}
impl Facet {
	pub fn admit_blob<A: ListArgument + AttachmentArgument + crate::files::FileArgument>(
		&self,
		verb: &str,
		args: &[A],
	) -> Result<Request<A::Capability>, Error> {
		match verb {
			PUT_FILES if (2..=MAX_ARGUMENTS).contains(&args.len()) => {
				if self.access() != super::super::Access::ReadWrite {
					return Err(Error::Access);
				}
				let record = protocol::record(&args[0])?;
				if !self.permits_put(&record) {
					return Err(Error::Filter);
				}
				let attachments = attachment::read_exact(args, 1).map_err(|_| Error::Blob)?;
				validate_sources(&record, attachments.iter().map(|a| &a.description))?;
				Ok(Request::Put {
					record,
					files: attachments,
				})
			}
			ATTACHMENT if args.len() == 2 => {
				let record = protocol::record(&args[0])?;
				let at = args[1]
					.integer()
					.and_then(|n| usize::try_from(n).ok())
					.ok_or(Error::Blob)?;
				Ok(Request::Attachment(Reader::attachment(self, &record, at)?))
			}
			BLOB if args.len() == 1 => {
				let digest = args[0].text().filter(|s| records::digest(s)).ok_or(Error::Blob)?;
				let scope = self
					.scope()
					.intersect(&Filter {
						digest: Some(digest.into()),
						..Default::default()
					})
					.ok_or(Error::Filter)?;
				Ok(Request::Digest {
					scope,
					digest: digest.into(),
				})
			}
			_ => Err(Error::Method),
		}
	}
}
pub fn read<A: crate::room::ArgumentView>(verb: &str, args: &[A]) -> Result<(u64, usize), Error> {
	if verb != "read" || args.len() != 2 {
		return Err(Error::Method);
	}
	let offset = args[0]
		.integer()
		.and_then(|n| u64::try_from(n).ok())
		.filter(|n| SafeInteger::<false>::new(*n).is_some())
		.ok_or(Error::Blob)?;
	let length = args[1]
		.integer()
		.and_then(|n| usize::try_from(n).ok())
		.filter(|n| (1..=CHUNK_BYTES).contains(n))
		.ok_or(Error::Blob)?;
	Ok((offset, length))
}
