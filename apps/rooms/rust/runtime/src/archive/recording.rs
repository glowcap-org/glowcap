//! Archive recording admission and completion shared by message producers.
//! Admitted storage and capture work stays with the archive after reply loss.
use crate::Error;
use std::{
	future::Future,
	pin::Pin,
	task::{Context, Poll},
};
use tokio::sync::oneshot;

#[must_use = "observe the archive completion or explicitly abandon its reply"]
pub struct Reply<T>(oneshot::Receiver<Result<T, Error>>);
impl<T> Reply<T> {
	/// Transfer observation of already admitted archive work.
	pub fn from_receiver(receiver: oneshot::Receiver<Result<T, Error>>) -> Self {
		Self(receiver)
	}
	pub async fn wait(self) -> Result<T, Error> {
		self.await
	}
}
impl<T> Future for Reply<T> {
	type Output = Result<T, Error>;
	fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
		Pin::new(&mut self.get_mut().0)
			.poll(cx)
			.map(|result| result.map_err(|_| Error::closed("session archive worker stopped before replying"))?)
	}
}
/// A line acknowledgement does not imply its separate standing write committed.
#[derive(Debug)]
pub struct Recorded {
	pub revision: u64,
	pub standing: Result<Option<u64>, Error>,
	pub files: FileRecording,
}
/// Attachment work performed by this recording. Metadata-only writes can still
/// preserve matching blobs already stored in the archive; they fetch no sources.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FileRecording {
	NoFiles,
	Stored,
	MetadataOnly(MetadataReason),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MetadataReason {
	PendingCaptures,
	PendingBytes,
	BackendUnsupported,
	/// The source stopped answering before every byte arrived; the line is
	/// kept the way its room keeps it, with the file named and its bytes gone.
	SourceFailed(String),
}
impl core::fmt::Display for MetadataReason {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::PendingCaptures => f.write_str("too many files were already being captured"),
			Self::PendingBytes => f.write_str("too many file bytes were already waiting to be stored"),
			Self::BackendUnsupported => f.write_str("the selected archive keeps no file bytes"),
			Self::SourceFailed(reason) => f.write_str(reason),
		}
	}
}
/// Coordinates identify admitted work. Observe completion to know it committed.
#[must_use = "observe the recording completion or explicitly abandon its reply"]
pub struct Recording {
	pub coordinates: rooms_application::archive::Coordinates,
	pub completion: Reply<Recorded>,
}

/// Input authority for recording. Reuse admitted media whenever available.
/// If media admission refused, the archive may independently admit the original
/// received capabilities under its own capture budget; no empty-file success
/// substitutes for that refusal.
pub enum Files {
	Retained(Vec<crate::files::media_files::FileView>),
	Received {
		session: glowcap::Session,
		attachments: Vec<rooms_application::room::attachment::Attachment<glowcap::Ref>>,
	},
}

/// Turn a completed archive write into the one issue its producer owns, as
/// the sentence a person reads in the session's issue list. The line write,
/// attachment capture, and standing write are separate outcomes; none may
/// disappear merely because the primary record committed.
pub fn completion_issue(result: Result<Recorded, Error>) -> Option<String> {
	match result {
		Ok(Recorded {
			files: FileRecording::MetadataOnly(reason),
			standing: Err(standing),
			..
		}) => Some(format!(
			"the archive kept a line without its file bytes: {reason}; the archive also did not record the member standing: {standing}"
		)),
		Ok(Recorded {
			files: FileRecording::MetadataOnly(reason),
			standing: Ok(_),
			..
		}) => Some(format!("the archive kept a line without its file bytes: {reason}")),
		Ok(Recorded {
			standing: Err(reason), ..
		}) => Some(format!("the archive did not record the member standing: {reason}")),
		Ok(_) => None,
		Err(reason) => Some(reason.to_string()),
	}
}

/// Synchronous recording admission. The implementation owns capture, ordered
/// persistence, archive selection and erasure; observers only receive a receipt.
pub trait Recorder {
	fn record(
		&self,
		source: &rooms_application::text::DocumentText,
		message: &rooms_application::archive::recording::Message<'_>,
		files: Files,
	) -> Result<Option<Recording>, Error>;
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn completion_issue_keeps_every_partial_recording_outcome() {
		let issue = completion_issue(Ok(Recorded {
			revision: 1,
			standing: Err(Error::refused("standing refused")),
			files: FileRecording::MetadataOnly(MetadataReason::SourceFailed("source vanished".into())),
		}))
		.unwrap();
		assert!(issue.contains("without its file bytes: source vanished"));
		assert!(issue.contains("also did not record the member standing: standing refused"));
	}
}
