//! Browser task retirement reports one terminal result.
use tokio::sync::watch;
/// Wait for a browser-owned task to report how it ended.
///
/// This is the sibling of the runtime's `terminal`, not a copy of it: these
/// outcomes belong to tasks this module spawned and their reader is the page,
/// so they carry the sentence JavaScript will see rather than the runtime's
/// classed failure. A sender dropped without reporting means the task was
/// cancelled with nobody left to say why.
pub(super) async fn settled(ended: &mut watch::Receiver<Option<super::Result<()>>>) -> super::Result<()> {
	loop {
		let outcome = ended.borrow().clone();
		if let Some(outcome) = outcome {
			return outcome;
		}
		ended
			.changed()
			.await
			.map_err(|_| "a Rooms browser owner retired without reporting".to_owned())?;
	}
}
