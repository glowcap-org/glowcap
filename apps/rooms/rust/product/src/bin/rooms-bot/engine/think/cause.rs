//! Why a turn the agent could not answer was given up: what the room reads,
//! what the operator reads, and the one place that records the give-up.
use super::super::Env;
use crate::bot::{harness::FailureKind, ledger::TurnId, rooms::Rooms};

/// Why a turn the agent could not answer was given up. It holds what the room
/// reads and what the operator reads, and it is the one place that records the
/// give-up: the log line and `status` both come from [`Cause::record`].
#[derive(Clone)]
pub(super) struct Cause {
	pub(super) kind: Option<FailureKind>,
	/// The reason the failure line posts.
	pub(super) room: String,
	/// What the operator reads: the reason and the one next step.
	pub(super) operator: String,
}

impl Cause {
	/// A failure the agent reported. The room reads the kind's fixed label,
	/// never the agent's own words, and the operator reads it with the next
	/// step. The agent's words go to the log alone.
	pub(super) fn failed(kind: FailureKind) -> Self {
		let room = kind.label().to_owned();
		let operator = format!("{room}. {}", kind.next_step());
		Self {
			kind: Some(kind),
			room,
			operator,
		}
	}

	/// A give-up the bot decided, with the one `step` the operator takes, or
	/// none when nothing is theirs to do.
	pub(super) fn decided(kind: Option<FailureKind>, room: &str, step: Option<&str>) -> Self {
		let operator = match step.or_else(|| kind.map(FailureKind::next_step)) {
			Some(step) => format!("{room}. {step}"),
			None => room.to_owned(),
		};
		Self {
			kind,
			room: room.to_owned(),
			operator,
		}
	}

	/// Write the give-up to the log and to `status`.
	pub(super) fn record<R: Rooms>(&self, env: &Env<'_, R>, id: TurnId) {
		env.store.log(&format!("turn {}: gave up: {}", id.0, self.operator));
		env.facts.borrow_mut().gave_up(self.kind, &self.operator);
	}
}
