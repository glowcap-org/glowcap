use super::Platform;
use crate::directories::session::DirectoryState;
use rooms_application::{
	session::checkpoint::{
		Checkpoint, DirectoryIntent,
		reconciliation::{Fact, Field, Id},
	},
	text::DocumentText,
};
use rooms_glowcap::client::directory::Directory;
use std::{cell::Cell, rc::Rc, time::Duration};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
	Waiting,
	Connecting,
	Connected,
	Retiring,
}
pub(super) struct Generation {
	pub id: Rc<Id>,
	pub scope: crate::session::commands::FactScope,
}
impl Generation {
	pub fn new(id: Rc<Id>) -> Rc<Self> {
		Rc::new(Self {
			id,
			scope: crate::session::commands::FactScope::new(),
		})
	}
}
pub(super) struct Wanted {
	pub id: Rc<Id>,
	pub locator: Id,
	pub nick: Field,
	pub nick_allocation: rooms_application::directory::registration::NicknameAllocation,
}
impl Wanted {
	fn new(intent: DirectoryIntent<'_>) -> Self {
		Self {
			id: Rc::new(intent.id.clone()),
			locator: intent.locator.clone(),
			nick: intent.nick.clone(),
			nick_allocation: intent.nick_allocation,
		}
	}
	pub fn matches(&self, intent: DirectoryIntent<'_>) -> bool {
		self.id.as_ref() == intent.id
			&& &self.locator == intent.locator
			&& &self.nick == intent.nick
			&& self.nick_allocation == intent.nick_allocation
	}
}
pub(super) struct Voucher {
	pub nick: String,
	pub bytes: Vec<u8>,
}
pub struct DirectoryRow<P: Platform> {
	pub(super) wanted: Wanted,
	pub(super) key: Rc<Generation>,
	pub(super) phase: Phase,
	pub(super) live: Option<DirectoryState<P>>,
	pub(super) held: Option<Directory<P>>,
	pub(super) granted_nick: String,
	pub(super) voucher: Option<Voucher>,
	pub(super) issue: Option<String>,
	pub(super) retry_at: P::Instant,
	pub(super) delay: Duration,
}
impl<P: Platform> DirectoryRow<P> {
	pub(super) fn new(intent: DirectoryIntent<'_>, now: P::Instant) -> Self {
		let wanted = Wanted::new(intent);
		Self {
			key: Generation::new(wanted.id.clone()),
			wanted,
			phase: Phase::Waiting,
			live: None,
			held: None,
			granted_nick: String::new(),
			voucher: None,
			issue: None,
			retry_at: now,
			delay: Duration::from_secs(1),
		}
	}
	pub fn id(&self) -> &Id {
		&self.wanted.id
	}
	pub fn phase(&self) -> Phase {
		self.phase
	}
	pub fn live(&self) -> Option<&DirectoryState<P>> {
		if self.phase == Phase::Connected {
			self.live.as_ref()
		} else {
			None
		}
	}
	pub fn issue(&self) -> Option<&str> {
		self.issue.as_deref()
	}
	pub(super) fn failed(&mut self, error: &str, now: P::Instant) {
		self.key.scope.retire();
		self.live = None;
		self.phase = Phase::Waiting;
		self.issue = Some(reason(error));
		self.retry_at = now + self.delay;
		self.delay = (self.delay * 2).min(Duration::from_secs(30));
	}
}
impl<P: Platform> Drop for DirectoryRow<P> {
	fn drop(&mut self) {
		self.key.scope.retire();
	}
}
pub struct Directories<P: Platform> {
	pub(super) staged: Option<Rc<super::entry::Staged<P>>>,
	entropy: Box<dyn crate::entropy::Entropy>,
	pub(super) directs: super::direct::Accepted,
	pub(super) rows: Vec<DirectoryRow<P>>,
	pub(super) failure: Option<String>,
	issues: Vec<(&'static str, DocumentText, String)>,
}
impl<P: Platform> Directories<P> {
	pub(super) fn new(checkpoint: &Checkpoint, now: P::Instant, entropy: Box<dyn crate::entropy::Entropy>) -> Self {
		Self {
			staged: None,
			entropy,
			directs: super::direct::Accepted::default(),
			rows: checkpoint
				.directories()
				.map(|intent| DirectoryRow::new(intent, now))
				.collect(),
			failure: None,
			issues: Vec::new(),
		}
	}
	pub(super) fn random_id(&mut self, prefix: &str) -> Result<Id, crate::Error> {
		crate::entropy::random_id(self.entropy.as_mut(), prefix)
	}
	pub fn rows(&self) -> &[DirectoryRow<P>] {
		&self.rows
	}
	pub fn failure(&self) -> Option<&str> {
		self.failure.as_deref()
	}
	pub fn fact_issues(&self) -> impl Iterator<Item = (&'static str, &DocumentText, &str)> {
		self.issues.iter().map(|(kind, id, error)| (*kind, id, error.as_str()))
	}
	pub(super) fn fact_issue(&mut self, fact: &Fact, error: Option<&str>) {
		let (kind, id) = fact.subject();
		let index = self.issues.iter().position(|(k, i, _)| *k == kind && i == id);
		match (index, error) {
			(Some(index), Some(error)) => self.issues[index].2 = reason(error),
			(Some(index), None) => {
				self.issues.remove(index);
			}
			(None, Some(error)) if self.issues.len() < crate::session::commands::MAX_PENDING_FACTS => {
				self.issues.push((kind, id.clone(), reason(error)))
			}
			(None, Some(_)) => self.failure = Some("session fact issue capacity exceeded".into()),
			(None, None) => {}
		}
	}
}
pub(super) fn reason(error: &str) -> String {
	rooms_application::session::diagnosis::directory(error)
		.unwrap_or_else(|| rooms_application::failure::reason_prefix(error))
		.into()
}

/// Charge queued and handed-out work until its owner retires it. Counting the
/// directory ID per notice conservatively bounds old generations retained by
/// a slow consumer while checkpoints keep changing.
#[derive(Default)]
pub(super) struct NoticeBudget(Rc<Cell<(usize, usize)>>);
pub(super) struct NoticePermit {
	budget: Rc<Cell<(usize, usize)>>,
	bytes: usize,
}
impl NoticeBudget {
	pub fn reserve(
		&self,
		key: &Generation,
		event: &rooms_application::directory::registration::Event,
	) -> Option<NoticePermit> {
		let bytes = core::mem::size_of::<super::RegistrationWork>()
			.saturating_add(key.id.text().heap_bytes())
			.saturating_add(event.peer.text().heap_bytes())
			.saturating_add(event.registration.as_str().len());
		let (count, held) = self.0.get();
		if count == super::REGISTRATION_LIMIT || bytes > super::REGISTRATION_BYTES.saturating_sub(held) {
			return None;
		}
		self.0.set((count + 1, held + bytes));
		Some(NoticePermit {
			budget: self.0.clone(),
			bytes,
		})
	}
}
impl Drop for NoticePermit {
	fn drop(&mut self) {
		let (count, bytes) = self.budget.get();
		self.budget.set((count - 1, bytes - self.bytes));
	}
}
