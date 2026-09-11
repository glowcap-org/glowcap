//! Owned work admitted to the one serial archive worker.
use super::*;
use rooms_application::archive::blobs::Reader as BlobReader;
use rooms_glowcap::client::files::File;
pub(super) enum Operation<P: Platform> {
	Clear,
	Shares(rooms_application::archive::shares::protocol::Request),
	Record(Request),
	Files {
		record: Record,
		sources: Vec<File<P>>,
		/// The capture budget these files hold until they are stored or refused.
		files: FilePermit,
	},
	Digest {
		scope: Filter,
		digest: String,
		session: Session,
		receiver: Receiver<P>,
	},
	ReadBlob {
		reader: BlobReader,
		offset: u64,
		maximum: usize,
	},
}
impl<P: Platform> Operation<P> {
	pub(super) fn heap_bytes(&self) -> usize {
		match self {
			Self::Clear => 0,
			Self::Shares(request) => request.heap_bytes(),
			Self::Record(request) => request.heap_bytes(),
			Self::Files { record, sources, .. } => {
				record.retained_bytes() - core::mem::size_of::<Record>()
					+ sources.capacity() * core::mem::size_of::<File<P>>()
					+ sources
						.iter()
						.map(|s| s.attachment().description.retained_bytes())
						.sum::<usize>()
			}
			Self::Digest { scope, digest, .. } => scope.retained_bytes() + digest.capacity(),
			Self::ReadBlob { reader, .. } => reader.retained_bytes(),
		}
	}
}
