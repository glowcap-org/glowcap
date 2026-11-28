//! What every stage of the loop shares, and how it records what a call says
//! about the bot's access.
use super::think::{Reply, Unsaved};
use crate::bot::{
	config::Config,
	conversations::Conversations,
	harness::Harness,
	harness_sessions::HarnessSessions,
	ledger::{Ledger, TurnId},
	rooms::{Rooms, RoomsError, RoomsErrorKind},
	status::{Access, Activity, Facts},
	store::Store,
};
use std::{
	cell::{Cell, RefCell},
	collections::{BTreeMap, BTreeSet},
};
use tokio::sync::{Notify, watch};

/// Whether a [`Core`] writes `status.json`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Publishing {
	/// The serving loop, the one publisher of the status file.
	Status,
	/// The old access's settling, whose calls are no fact of the serving link.
	Nowhere,
}

/// What settling and delivering a line reads and records, and all the
/// old access's settling holds: the session, the ledger, and what the
/// calls say about the access.
pub struct Core<'a, R: Rooms> {
	pub rooms: &'a R,
	pub store: &'a Store,
	pub ledger: RefCell<Ledger>,
	pub facts: RefCell<Facts>,
	/// Woken when a failed call first finds the access paused or revoked, from
	/// a read or from a send, so the loop ends what is thinking at once.
	pub halted: Notify,
	/// Counts changes of `facts.access`, so a call that began before one
	/// can tell its answer is older than the access state.
	pub access_changes: Cell<u64>,
	/// The operations of the lines the session says another access sent, which
	/// delivery decides by their echo alone and never sends again.
	pub by_echo: BTreeSet<String>,
	publishing: Publishing,
}

impl<'a, R: Rooms> Core<'a, R> {
	pub fn new(
		rooms: &'a R,
		store: &'a Store,
		ledger: Ledger,
		facts: Facts,
		by_echo: BTreeSet<String>,
		publishing: Publishing,
	) -> Self {
		Self {
			rooms,
			store,
			ledger: ledger.into(),
			facts: facts.into(),
			halted: Notify::new(),
			access_changes: 0.into(),
			by_echo,
			publishing,
		}
	}

	/// Write the status file. Its ledger counts are what the ledger file
	/// holds: while the last ledger write may not have landed, they stay as
	/// the last settled ledger left them, until a write lands.
	pub fn publish(&self) {
		if self.publishing == Publishing::Nowhere {
			return;
		}
		let ledger = self.ledger.borrow();
		let mut facts = self.facts.borrow_mut();
		if !ledger.is_settled() {
			facts.publish(self.store);
			return;
		}
		facts.cursor = ledger.cursor().clone();
		facts.open_turns = ledger.open().len();
		facts.sending = ledger.sending();
		facts.replaced_lines = ledger.replaced().len() as u64;
		facts.unreleased_lines = ledger.left() as u64;
		facts.replaced_actions = ledger.replaced_actions().len() as u64;
		facts.replaced_unlisted = ledger.unlisted();
		facts.turns_finished = ledger.finished();
		facts.publish(self.store);
	}

	/// Record what a failed call says about the bot's access.
	pub fn access_failed(&self, during: Activity, error: &RoomsError) {
		let mut facts = self.facts.borrow_mut();
		if let Some(access) = access_of(error.kind) {
			if facts.access != access {
				// `notify_one` keeps a permit, so a change that lands between
				// two waits is not lost.
				self.halted.notify_one();
				self.access_changes.set(self.access_changes.get() + 1);
			}
			facts.access = access;
		}
		facts.failed(during, error);
	}

	/// A call succeeded, so access is active and that activity has recovered.
	pub fn access_active(&self, during: Activity) {
		let mut facts = self.facts.borrow_mut();
		if facts.access != Access::Active {
			self.access_changes.set(self.access_changes.get() + 1);
		}
		facts.access = Access::Active;
		facts.recovered(during);
	}

	/// A call that began when `access_changes` read `began` succeeded. It
	/// marks the access active only when nothing changed the access since,
	/// so a send already on its way when a read found the access paused
	/// does not open it again.
	pub fn access_active_since(&self, began: u64, during: Activity) {
		if self.access_changes.get() == began {
			self.access_active(during);
		} else {
			self.facts.borrow_mut().recovered(during);
		}
	}
}

/// Everything the serving loop shares: the [`Core`] and what only a turn of
/// the serving link reads.
pub struct Env<'a, R: Rooms> {
	core: Core<'a, R>,
	pub config: &'a Config,
	pub harness: &'a dyn Harness,
	pub harness_sessions: RefCell<HarnessSessions>,
	pub conversations: RefCell<Conversations>,
	/// What the runs of each turn still thinking share, by turn.
	pub replies: RefCell<BTreeMap<TurnId, Reply>>,
	/// The replies whose ledger write has not landed, by turn.
	pub unsaved: RefCell<BTreeMap<TurnId, Unsaved>>,
	/// Whether the link has answered and what its first answer stores is
	/// stored. Until then the stored link may not be the one serving, so no
	/// turn starts, no reply resumes, and no note is looked at. The engine
	/// sets it once, and everything that must wait, `Reaching` included, reads
	/// this one fact.
	linked: watch::Sender<bool>,
}

impl<'a, R: Rooms> Env<'a, R> {
	pub fn new(
		core: Core<'a, R>,
		config: &'a Config,
		harness: &'a dyn Harness,
		harness_sessions: HarnessSessions,
		conversations: Conversations,
	) -> Self {
		Self {
			core,
			config,
			harness,
			harness_sessions: harness_sessions.into(),
			conversations: conversations.into(),
			replies: RefCell::default(),
			unsaved: RefCell::default(),
			linked: watch::channel(false).0,
		}
	}

	/// Whether the link has answered and is stored: see [`Env::new`].
	pub fn is_linked(&self) -> bool {
		*self.linked.borrow()
	}

	/// The link has answered and is stored.
	pub(super) fn link_reached(&self) {
		self.linked.send_replace(true);
	}

	/// Wait until the link is reached, or forever when it never comes.
	pub async fn until_linked(&self) {
		let mut linked = self.linked.subscribe();
		// tolerant: the only error is a dropped sender, which cannot happen
		// while `self` holds it.
		let _ = linked.wait_for(|reached| *reached).await;
	}
}

impl<'a, R: Rooms> std::ops::Deref for Env<'a, R> {
	type Target = Core<'a, R>;
	fn deref(&self) -> &Core<'a, R> {
		&self.core
	}
}

/// What an access error says about the grant, when it says anything. This is
/// the one owner of the verdicts, for reads, sends, and opens alike:
///
/// | Answer | Access | What the bot does |
/// | --- | --- | --- |
/// | `Paused` | paused | Waits for the grantor to resume it, and the reply stays pending. |
/// | `Revoked` | revoked | Ends serving with the access error, the reply stays pending. |
/// | `Denied` | revoked | The same: the session no longer holds the access, because it was dropped or is out of scope, and no later answer changes that. |
/// | `Refused` | unchanged | The one request is given up, as it is the line's verdict. |
pub(crate) fn access_of(kind: RoomsErrorKind) -> Option<Access> {
	match kind {
		RoomsErrorKind::Paused => Some(Access::Paused),
		RoomsErrorKind::Revoked | RoomsErrorKind::Denied => Some(Access::Revoked),
		RoomsErrorKind::Refused | RoomsErrorKind::Unreachable | RoomsErrorKind::Uncertain | RoomsErrorKind::Exists => {
			None
		}
	}
}

/// Whether the table above says an answer of `kind` ended the access.
pub(crate) fn ends_serving(kind: RoomsErrorKind) -> bool {
	access_of(kind) == Some(Access::Revoked)
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn only_an_access_the_session_no_longer_holds_ends_serving() {
		for kind in [RoomsErrorKind::Revoked, RoomsErrorKind::Denied] {
			assert!(ends_serving(kind), "{kind:?}");
			assert_eq!(access_of(kind), Some(Access::Revoked), "{kind:?}");
		}
		for kind in [
			RoomsErrorKind::Paused,
			RoomsErrorKind::Refused,
			RoomsErrorKind::Unreachable,
			RoomsErrorKind::Uncertain,
			RoomsErrorKind::Exists,
		] {
			assert!(!ends_serving(kind), "{kind:?}");
		}
	}

	/// A turn the ledger may not have written is not in the status until the
	/// ledger file holds it.
	#[cfg(feature = "test-support")]
	#[test]
	fn the_status_counts_only_what_the_ledger_file_holds() {
		use crate::bot::{
			classify::{Seq, Trigger},
			ledger::Asked,
			rooms::{ConversationId, Cursor, Kind, files::Files},
		};
		let scratch = rooms_testing::scratch::Scratch::create("bot-env-unsettled");
		let store = Store::open(&scratch.join("bot")).unwrap();
		std::fs::create_dir_all(scratch.join("session")).unwrap();
		let rooms = Files::open(&scratch.join("session"));
		let asked = |seq: u64| Asked {
			conversation: ConversationId::new("c1"),
			kind: Kind::Direct,
			triggers: vec![Trigger {
				opening_until: None,
				scope: None,
				seq: Seq(seq),
				event: Cursor::new(format!("e{seq}")).unwrap(),
				line: format!("l{seq}"),
				from: None,
				text: "asked".into(),
				files: Vec::new(),
			}],
		};
		let ledger = Ledger::start(&store, Cursor::start()).unwrap();
		let core = Core::new(
			&rooms,
			&store,
			ledger,
			Facts::default(),
			BTreeSet::new(),
			Publishing::Status,
		);
		let open_turns = || {
			let status: serde_json::Value =
				serde_json::from_slice(&std::fs::read(store.root().join("status.json")).unwrap()).unwrap();
			status["open_turns"].clone()
		};
		core.ledger.borrow_mut().begin(&store, asked(1)).unwrap();
		core.publish();
		assert_eq!(open_turns(), 1);
		// A directory where the ledger file goes makes the rename fail, after
		// which the file may hold either document.
		let file = store.root().join("turns.json");
		std::fs::remove_file(&file).unwrap();
		std::fs::create_dir_all(file.join("block")).unwrap();
		core.ledger.borrow_mut().begin(&store, asked(2)).unwrap();
		core.publish();
		assert_eq!(open_turns(), 1, "a turn that may not be written is not published");
		std::fs::remove_dir_all(&file).unwrap();
		core.ledger.borrow_mut().durable(&store).unwrap();
		core.publish();
		assert_eq!(open_turns(), 2);
	}
}
