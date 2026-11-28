//! Decide which row can hold an admitted request, and reserve one bounded
//! delivery row for the first refusal in a conversation's limit window.
use super::{
	Asked, Attempt, Content, Covered, Error, FILE, Ledger, MAX_OPEN, MAX_ROWS, MAX_TRIGGERS, Part, Phase, Progress,
	Runs, Store, TurnId, missing,
};
use crate::bot::{classify::Trigger, gate, identity, rooms::ConversationId};

impl Ledger {
	/// Whether another turn fits. One that does not waits until an earlier
	/// turn finishes, which never waits on a later trigger.
	pub fn has_room(&self) -> bool {
		self.open().len() < MAX_OPEN && self.rows.len() < MAX_ROWS
	}

	/// How many more triggers turn `id` can take: room up to [`MAX_TRIGGERS`]
	/// while its harness has never started, and none after.
	pub fn room_in(&self, id: TurnId) -> usize {
		match self.rows.get(&id) {
			Some(Phase::Running {
				asked,
				runs: Runs {
					spent: 0,
					progress: Progress::Ready,
				},
				note: None,
			}) => MAX_TRIGGERS.saturating_sub(asked.triggers.len()),
			_ => 0,
		}
	}

	/// Start a turn. The row is durable before the harness starts.
	pub fn begin(&mut self, store: &Store, asked: Asked) -> Result<TurnId, Error> {
		if asked.triggers.is_empty() || asked.triggers.len() > MAX_TRIGGERS {
			return Err(Error::state(FILE, "a turn's triggers are missing or past its bound"));
		}

		self.insert(
			store,
			Phase::Running {
				asked,
				runs: Runs {
					spent: 0,
					progress: Progress::Ready,
				},
				note: None,
			},
		)
	}

	pub fn notice(
		&mut self,
		store: &Store,
		conversation: ConversationId,
		trigger: &Trigger,
		until: u64,
	) -> Result<TurnId, Error> {
		let part = Part {
			operation: identity::new_action(store.root())?,
			text: gate::message(until),
		};
		self.insert(
			store,
			Phase::Sending {
				conversation,
				covered: Covered::of(std::slice::from_ref(trigger)),
				content: Content::Availability,
				parts: vec![part],
				sent: 0,
				attempt: Attempt::Unsent,
			},
		)
	}

	fn insert(&mut self, store: &Store, phase: Phase) -> Result<TurnId, Error> {
		if !self.has_room() {
			return Err(Error::state(FILE, "a turn was begun past the ledger's bounds"));
		}
		self.commit(store, |next| {
			let id = next.next_turn;
			next.next_turn = TurnId(id.0.saturating_add(1));
			if phase.is_notice() {
				next.notices = next.notices.saturating_add(1);
			}
			next.rows.insert(id, phase);
			Ok(id)
		})
	}

	/// Add triggers read later to a turn whose harness has not started.
	pub fn extend(&mut self, store: &Store, id: TurnId, triggers: Vec<Trigger>) -> Result<(), Error> {
		if triggers.is_empty() || triggers.len() > self.room_in(id) {
			return Err(Error::state(FILE, "triggers were added past a turn's room"));
		}
		self.commit(store, |next| match next.rows.get_mut(&id).ok_or_else(missing)? {
			Phase::Running { asked, .. } => {
				asked.triggers.extend(triggers);
				Ok(())
			}
			_ => Err(Error::state(FILE, "triggers were added to a turn that is not running")),
		})
	}
}
