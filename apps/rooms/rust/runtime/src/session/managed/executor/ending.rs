//! How a pipeline hands its end to the executor, once for every pipeline
//! whose dispatch can end without an answer it can settle on: archive sharing,
//! uploads, and bridges.
use super::{super::results::Settlement, Writer};

/// How a pipeline ends. The executor reports a cause it was handed
/// (`Writer::report`) before it acts on it.
pub(in crate::session::managed) enum Ending {
	/// The settlement the receipt takes.
	Settled(Settlement),
	/// The answer was unknown, so the receipt settles unknown by this cause.
	Unknown(glowcap::Error),
	/// The pipeline cannot settle: a room upload whose attach or post answer
	/// was lost or unreadable (its cleanup never proves the post absent), a
	/// request whose answer is unknown or unreadable, or a step that failed
	/// after the point from which the pipeline cannot rerun, such as the
	/// completion of an upload's settlement. A fill that fails settles the line
	/// as incomplete and is not this ending.
	/// The executor drops the job and leaves the receipt with no executor: it
	/// reads unknown, holds its place, and its source's release settles it.
	Unresolved(glowcap::Error),
}
impl Ending {
	/// The settlement to commit, or none when the job ends without one.
	pub(in crate::session::managed) fn settlement(self, id: &str, writer: &Writer) -> Option<Settlement> {
		match self {
			Self::Settled(outcome) => Some(outcome),
			Self::Unknown(cause) => {
				writer.report(id, &cause);
				Some(Settlement::unknown(&cause))
			}
			Self::Unresolved(cause) => {
				writer.report(id, &cause);
				None
			}
		}
	}
}
