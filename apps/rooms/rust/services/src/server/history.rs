//! Retention belongs to the portable index. This host owner restores the
//! history directory and serializes the admitted effects, with one bounded queue.
//! A failed persistence effect ends the server: later effects cannot safely
//! continue from storage whose outcome no longer matches the live index.
use super::error::Error;
use rooms_application::server::history::Persist;
use tokio::sync::mpsc;
mod file;
pub(super) use file::{Backend, restore};

/// Queued tails share immutable rows with the live index. At most one new
/// retained row is introduced per admitted mutation, plus at most `LINES_KEPT` shared
/// row references per queued replacement. The in-flight write adds one slot.
pub(super) const QUEUE: usize = 1024;

/// Reserve before touching policy, then transfer the effect without another
/// fallible step. Ordinary room effects cannot carry persistence by type.
pub(super) fn mutate<T>(
	state: &mut super::state::State,
	change: impl FnOnce(
		&mut rooms_application::server::rooms::Rooms<u64, glowcap::Ref>,
	) -> Result<
		(T, rooms_application::server::rooms::Mutation<u64, glowcap::Ref>),
		rooms_application::server::rooms::Refusal,
	>,
) -> Result<T, String> {
	let reserved = state
		.history
		.as_ref()
		.map(|history| {
			history.clone().try_reserve_owned().map_err(|error| match error {
				mpsc::error::TrySendError::Full(_) => super::answer::busy(),
				mpsc::error::TrySendError::Closed(_) => "the history writer has ended".into(),
			})
		})
		.transpose()?;
	let (result, mutation) = change(&mut state.rooms).map_err(|refusal| refusal.reason())?;
	if let (Some(reserved), Some(persist)) = (reserved, mutation.persist) {
		reserved.send(persist);
	}
	state.apply_rooms(mutation.effects);
	Ok(result)
}
pub(super) async fn worker(mut backend: Backend, mut changes: mpsc::Receiver<Persist>) -> Result<(), Error> {
	while let Some(change) = changes.recv().await {
		let (held, outcome) = tokio::task::spawn_blocking(move || {
			let outcome = backend.persist(change);
			(backend, outcome)
		})
		.await
		.map_err(|e| Error::Worker(e.to_string()))?;
		outcome.map_err(|(what, cause)| Error::History(format!("could not {what}: {cause}")))?;
		backend = held;
	}
	Ok(())
}
