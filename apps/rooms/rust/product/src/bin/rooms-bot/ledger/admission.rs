//! Admission of incoming messages and clock occurrences. An occurrence has no
//! activity cursor. Its acknowledgement lives beside its turn in the same write.
use super::*;
use crate::bot::{gate, identity};
use crate::bot::{reminders, rooms::Scope};
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Scheduled {
	pub scope: Scope,
	pub operation: String,
	pub task: String,
}
/// After delivery only the occurrence id is needed to answer a clock retry.
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum Occurrence {
	Open(Scheduled),
	Finished(String),
}
impl Occurrence {
	fn operation(&self) -> &str {
		match self {
			Self::Open(task) => &task.operation,
			Self::Finished(operation) => operation,
		}
	}
	fn open(&self) -> Option<&Scheduled> {
		match self {
			Self::Open(task) => Some(task),
			Self::Finished(_) => None,
		}
	}
}
const MAX_ADMISSIONS: usize = MAX_OPEN + reminders::MAX_ACTIVE;

pub(super) fn validate(
	entries: &BTreeMap<TurnId, Occurrence>,
	rows: &BTreeMap<TurnId, Phase>,
	next: TurnId,
) -> Result<(), Error> {
	let mut seen = BTreeSet::new();
	if entries.len() > MAX_ADMISSIONS
		|| entries.iter().any(|(id, entry)| {
			*id >= next
				|| !seen.insert(entry.operation())
				|| match (entry.open(), rows.get(id).and_then(Phase::conversation)) {
					(Some(task), Some(room)) => task.scope.conversation() != room.as_str(),
					(None, None) => false,
					_ => true,
				}
		})
		|| rows.iter().any(
			|(id, phase)| matches!(phase, Phase::Running {asked,..} if asked.triggers.is_empty() != entries.contains_key(id)),
		) {
		return Err(Error::unreadable(FILE, "invalid scheduled turn admissions"));
	}
	Ok(())
}
impl Ledger {
	pub fn scheduled(&self, id: TurnId) -> Option<&Scheduled> {
		self.scheduled.get(&id).and_then(Occurrence::open)
	}

	/// A missing, stale, or misnamed turn can never fall through to an interactive helper.
	#[cfg(test)]
	pub fn scheduled_turn_in(root: &Path, id: TurnId, conversation: &str) -> Result<Option<Scope>, Error> {
		Ok(Self::turn_scopes_in(root, id, conversation)?.0)
	}
	pub fn turn_scopes_in(
		root: &Path,
		id: TurnId,
		conversation: &str,
	) -> Result<(Option<Scope>, Option<Scope>), Error> {
		let inactive = || Error::Usage(crate::bot::words::ONLY_WHILE_TURN.into());
		let doc = store::read_unleased_bounded::<Document>(root, FILE, MAX_LEDGER_BYTES)?.ok_or_else(inactive)?;
		let phase = doc.turns.into_iter().find(|r| r.id == id).map(|r| r.phase);
		let Some(Phase::Running { asked, .. }) = phase else {
			return Err(inactive());
		};
		let scope = doc
			.scheduled
			.get(&id)
			.and_then(Occurrence::open)
			.map(|entry| &entry.scope);
		if asked.conversation.as_str() != conversation {
			return Err(inactive());
		}
		if asked.triggers.is_empty() != scope.is_some() || scope.is_some_and(|s| s.conversation() != conversation) {
			return Err(Self::invariant("the turn does not own this conversation"));
		}
		let private = doc.private.get(&id).map(|speech| &speech.scope);
		if private.is_some_and(|p| {
			p.conversation() != conversation || asked.kind != crate::bot::rooms::Kind::Direct || scope.is_some()
		}) {
			return Err(Self::invariant("private turn has a different destination"));
		}
		Ok((scope.cloned(), private.cloned()))
	}
	pub(super) fn close_occurrence(&mut self, id: TurnId) {
		if let Some(entry @ Occurrence::Open(_)) = self.scheduled.get_mut(&id) {
			*entry = Occurrence::Finished(entry.operation().into());
		}
	}
	pub fn admitted(&self, operation: &str) -> bool {
		self.scheduled.values().any(|entry| entry.operation() == operation)
	}
	pub fn begin_scheduled(
		&mut self,
		store: &Store,
		requested: Scheduled,
		pending: &BTreeSet<String>,
	) -> Result<TurnId, Error> {
		self.commit(store, |next| {
			next.scheduled.retain(|id, entry| {
				pending.contains(entry.operation()) || next.rows.get(id).is_some_and(Phase::is_open)
			});
			if next.scheduled.len() >= MAX_ADMISSIONS
				|| !pending.contains(&requested.operation)
				|| next.admitted(&requested.operation)
			{
				return Err(Self::invariant("invalid scheduled occurrence admission"));
			}
			let asked = Asked {
				conversation: ConversationId::new(requested.scope.conversation()),
				kind: requested.scope.kind(),
				triggers: vec![],
			};
			let id = next.insert(asked)?;
			next.scheduled.insert(id, Occurrence::Open(requested));
			Ok(id)
		})
	}
	/// Whether another turn fits. One that does not waits until an earlier
	/// turn finishes, which never waits on a later trigger.
	pub fn has_room(&self) -> bool {
		self.open().len() < MAX_OPEN && self.rows.len() < MAX_ROWS
	}

	/// How many more triggers turn `id` can take: room up to [`MAX_TRIGGERS`]
	/// while its harness has never started, and none after.
	pub fn can_extend(&self, id: TurnId, trigger: &Trigger) -> bool {
		self.room_in(id) > 0
			&& matches!(self.phase(id), Some(Phase::Running {asked,..}) if asked.triggers.first().is_some_and(|previous| previous.scope == trigger.scope))
	}

	pub fn room_in(&self, id: TurnId) -> usize {
		if self.scheduled.contains_key(&id) || self.private.contains_key(&id) {
			return 0;
		}
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
		self.commit(store, |next| next.insert(asked))
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
		self.commit(store, |next| {
			let id = next.insert_phase(Phase::Sending {
				conversation,
				covered: Covered {
					opening_until: trigger.opening_until,
					..Covered::of(std::slice::from_ref(trigger))
				},
				content: Content::Availability,
				parts: vec![part],
				sent: 0,
				attempt: Attempt::Unsent,
			})?;
			if let Some(scope) = &trigger.scope {
				next.private
					.insert(id, crate::bot::direct_context::Speech::bound(scope.clone()));
			}
			Ok(id)
		})
	}

	fn insert(&mut self, asked: Asked) -> Result<TurnId, Error> {
		self.insert_phase(Phase::Running {
			asked,
			runs: Runs {
				spent: 0,
				progress: Progress::Ready,
			},
			note: None,
		})
	}

	fn insert_phase(&mut self, phase: Phase) -> Result<TurnId, Error> {
		if !self.has_room() {
			return Err(Self::invariant("a turn was begun past the ledger's bounds"));
		}
		let id = self.next_turn;
		self.next_turn = TurnId(
			id.0.checked_add(1)
				.ok_or_else(|| Self::invariant("turn numbers are exhausted"))?,
		);
		if phase.is_notice() {
			self.notices = self.notices.saturating_add(1);
		}
		self.rows.insert(id, phase);
		Ok(id)
	}
}

impl Ledger {
	pub fn private_speech(&self, id: TurnId) -> Option<&crate::bot::direct_context::Speech> {
		self.private.get(&id)
	}
	pub fn scope(&self, id: TurnId) -> Option<&Scope> {
		self.scheduled(id)
			.map(|scheduled| &scheduled.scope)
			.or_else(|| self.private.get(&id).map(|speech| &speech.scope))
	}
	pub fn bind_private(
		&mut self,
		store: &Store,
		id: TurnId,
		speech: crate::bot::direct_context::Speech,
	) -> Result<(), Error> {
		self.commit(store, |next| {
			if !matches!(next.phase(id), Some(Phase::Running {asked, ..}) if asked.kind == crate::bot::rooms::Kind::Direct && asked.conversation.as_str() == speech.scope.conversation()) {
				return Err(Self::invariant("a private post has a different destination than its turn"));
			}
			next.private.entry(id).or_insert(speech);
			Ok(())
		})?;
		self.durable(store)
	}
}
