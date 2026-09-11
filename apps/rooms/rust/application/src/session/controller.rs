//! Client command coordination. The durable session remains the authority;
//! this owner decides which refused intent may be retried and retains the
//! identity of an authority request whose answer was lost. Adapters execute
//! each selected step and release the operation after observing its outcome.
pub mod drafts;
pub mod editable;
pub mod events;
pub mod history;
mod intent;
pub mod operations;
use super::{command::Route, state::OperationId};
use crate::text::DocumentText;
use alloc::{collections::BTreeMap, rc::Rc, string::String, vec::Vec};
use core::cell::RefCell;
use intent::Intent;

/// A failed result request must not silently lose its retry identity. Refuse
/// new retained intent at these bounds; correcting an existing intent replaces
/// only that action's conversation slot. Active and retained holders share it.
/// Counts intent storage; the slot ceiling separately bounds map and id overhead.
pub const MAX_RETAINED_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_RETAINED_RESULTS: usize = 5 * 256;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
	Refresh,
	Issue,
	Resume,
	SettleCommand(u64),
	SettleResume(u64),
	Refused,
	Done,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Closed,
	Busy,
	Arguments,
	Full,
	Step,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Closed => "this attached Rooms controller is closed",
			Self::Busy => "a Rooms controller command is already being driven",
			Self::Arguments => "invalid Rooms controller command intent",
			Self::Full => "the Rooms controller's unanswered authority requests fill its retention budget",
			Self::Step => "unexpected Rooms controller command outcome",
		})
	}
}
impl core::error::Error for Error {}

struct Retained {
	intent: Rc<Intent>,
	id: OperationId,
}
struct Active {
	id: OperationId,
	track: bool,
	resume: Option<OperationId>,
}
#[derive(Default)]
struct State {
	closed: bool,
	active: Option<Active>,
	results: BTreeMap<(String, DocumentText), Retained>,
	bytes: usize,
}
impl State {
	fn ready(&self) -> Result<(), Error> {
		if self.closed {
			Err(Error::Closed)
		} else if self.active.is_some() {
			Err(Error::Busy)
		} else {
			Ok(())
		}
	}
}
#[derive(Default)]
pub struct Commands(Rc<RefCell<State>>);
impl Commands {
	/// The argument supplier is evaluated only for result-bearing commands.
	/// Ordinary commands do not copy their text into a second application heap.
	pub fn begin(
		&self,
		name: &str,
		candidate: OperationId,
		arguments: impl FnOnce(super::checkpoint::commands::results::Command) -> Result<Vec<DocumentText>, Error>,
	) -> Result<Operation, Error> {
		self.0.borrow().ready()?;
		let route = Route::parse(name).ok_or(Error::Arguments)?;
		// No borrow survives the adapter's argument supplier. Reentrant closure
		// or admission is observed before committing this operation's ownership.
		let supplied = if let Route::Result(command) = route {
			Some(Intent::new(name, command, arguments(command)?)?)
		} else {
			None
		};
		let mut state = self.0.borrow_mut();
		state.ready()?;
		let mut id = candidate;
		let intent = if let Some(intent) = supplied {
			let key = intent.key();
			if let Some(prior) = state.results.get(&key).filter(|prior| *prior.intent == intent) {
				id = prior.id.clone();
				Some(prior.intent.clone())
			} else {
				let old_bytes = state.results.get(&key).map_or(0, |old| old.intent.bytes());
				let bytes = state.bytes - old_bytes + intent.bytes();
				if bytes > MAX_RETAINED_BYTES
					|| (state.results.len() >= MAX_RETAINED_RESULTS && !state.results.contains_key(&key))
				{
					return Err(Error::Full);
				}
				let intent = Rc::new(intent);
				state.results.insert(
					key,
					Retained {
						intent: intent.clone(),
						id: id.clone(),
					},
				);
				state.bytes = bytes;
				Some(intent)
			}
		} else {
			None
		};
		state.active = Some(Active {
			id: id.clone(),
			track: !matches!(route, Route::Checkpoint(_)),
			resume: None,
		});
		Ok(Operation {
			owner: self.0.clone(),
			id,
			route,
			intent,
			retried: false,
			step: if matches!(route, Route::Result(_)) {
				Step::Refresh
			} else {
				Step::Issue
			},
			resuming: None,
		})
	}
	/// File transfers are external effects with their own typed protocol. Track
	/// their identity while the adapter drives them; never make them retryable.
	pub fn external(&self, id: OperationId) -> Result<ExternalOperation, Error> {
		let mut state = self.0.borrow_mut();
		state.ready()?;
		state.active = Some(Active {
			id,
			track: true,
			resume: None,
		});
		Ok(ExternalOperation(self.0.clone()))
	}
	pub fn driving(&self) -> Vec<OperationId> {
		let state = self.0.borrow();
		let Some(active) = &state.active else { return Vec::new() };
		let mut ids = Vec::new();
		if active.track {
			ids.push(active.id.clone());
		}
		if let Some(resume) = &active.resume {
			if !active.track || resume != &active.id {
				ids.push(resume.clone());
			}
		}
		ids
	}
	pub fn close(&self) {
		let mut state = self.0.borrow_mut();
		state.closed = true;
		state.results.clear();
		state.bytes = 0;
	}
}

/// External-effect custody ends only when its owning future retires.
pub struct ExternalOperation(Rc<RefCell<State>>);
impl Drop for ExternalOperation {
	fn drop(&mut self) {
		self.0.borrow_mut().active = None;
	}
}

pub struct Pending<'a> {
	pub id: &'a DocumentText,
	pub kind: &'a DocumentText,
	pub subject: &'a DocumentText,
}
/// A borrowed projection of room authority, supplied from the latest committed
/// checkpoint. It carries no live capability and never grants authority.
pub struct Authority<'a> {
	pub id: &'a DocumentText,
	pub link: Option<&'a DocumentText>,
	pub manager: Option<&'a DocumentText>,
	pub steward: Option<&'a DocumentText>,
}
impl<'a> From<super::checkpoint::RoomIntent<'a>> for Authority<'a> {
	fn from(room: super::checkpoint::RoomIntent<'a>) -> Self {
		Self {
			id: room.id.text(),
			link: room.link.map(|v| v.text()),
			manager: room.manager.map(|v| v.text()),
			steward: room.steward.map(|v| v.text()),
		}
	}
}

pub struct Operation {
	owner: Rc<RefCell<State>>,
	id: OperationId,
	route: Route,
	intent: Option<Rc<Intent>>,
	retried: bool,
	step: Step,
	resuming: Option<(OperationId, DocumentText)>,
}
impl Operation {
	pub fn id(&self) -> &OperationId {
		&self.id
	}
	pub fn step(&self) -> Step {
		self.step
	}
	pub fn resuming(&self) -> Option<(&OperationId, &DocumentText)> {
		self.resuming.as_ref().map(|(id, subject)| (id, subject))
	}
	/// A refresh selects at most one recoverable result. External effects need a
	/// reader's decision and are never resumed as a side effect of another act.
	pub fn refreshed<'a>(&mut self, pending: impl IntoIterator<Item = Pending<'a>>) -> Result<(), Error> {
		self.expect(Step::Refresh)?;
		if self.intent.is_some() {
			if let Some(pending) = pending.into_iter().find(|p| p.kind.as_str() != Some("external")) {
				let id = OperationId::new(pending.id.clone()).ok_or(Error::Arguments)?;
				self.owner.borrow_mut().active.as_mut().ok_or(Error::Step)?.resume = Some(id.clone());
				self.resuming = Some((id, pending.subject.clone()));
				self.step = Step::Resume;
				return Ok(());
			}
		}
		self.step = Step::Issue;
		Ok(())
	}
	pub fn resumed<'a>(&mut self, rooms: impl IntoIterator<Item = Authority<'a>>) -> Result<(), Error> {
		if !matches!(self.step, Step::SettleResume(_)) {
			return Err(Error::Step);
		}
		self.open()?;
		self.owner.borrow_mut().active.as_mut().ok_or(Error::Step)?.resume = None;
		self.resuming = None;
		if self.intent.as_ref().is_some_and(|intent| intent.held(rooms)) {
			self.complete();
		} else {
			self.step = Step::Issue;
		}
		Ok(())
	}
	/// Only a command refusal enters this edge. A failed read after an
	/// acknowledgement must drop the observation, never replay the command.
	pub fn refused(&mut self, reason: &str) -> Result<bool, Error> {
		self.expect(Step::Issue)?;
		let retry = !self.retried
			&& match self.route {
				Route::Checkpoint(_) => refusal(reason, super::state::Error::Revision, "session revision changed"),
				Route::Result(_) => refusal(
					reason,
					super::state::Error::ResultInFlight,
					"session already has a result-bearing effect in flight",
				),
				Route::Effect(_) => false,
			};
		if retry {
			self.retried = true;
			self.step = Step::Refresh;
		} else {
			self.step = Step::Refused;
		}
		Ok(retry)
	}
	/// Separate acknowledgement from observation: no refusal can retry a write
	/// after this edge, even if the subsequent snapshot read fails.
	pub fn acknowledged(&mut self, revision: u64) -> Result<(), Error> {
		self.open()?;
		let revision = super::state::SafeInteger::<false>::new(revision)
			.ok_or(Error::Arguments)?
			.get();
		self.step = match self.step {
			Step::Issue => Step::SettleCommand(revision),
			Step::Resume => Step::SettleResume(revision),
			_ => return Err(Error::Step),
		};
		Ok(())
	}
	/// The acknowledged revision has been observed in the authoritative feed.
	pub fn committed(&mut self) -> Result<(), Error> {
		if !matches!(self.step, Step::SettleCommand(_)) {
			return Err(Error::Step);
		}
		self.open()?;
		self.complete();
		Ok(())
	}
	fn complete(&mut self) {
		if let Some(intent) = &self.intent {
			let mut state = self.owner.borrow_mut();
			if let Some(prior) = state.results.remove(&intent.key()) {
				state.bytes -= prior.intent.bytes();
			}
		}
		self.step = Step::Done;
	}
	fn open(&self) -> Result<(), Error> {
		if self.owner.borrow().closed {
			Err(Error::Closed)
		} else {
			Ok(())
		}
	}
	fn expect(&self, step: Step) -> Result<(), Error> {
		self.open()?;
		if self.step == step {
			Ok(())
		} else {
			Err(Error::Step)
		}
	}
}
impl Drop for Operation {
	fn drop(&mut self) {
		self.owner.borrow_mut().active = None;
	}
}

fn refusal(reason: &str, native: super::state::Error, local: &str) -> bool {
	use alloc::string::ToString;
	// Native sessions report the shared state error. The remaining browser-local
	// session reports its older sentence; both travel inside binding diagnostics.
	let native = native.to_string();
	let mut segment = reason;
	loop {
		if segment == native
			|| segment == local
			|| (local == "session revision changed" && segment.starts_with("session revision changed from "))
		{
			return true;
		}
		let Some((_, rest)) = segment.split_once(": ") else {
			return false;
		};
		segment = rest;
	}
}
