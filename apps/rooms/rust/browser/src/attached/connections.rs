//! Browser task retirement reports one terminal result.
use rooms_runtime::Error as RuntimeError;
use tokio::sync::watch;
/// Retain the owner's typed result for every observer. A dropped sender
/// without a terminal result means the owner closed without reporting.
pub(super) async fn settled(ended: &mut watch::Receiver<Option<super::Result<()>>>) -> super::Result<()> {
	loop {
		let outcome = ended.borrow().clone();
		if let Some(outcome) = outcome {
			return outcome;
		}
		ended
			.changed()
			.await
			.map_err(|_| RuntimeError::closed("a Rooms browser owner retired without reporting"))?;
	}
}
