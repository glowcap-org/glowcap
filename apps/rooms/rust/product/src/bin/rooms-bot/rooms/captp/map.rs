//! The typed mapping between the attached view and the [`Rooms`](super::super)
//! seam. Nothing here decides policy. It names each view result by what the
//! bot does next.
use super::{dial::Failure, names::Names};
use crate::bot::rooms::{
	ActionSettled, Batch, Body, Change, ConversationId, Cursor, Handback, Incoming, Kind, Line, Outcome, RoomsError,
	RoomsErrorKind, Sender, Standing,
};
use rooms_application::{failure::Retry, room::inbox::ROOM};
use rooms_services::session::attached::{self, EffectStatus, Release};

fn error(kind: RoomsErrorKind, cause: impl ToString) -> RoomsError {
	RoomsError::new(kind, cause)
}

/// What the bot asks of the session, which decides what a failure means for
/// its next step.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ask {
	/// A read, which is idempotent.
	Read,
	/// A send, whose refusal is answered with a failure line instead of
	/// stalling its turn.
	Send,
	/// The question whose receipt an operation is, asked by a start that goes
	/// on only with an answer.
	Holder,
}

/// What each way a view call fails means for the next step. A refused,
/// invalid, or oversized request will not improve by repeating it. A peer
/// that answered with a failure is refused for a send and retried for a read,
/// because a read is idempotent and a refused send is answered with a failure
/// line instead of stalling its turn. A peer that asked for the same request
/// again soon, such as an admission or pacing refusal, is retried for a send
/// too, after the wait it advised, and so is an admission refusal that a
/// change of the session's state clears, such as a full receipt window,
/// because nothing was dispatched. The holder question is refused when no wait clears the peer's refusal (a
/// request the session will not answer, or retry advice of never or only
/// after the request changes), so the start ends with it. Every other failure
/// of it clears with time or says what the access is, and the start asks
/// again.
pub fn failure(cause: attached::Error, ask: Ask) -> RoomsError {
	use attached::Error::{
		Budget, Conflict, Exists, Forfeited, Input, Io, Malformed, Paused, Peer, Refused, Revoked, Stale, Uncertain,
		Unkeepable, Unkept, Unopened, Unreachable,
	};
	// Keeping a committed result can fail because the access changed. Apply
	// its access state and retry advice without treating the post as unsent.
	let held = match &cause {
		Unkept {
			receipt: attached::GiveBack::Held,
			cause,
			..
		}
		| Unopened {
			receipt: attached::GiveBack::Held,
			cause,
			..
		} => Some(cause.as_ref()),
		_ => None,
	};
	let reason = held.unwrap_or(&cause);
	let kind = match (reason, ask) {
		(Refused, _) => RoomsErrorKind::Denied,
		(Paused, _) => RoomsErrorKind::Paused,
		(Revoked, _) => RoomsErrorKind::Revoked,
		_ if held.is_some() => RoomsErrorKind::Unreachable,
		(Input(_) | Unkeepable { .. } | Budget | Unkept { .. } | Unopened { .. } | Forfeited { .. }, _)
		| (Exists(_), Ask::Holder) => RoomsErrorKind::Refused,
		(Exists(_), _) => RoomsErrorKind::Exists,
		(Peer(peer), Ask::Send) if !send_waits(peer) => RoomsErrorKind::Refused,
		(Peer(peer), Ask::Holder) if matches!(peer.retry(), Retry::Never | Retry::AfterRequestChange) => {
			RoomsErrorKind::Refused
		}
		(Uncertain { .. }, Ask::Read | Ask::Send) => RoomsErrorKind::Uncertain,
		(Uncertain { .. } | Unreachable(_) | Peer(_) | Conflict | Stale | Malformed(_) | Io(_), _) => {
			RoomsErrorKind::Unreachable
		}
	};
	RoomsError {
		retry_after: advised(reason),
		refused_before_dispatch: matches!(&cause, Peer(peer)
			if matches!(peer, attached::ClientError::Unsent(_)) || peer.admission_refusal().is_some()),
		..error(kind, cause)
	}
}

/// Whether a send the peer refused is tried again: a refusal that clears
/// soon, or an admission refusal that a change of state clears.
fn send_waits(peer: &attached::ClientError) -> bool {
	match peer.retry() {
		Retry::Soon => true,
		Retry::AfterStateChange => peer.admission_refusal().is_some(),
		Retry::Never | Retry::AfterRequestChange | Retry::AfterRequestOrStateChange => false,
	}
}

/// What the session answered when the bot gave a receipt back.
pub fn handback(answer: Release) -> Handback {
	match answer {
		Release::Released | Release::Kept => Handback::Taken,
		Release::Running => Handback::Running,
	}
}

/// The wait a peer's admission or pacing refusal advised.
fn advised(cause: &attached::Error) -> Option<std::time::Duration> {
	match cause {
		attached::Error::Peer(peer) => peer
			.admission_refusal()
			.and_then(|refusal| refusal.retry_advice())
			.map(|advice| std::time::Duration::from_millis(advice.retry_ms)),
		_ => None,
	}
}

/// How a failure of a look at an open reads. A peer refusal that only a
/// change of state clears, such as a timeout or a peer that is offline, is no
/// verdict on an open the session may still settle, so it reads as a read and
/// the look is tried again. Any other refusal is the session's verdict on the
/// open, as for a send.
pub fn open_ask(cause: &attached::Error) -> Ask {
	if matches!(cause, attached::Error::Peer(peer) if peer.retry() == Retry::AfterStateChange) {
		Ask::Read
	} else {
		Ask::Send
	}
}

/// A failed dial is the same kind of failure as a failed call.
pub fn dial_failure(cause: Failure) -> RoomsError {
	match cause {
		Failure::Platform(cause) => error(RoomsErrorKind::Unreachable, Failure::Platform(cause)),
		Failure::Attach(cause) => failure(cause, Ask::Read),
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

/// How the files of a committed action stand: a post's as its result records
/// them, and an action with none is whole.
fn standing(files: Option<attached::Files>) -> Standing {
	match files {
		None | Some(attached::Files::Complete) => Standing::Whole,
		// A post still filling when its verb ended stopped with it.
		Some(attached::Files::Incomplete(_) | attached::Files::Unfinished) => Standing::Partial,
	}
}

/// How the look at a listed action reads. A result nothing kept, whose
/// receipt was given back, is released, and every other failure is the
/// caller's to read.
pub fn listed(settled: Result<attached::Recovered, attached::Error>) -> Result<ActionSettled, attached::Error> {
	match settled {
		Ok(attached::Recovered::Gone) => Ok(ActionSettled::Gone),
		Ok(attached::Recovered::Committed { files }) => Ok(ActionSettled::Kept(standing(files))),
		Ok(attached::Recovered::Unapplied(_)) => Ok(ActionSettled::Unapplied),
		Ok(attached::Recovered::Pending) => Ok(ActionSettled::Pending),
		Ok(attached::Recovered::Unknown) => Ok(ActionSettled::Unknown),
		Err(
			attached::Error::Unkept {
				receipt: attached::GiveBack::Released,
				..
			}
			| attached::Error::Unopened {
				receipt: attached::GiveBack::Released,
				..
			}
			| attached::Error::Forfeited {
				receipt: attached::GiveBack::Released,
				..
			},
		) => Ok(ActionSettled::Released),
		Err(cause) => Err(cause),
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
		cause => Err(failure(cause, Ask::Send)),
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
/// only on a line this member sent. In a room it names every sender by
/// nickname, and the room itself by a reserved name.
fn sender(kind: attached::Kind, conversation: &str, from: Option<String>, names: &Names) -> Sender {
	match (kind, from) {
		(_, None) => Sender::Peer,
		(attached::Kind::Direct, Some(_)) => Sender::Own,
		(_, Some(name)) if name == ROOM => Sender::System,
		(_, Some(name)) if names.is_own(conversation, &name) => Sender::Own,
		(_, Some(name)) => Sender::Member(name),
	}
}

/// The cursor a session event or batch names, within the bound the bot keeps.
fn cursor_of(raw: String) -> Result<Cursor, RoomsError> {
	Cursor::new(raw).ok_or_else(|| {
		error(
			RoomsErrorKind::Unreachable,
			format!("the session gave a cursor longer than {} bytes", Cursor::MAX_BYTES),
		)
	})
}

fn incoming(
	event: attached::Event,
	names: &Names,
	scopes: &std::collections::BTreeMap<String, Sender>,
	origin: Option<(&str, &attached::Snapshot)>,
) -> Result<Incoming, RoomsError> {
	let cursor = cursor_of(event.cursor)?;
	let attached::Event {
		conversation,
		notice,
		mentions,
		attachments,
		..
	} = event;
	// A line the session does not number is a notice, not a member's line.
	let body = match notice {
		attached::Notice::Line(line) => match line.id {
			Some(id) => Body::Line(Line {
				id: id.to_string(),
				sender: if conversation.kind == attached::Kind::Direct && line.from.is_none() {
					scopes.get(cursor.as_str()).cloned().unwrap_or(Sender::System)
				} else if conversation.kind == attached::Kind::Direct
					&& line.from.is_some()
					&& let Some(operation) = line.operation
					&& let Some((grant, snapshot)) = origin
					&& let Some(scope) = crate::bot::rooms::Scope::held(grant, &conversation.id, snapshot)
				{
					Sender::OwnDirect { operation, scope }
				} else {
					sender(conversation.kind, &conversation.id, line.from, names)
				},
				change: match line.change {
					attached::Change::Said => Change::Said,
					attached::Change::Edited | attached::Change::Refiled | attached::Change::Withdrawn => {
						Change::Revised
					}
				},
				text: line.text,
				files: attachments,
				mentions,
			}),
			None => Body::Other,
		},
		attached::Notice::Other(_) => Body::Other,
	};
	Ok(Incoming {
		cursor,
		kind: kind(conversation.kind),
		conversation: ConversationId::new(conversation.id),
		body,
	})
}

/// Map one read. `names` holds this member's nicknames, and is read only
/// when the batch holds a room event.
pub fn batch(
	raw: attached::Batch,
	names: &Names,
	scopes: &std::collections::BTreeMap<String, Sender>,
	origin: Option<(&str, &attached::Snapshot)>,
) -> Result<Batch, RoomsError> {
	let cursor = cursor_of(raw.cursor)?;
	let events = raw
		.events
		.into_iter()
		.map(|event| incoming(event, names, scopes, origin))
		.collect::<Result<Vec<_>, _>>()?;
	Ok(Batch {
		events,
		cursor,
		gap: raw.gap,
		unavailable: raw.unavailable,
		unreadable: raw.unreadable,
	})
}

#[cfg(test)]
mod tests {
	use super::*;

	/// A listed action whose result nothing kept is released once its
	/// receipt was given back, and stays the caller's to read while the
	/// receipt still runs.
	#[test]
	fn a_listed_action_whose_result_was_forfeited_is_released() {
		let forfeited = |receipt| attached::Error::Forfeited {
			operation: "op".into(),
			base: 1,
			receipt,
		};
		assert!(matches!(
			listed(Err(forfeited(attached::GiveBack::Released))),
			Ok(ActionSettled::Released)
		));
		assert!(matches!(
			listed(Err(forfeited(attached::GiveBack::Running))),
			Err(attached::Error::Forfeited { .. })
		));
	}

	#[test]
	fn the_session_refusing_the_access_is_told_from_it_refusing_one_request() {
		for ask in [Ask::Read, Ask::Send, Ask::Holder] {
			assert_eq!(failure(attached::Error::Refused, ask).kind, RoomsErrorKind::Denied);
			assert_eq!(failure(attached::Error::Budget, ask).kind, RoomsErrorKind::Refused);
		}
		assert_eq!(failure(attached::Error::Paused, Ask::Send).kind, RoomsErrorKind::Paused);
		assert_eq!(
			failure(attached::Error::Revoked, Ask::Send).kind,
			RoomsErrorKind::Revoked
		);
	}

	#[test]
	fn a_held_commit_reports_the_access_that_prevented_keeping_it() {
		for (cause, kind) in [
			(attached::Error::Refused, RoomsErrorKind::Denied),
			(attached::Error::Revoked, RoomsErrorKind::Revoked),
			(attached::Error::Paused, RoomsErrorKind::Paused),
			(attached::Error::Conflict, RoomsErrorKind::Unreachable),
		] {
			let error = attached::Error::Unkept {
				operation: "op".into(),
				base: 1,
				cause: Box::new(cause),
				receipt: attached::GiveBack::Held,
				files: None,
			};
			let mapped = failure(error, Ask::Send);
			assert_eq!(mapped.kind, kind);
			assert!(!mapped.refused_before_dispatch);
		}
	}

	#[test]
	fn a_question_the_session_refuses_for_good_ends_the_start_and_one_that_clears_is_asked_again() {
		let unknown = attached::Error::Peer(attached::ClientError::RefusedObservation(
			"unknown recovery method".into(),
		));
		assert_eq!(failure(unknown, Ask::Holder).kind, RoomsErrorKind::Refused);
		assert_eq!(
			failure(attached::Error::Input("bad".into()), Ask::Holder).kind,
			RoomsErrorKind::Refused
		);
		assert_eq!(
			failure(attached::Error::Budget, Ask::Holder).kind,
			RoomsErrorKind::Refused
		);
		assert_eq!(
			failure(attached::Error::Refused, Ask::Holder).kind,
			RoomsErrorKind::Denied
		);
		assert_eq!(
			failure(attached::Error::Paused, Ask::Holder).kind,
			RoomsErrorKind::Paused
		);
		assert_eq!(
			failure(attached::Error::Revoked, Ask::Holder).kind,
			RoomsErrorKind::Revoked
		);
		assert_eq!(
			failure(attached::Error::Stale, Ask::Holder).kind,
			RoomsErrorKind::Unreachable
		);
		// The view reads a missed deadline as a lost connection, never as a peer's answer.
		let timeout = attached::Error::Unreachable(attached::ClientError::Timeout("asking"));
		assert_eq!(failure(timeout, Ask::Holder).kind, RoomsErrorKind::Unreachable);
	}

	#[test]
	fn a_release_answer_names_what_the_session_holds() {
		assert_eq!(handback(Release::Released), Handback::Taken);
		assert_eq!(handback(Release::Running), Handback::Running);
		assert_eq!(handback(Release::Kept), Handback::Taken);
	}

	/// A request the binding refused to admit never left, so a first send of
	/// it goes out again under a new operation rather than being looked at.
	#[test]
	fn a_binding_refusal_before_sending_is_refused_before_dispatch() {
		let unsent = attached::Error::Peer(attached::ClientError::Unsent(Box::new(glowcap::loam::refusal(
			"the binding refused admission",
		))));
		assert!(failure(unsent, Ask::Send).refused_before_dispatch);
		let timeout = attached::Error::Unreachable(attached::ClientError::Timeout("sending"));
		assert!(!failure(timeout, Ask::Send).refused_before_dispatch);
	}

	#[test]
	fn a_timeout_is_no_refusal_of_an_open_the_session_may_still_settle() {
		// The view reports a missed deadline as a lost connection, which says
		// nothing of the open, so it reads as unreachable and not as a refusal.
		let timeout = attached::Error::Unreachable(attached::ClientError::Timeout("settling an open"));
		let ask = open_ask(&timeout);
		assert_eq!(failure(timeout, ask).kind, RoomsErrorKind::Unreachable);
		let refusal = attached::Error::Peer(attached::ClientError::RefusedObservation("no".into()));
		assert_eq!(open_ask(&refusal), Ask::Send);
		assert_eq!(failure(refusal, Ask::Send).kind, RoomsErrorKind::Refused);
	}

	#[test]
	fn a_peer_answer_with_retry_advice_is_unreachable_after_the_wait_it_advised() {
		use rooms_application::admission::{Class, Refusal};
		let reason = Refusal::Throttled {
			class: Class::Read,
			retry_ms: 1500,
		}
		.line(None);
		let cause = attached::Error::Peer(attached::ClientError::RefusedObservation(reason));
		let mapped = failure(cause, Ask::Read);
		assert_eq!(mapped.kind, RoomsErrorKind::Unreachable);
		assert_eq!(mapped.retry_after, Some(std::time::Duration::from_millis(1500)));
	}
}
