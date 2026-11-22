//! The first start's read to the head of activity, where a new bot begins.
use super::{Backoff, Cursor, READ_DEADLINE, Rooms, Store, read_backoff, stopping, waited};
use crate::bot::error::Error;
use tokio::{sync::watch, time::timeout};

/// Read to the head of activity, for a first start. Failures wait with
/// backoff. A stop before the head is reached returns `None`.
pub async fn head<R: Rooms>(
	rooms: &R,
	store: &Store,
	mut shutdown: watch::Receiver<bool>,
) -> Result<Option<Cursor>, Error> {
	let mut cursor = Cursor::start();
	let (mut standard, mut slow) = (Backoff::standard(), Backoff::slow());
	let mut reported = None;
	loop {
		let read = tokio::select! {
			biased;
			() = stopping(&mut shutdown) => return Ok(None),
			read = timeout(READ_DEADLINE, rooms.events(&cursor, false)) => read,
		};
		let wait = match read {
			Ok(Ok(batch)) if batch.events.is_empty() => return Ok(Some(batch.cursor)),
			Ok(Ok(batch)) => {
				cursor = batch.cursor;
				continue;
			}
			Ok(Err(error)) => read_backoff(
				store,
				"reading to the head of activity",
				&error,
				[&mut standard, &mut slow],
				&mut reported,
			),
			Err(_) => standard.next(),
		};
		if !waited(wait, &mut shutdown).await {
			return Ok(None);
		}
	}
}
