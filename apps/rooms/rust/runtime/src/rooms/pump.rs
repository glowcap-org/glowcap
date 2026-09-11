//! One live room's message stream, folded into its view and forwarded to the
//! session's event stream until the room ends it.
use super::{
	events::ConversationEvent,
	worker::{Notice, Recorder},
	LiveRooms, Platform, PENDING_LINES,
};
use crate::session_commands::SessionCommands;
use rooms_application::room::{inbox::Message, message::ChangeKind};
use rooms_glowcap::client::room::Messages;
use std::{cell::RefCell, collections::VecDeque, rc::Rc};
use tokio::sync::{mpsc, watch};

#[allow(clippy::too_many_arguments)]
pub(super) async fn pump<P: Platform>(
	platform: P,
	id: String,
	epoch: u64,
	mut messages: Messages,
	shared: Rc<RefCell<LiveRooms<P>>>,
	events: mpsc::Sender<ConversationEvent>,
	notices: mpsc::Sender<Notice>,
	changed: watch::Sender<()>,
	commands: SessionCommands,
	recorder: Option<Recorder>,
) {
	let mut recordings = super::recording::Observations::default();
	let reason = loop {
		let next = tokio::select! {
			message = messages.next() => message,
			issue = recordings.next() => {
				if let Some(reason) = issue {
					let mut state = shared.borrow_mut();
					if state.rooms.get(&id).is_some_and(|live| live.epoch == epoch) {
						state.issues.insert(format!("archive:{id}"), reason);
						changed.send_replace(());
					}
				}
				continue;
			}
		};
		let mut message = match next {
			Ok(Some(message)) => message,
			Ok(None) => break None,
			Err(error) => break Some(error.to_string()),
		};
		let at = match platform.unix_millis() {
			Ok(at) => at,
			Err(error) => break Some(error.to_string()),
		};
		let line_id = message.marker.map(|marker| marker.id.get());
		let pending = {
			let mut state = shared.borrow_mut();
			let Some(live) = state.rooms.get_mut(&id).filter(|live| live.epoch == epoch) else {
				return;
			};
			rooms_application::session::room_view::apply(
				&mut live.view,
				message.presence.as_ref(),
				message.facts.as_ref(),
			);
			take_own_said(&mut live.pending, &live.nick, &message).map(|(_, pending)| pending)
		};
		let posted = match pending {
			Some(super::PendingLine::Wait(rx)) => rx.await.ok().flatten(),
			None => None,
		};
		let event = {
			let mut state = shared.borrow_mut();
			let LiveRooms {
				rooms,
				media,
				issues,
				history,
				..
			} = &mut *state;
			let Some(live) = rooms.get_mut(&id).filter(|live| live.epoch == epoch) else {
				return;
			};
			let editable = if let (Some(line_id), Some(line)) = (line_id, posted) {
				live.posted.insert(line_id, line);
				while live.posted.len() > PENDING_LINES {
					if let Some(oldest) = live.posted.keys().next().copied() {
						live.posted.remove(&oldest);
					} else {
						break;
					}
				}
				true
			} else {
				line_id.is_some_and(|line_id| live.posted.contains_key(&line_id))
			};
			let mut event = super::events::from_message(id.clone(), &message, editable, at);
			let mut retained = false;
			let mut history_failure = None;
			// A line's attachments ride the event as views over the media pool,
			// admitted on the session that delivered them. A refused admission
			// is an issue beside the line, never a line silently without files.
			if let Some(line) = line_id {
				let subject = format!("media:{id}");
				let files = match history.fold((id.clone(), line), &mut message) {
					Ok(previous) => media.receive(
						(id.clone(), line),
						live.room.client().session(),
						message.attachments.clone(),
						previous,
					),
					Err(error) => {
						history_failure = Some(error.clone());
						Err(error)
					}
				};
				match files {
					Ok(files) => {
						retained = true;
						event.files = files;
						issues.remove(&subject);
					}
					Err(error) => {
						issues.insert(subject, error);
					}
				}
			}
			if let Some(recorder) = &recorder {
				let subject = format!("archive:{id}");
				let files = if retained {
					crate::archive_recording::Files::Retained(event.files.clone())
				} else {
					crate::archive_recording::Files::Received {
						session: live.room.client().session().borrowed(),
						attachments: message.attachments.clone(),
					}
				};
				let recorded = if let Some(error) = history_failure {
					Err(error)
				} else {
					super::recording::record_room(
						recorder,
						&commands,
						live,
						&message,
						&mut event,
						files,
						&mut recordings,
					)
				};
				match recorded {
					Ok(()) => {
						issues.remove(&subject);
					}
					Err(error) => {
						issues.insert(subject, error);
					}
				}
			}
			event
		};
		// The event stream is the session's own; waiting on it is right, a
		// room ahead of its views has nowhere else to put a line.
		if events.send(event).await.is_err() {
			return;
		}
		changed.send_replace(());
	};
	let ended = shared
		.borrow()
		.rooms
		.get(&id)
		.filter(|live| live.epoch == epoch)
		.and_then(|live| live.room.ended_reason());
	let reason = reason
		.or_else(|| ended.clone())
		.unwrap_or_else(|| "the room message stream ended".to_owned());
	let terminal = ended
		.as_deref()
		.and_then(rooms_application::failure::Failure::parse)
		.is_some_and(|failure| failure.code == rooms_application::failure::FailureCode::RoomRetired);
	// tolerant: if the worker is gone the room is being retired with it.
	let _ = notices
		.send(Notice::Retired {
			id,
			epoch,
			reason,
			terminal,
		})
		.await;
}

/// A send intent is reconciled only by this membership's fresh-line echo.
/// Other members' lines and every mutation are authoritative room events, but
/// none of them is the outcome of the local FIFO intent at the head.
fn take_own_said<T, C>(pending: &mut VecDeque<T>, nick: &str, message: &Message<String, C>) -> Option<T> {
	(message.from == nick && message.marker.is_some_and(|marker| marker.kind == ChangeKind::Said))
		.then(|| pending.pop_front())
		.flatten()
}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_application::room::message::{LineId, LineMarker};

	fn message(from: &str, kind: ChangeKind, id: u64) -> Message<String, ()> {
		Message {
			from: from.into(),
			text: "line".into(),
			presence: None,
			facts: None,
			marker: Some(LineMarker {
				id: LineId::new(id).unwrap(),
				kind,
			}),
			attachments: vec![],
		}
	}

	#[test]
	fn peer_lines_and_mutations_do_not_steal_a_local_send_intent() {
		let mut pending = VecDeque::from(["local authority"]);

		assert_eq!(
			take_own_said(&mut pending, "alice", &message("bob", ChangeKind::Said, 1)),
			None
		);
		assert_eq!(
			take_own_said(&mut pending, "alice", &message("alice", ChangeKind::Edited, 2)),
			None
		);
		assert_eq!(pending.len(), 1);
		assert_eq!(
			take_own_said(&mut pending, "alice", &message("alice", ChangeKind::Said, 3)),
			Some("local authority")
		);
	}
}
