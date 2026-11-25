//! The typing notice a thinking turn shows, renewed while it thinks, and the
//! stop said once it is done. Every call to the session is bounded by the
//! bot's own send deadline, so a session that never answers holds no turn.
use super::super::{Env, deliver::within};
use crate::bot::{
	ledger::TurnId,
	rooms::{ConversationId, Rooms, RoomsError, SEND_DEADLINE, Typing},
	words::COULD_NOT_SHOW_TYPING,
};
use rooms_application::room::membership::TYPING_RENEW_MS;
use std::{future::Future, time::Duration};

/// Say one typing level.
pub(super) async fn notice<R: Rooms>(
	env: &Env<'_, R>,
	conversation: &ConversationId,
	typing: Typing,
) -> Result<(), RoomsError> {
	say(|| env.rooms.typing(conversation, typing)).await
}

/// Say a level through `call`, each try within `SEND_DEADLINE`. The session
/// paces typing notices, so a level said soon after another may be refused
/// with a short wait, and it is said once more after that wait while the wait
/// is shorter than a renewal.
async fn say<F: Future<Output = Result<(), RoomsError>>>(mut call: impl FnMut() -> F) -> Result<(), RoomsError> {
	match within(SEND_DEADLINE, call()).await {
		Err(RoomsError {
			retry_after: Some(wait),
			..
		}) if wait < Duration::from_millis(TYPING_RENEW_MS) => {
			tokio::time::sleep(wait).await;
			within(SEND_DEADLINE, call()).await
		}
		said => said,
	}
}

/// Show the bot as typing in `conversation` for as long as this future
/// lives, saying so again every `TYPING_RENEW_MS` because readers clear a
/// notice nobody renews. Each notice costs two snapshot reads and two calls
/// to the session.
pub(super) async fn typing<R: Rooms>(
	env: &Env<'_, R>,
	conversation: &ConversationId,
	id: TurnId,
) -> std::convert::Infallible {
	let mut logged = false;
	loop {
		if let Err(error) = notice(env, conversation, Typing::Show).await
			&& !logged
		{
			// tolerant: a missing notice changes nothing the turn does, the
			// next renewal tries again, and the log holds the first failure.
			env.store
				.log(&format!("turn {}: {COULD_NOT_SHOW_TYPING}: {error}", id.0));
			logged = true;
		}
		tokio::time::sleep(Duration::from_millis(TYPING_RENEW_MS)).await;
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::bot::rooms::RoomsErrorKind;
	use std::cell::Cell;

	/// A notice the session never answers fails as unreachable once the send
	/// deadline passes, so the turn that says it goes on. The clock is paused,
	/// so the deadline passes without waiting.
	#[tokio::test(start_paused = true)]
	async fn a_notice_the_session_never_answers_fails_at_the_send_deadline() {
		let calls = Cell::new(0);
		let said = tokio::time::timeout(
			SEND_DEADLINE * 2,
			say(|| {
				calls.set(calls.get() + 1);
				std::future::pending()
			}),
		)
		.await
		.expect("the notice outlasted its deadline");
		assert_eq!(said.map_err(|error| error.kind), Err(RoomsErrorKind::Unreachable));
		assert_eq!(calls.get(), 1, "the unanswered call was made");
	}
}
