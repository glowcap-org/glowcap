//! One serialized, coalescing standing sender per actual membership. A new
//! checkpoint may replace the desired value while the preceding send settles.
use super::{Platform, intent::Intent, worker::Notice};
use crate::{Error, session::commands::SessionCommands};
use rooms_glowcap::client::room::Room;
use std::rc::Rc;
use tokio::sync::{mpsc, watch};

pub(super) async fn maintain<P: Platform>(
	room: Rc<Room<P>>,
	expected: Intent,
	epoch: u64,
	commands: SessionCommands,
	mut changes: watch::Receiver<()>,
	notices: mpsc::Sender<Notice>,
) {
	let mut sent = String::new();
	let result: Result<(), Error> = async {
		loop {
			changes.borrow_and_update();
			let desired = commands.view().read(|state| {
				let checkpoint = state.checkpoint()?;
				if !checkpoint
					.rooms()
					.filter_map(Intent::read)
					.any(|intent| expected.same_membership(&intent))
				{
					return Ok(None);
				}
				Ok::<_, Error>(checkpoint.room_standing(&expected.id).map(|value| {
					char::decode_utf16(value.utf16())
						.map(|unit| unit.unwrap_or(char::REPLACEMENT_CHARACTER))
						.collect::<String>()
				}))
			})??;
			let Some(desired) = desired else {
				return Ok(());
			};
			if desired != sent {
				room.away(&desired).await.map_err(Error::peer)?;
				sent = desired;
			}
			if changes.changed().await.is_err() {
				return Ok(());
			}
		}
	}
	.await;
	if let Err(reason) = result {
		// A failed send cannot be presented as an acknowledged standing.
		// Rejoining restores a known membership before its next attempt.
		let _ = notices
			.send(Notice::Retired {
				id: expected.id,
				epoch,
				reason: format!("room standing: {reason}"),
				terminal: false,
			})
			.await;
	}
}
