//! The typed mapping between the attached view and the [`Rooms`](super::super)
//! seam. Nothing here decides policy. It names each view result by what the
//! bot does next.
use super::{dial::Failure, names::Names};
use crate::bot::rooms::{
	Batch, Body, Change, ConversationId, Cursor, Incoming, Kind, Line, Outcome, RoomsError, RoomsErrorKind, Sender,
};
use rooms_application::{failure::Retry, room::inbox::ROOM};
use rooms_services::session::attached::{self, EffectStatus};

fn error(kind: RoomsErrorKind, cause: impl ToString) -> RoomsError {
	RoomsError::new(kind, cause)
}

/// What each way a view call fails means for the next step. A refused,
/// invalid, or oversized request will not improve by repeating it. A peer
/// that answered with a failure is refused for a send and retried for a read,
/// because a read is idempotent and a refused send is answered with a failure
/// line instead of stalling its turn. A peer that asked for the same request
/// again soon, such as an admission or pacing refusal, is retried for a send
/// too, after the wait it advised, because nothing was dispatched.
pub fn failure(cause: attached::Error, sending: bool) -> RoomsError {
	use attached::Error::{
		Budget, Conflict, Exists, Input, Io, Malformed, Paused, Peer, Refused, Revoked, Stale, Uncertain, Unkept,
		Unopened, Unreachable,
	};
	let kind = match &cause {
		Refused | Input(_) | Budget | Unkept { .. } | Unopened { .. } => RoomsErrorKind::Refused,
		Peer(peer) if sending && peer.retry() != Retry::Soon => RoomsErrorKind::Refused,
		Exists(_) => RoomsErrorKind::Exists,
		Paused => RoomsErrorKind::Paused,
		Revoked => RoomsErrorKind::Revoked,
		Uncertain { .. } => RoomsErrorKind::Uncertain,
		Unreachable(_) | Peer(_) | Conflict | Stale | Malformed(_) | Io(_) => RoomsErrorKind::Unreachable,
	};
	let retry_after = match &cause {
		Peer(peer) => peer
			.admission_refusal()
			.and_then(|refusal| refusal.retry_advice())
			.map(|advice| std::time::Duration::from_millis(advice.retry_ms)),
		_ => None,
	};
	RoomsError {
		retry_after,
		..error(kind, cause)
	}
}

/// A failed dial is the same kind of failure as a failed call.
pub fn dial_failure(cause: Failure) -> RoomsError {
	match cause {
		Failure::Platform(cause) => error(RoomsErrorKind::Unreachable, Failure::Platform(cause)),
		Failure::Attach(cause) => failure(cause, false),
	}
}

/// Whether a failure means the connection itself is gone, so the next call
/// must dial again.
pub fn connection_lost(cause: &attached::Error) -> bool {
	matches!(
		cause,
		attached::Error::Unreachable(_) | attached::Error::Uncertain { .. }
	)
}

/// How a receipt's status reads to the bot. Nothing was committed for a
/// conflict or an unsent command, so a new operation may send the line again.
pub fn outcome(status: EffectStatus) -> Outcome {
	match status {
		EffectStatus::Committed => Outcome::Committed,
		EffectStatus::Conflict | EffectStatus::Unsent => Outcome::Conflict,
		EffectStatus::Pending => Outcome::Pending,
		EffectStatus::Unknown => Outcome::Unknown,
	}
}

/// How a failed look at a receipt reads. The session refuses a look at an
/// operation it holds no receipt for, and that refusal carries no code, so
/// any refusal of a look that waiting will not clear is read as no receipt.
/// The bot then reads activity before it decides anything, so a refusal
/// read this way never posts a line on its own.
pub fn observed(cause: attached::Error) -> Result<Outcome, RoomsError> {
	match cause {
		attached::Error::Peer(refusal) if refusal.retry() != Retry::Soon => Ok(Outcome::Absent),
		cause => Err(failure(cause, true)),
	}
}

/// Whether one activity event is the echo of `operation` in `conversation`.
pub fn echoes(event: &attached::Event, conversation: &str, operation: &str) -> bool {
	event.conversation.id == conversation
		&& matches!(&event.notice, attached::Notice::Line(line) if line.operation.as_deref() == Some(operation))
}

fn kind(kind: attached::Kind) -> Kind {
	match kind {
		attached::Kind::Room => Kind::Room,
		attached::Kind::Direct => Kind::Direct,
		attached::Kind::Directory | attached::Kind::Discovery => Kind::Other,
	}
}

/// The sender of a line. In a direct conversation the session names the sender
/// only on a line this member sent, and the other person's nickname comes from
/// the workspace. In a room it names every sender by nickname, and the room
/// itself by a reserved name.
fn sender(kind: attached::Kind, conversation: &str, from: Option<String>, names: &Names) -> Sender {
	match (kind, from) {
		(attached::Kind::Direct, None) => Sender::Peer(names.peer(conversation)),
		(_, None) => Sender::Peer(None),
		(attached::Kind::Direct, Some(_)) => Sender::Own,
		(_, Some(name)) if name == ROOM => Sender::System,
		(_, Some(name)) if names.is_own(conversation, &name) => Sender::Own,
		(_, Some(name)) => Sender::Member(name),
	}
}

fn incoming(event: attached::Event, names: &Names) -> Result<Incoming, RoomsError> {
	let cursor = Cursor::new(event.cursor).ok_or_else(|| {
		error(
			RoomsErrorKind::Unreachable,
			format!("the session gave a cursor longer than {} bytes", Cursor::MAX_BYTES),
		)
	})?;
	let attached::Event {
		conversation,
		notice,
		mentions,
		attachments,
		..
	} = event;
	// A line the session does not number is a notice, not a member's line.
	let body = match notice {
		attached::Notice::Line(line) if line.id.is_some() => Body::Line(Line {
			id: line.id.map(|id| id.to_string()).unwrap_or_default(),
			sender: sender(conversation.kind, &conversation.id, line.from, names),
			change: match line.change {
				attached::Change::Said => Change::Said,
				attached::Change::Edited | attached::Change::Refiled | attached::Change::Withdrawn => Change::Revised,
			},
			text: line.text,
			files: attachments,
			mentions,
		}),
		attached::Notice::Line(_) | attached::Notice::Other(_) => Body::Other,
	};
	Ok(Incoming {
		cursor,
		kind: kind(conversation.kind),
		conversation: ConversationId::new(conversation.id),
		body,
	})
}

/// Map one read. `names` holds the workspace's nicknames, and is read only
/// when the batch holds a line.
pub fn batch(raw: attached::Batch, names: &Names) -> Result<Batch, RoomsError> {
	let cursor = Cursor::new(raw.cursor).ok_or_else(|| {
		error(
			RoomsErrorKind::Unreachable,
			format!("the session gave a cursor longer than {} bytes", Cursor::MAX_BYTES),
		)
	})?;
	let events = raw
		.events
		.into_iter()
		.map(|event| incoming(event, names))
		.collect::<Result<Vec<_>, _>>()?;
	Ok(Batch {
		events,
		cursor,
		gap: raw.gap,
		unavailable: raw.unavailable,
		unreadable: raw.unreadable,
	})
}
