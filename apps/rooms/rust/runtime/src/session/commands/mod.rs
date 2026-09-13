//! Bounded durable session transactions and ordered live-fact retries.
//! Runtime callbacks observe commits synchronously and enqueue their own I/O.
mod budget;
mod scope;
use scope::FactGuard;
pub use scope::FactScope;
mod requests;
mod transactions;
mod worker;

use crate::{
	clock::Clock,
	documents::Documents,
	entropy::Entropy,
	session::bridge_secrets::BridgeSecrets,
	session::state::{DurableSession, LoadStatus, SessionView},
};
use budget::{Budget, Permit};
use rooms_application::{
	bridge::Answers,
	session::{
		checkpoint::{
			commands::{Command, Facts},
			reconciliation::Fact,
		},
		state::{Change, OperationId},
	},
	text::DocumentText,
};
use std::{cell::Cell, rc::Rc};
use tokio::sync::{mpsc, oneshot, watch};
pub use worker::SessionWorker;

pub const MAX_PENDING: usize = 64;
pub const MAX_RETAINED_BYTES: usize = 2 * 1024 * 1024;
/// Failed facts may not consume the entire command budget: a command may be
/// needed to change the state that made a retained fact fail.
pub const MAX_PENDING_FACTS: usize = 32;
pub const MAX_FACT_BYTES: usize = MAX_RETAINED_BYTES / 2;

pub trait SessionEvents {
	/// Settle effects that must succeed before a candidate becomes committed.
	/// The returned guard fences concurrent effects through the storage write.
	fn preparing(
		&mut self,
		checkpoint: &rooms_application::session::checkpoint::Checkpoint,
	) -> impl std::future::Future<Output = Result<impl Sized + 'static, crate::Error>>;

	/// A scoped read of current realization. Command admission drops this
	/// guard before its storage future is polled.
	fn facts(&self) -> impl Facts + '_;
	/// Publish each committed boundary, even when a later result fails. This
	/// callback owns observer error isolation; network work must be queued.
	fn changed(&mut self, change: Change, view: &SessionView);
	/// Finish effects that must precede another durable boundary. A refusal leaves
	/// the committed checkpoint authoritative; the next transaction retries this
	/// barrier before it may mutate state. Never hold a SessionView read over await.
	fn settled(&mut self, _view: &SessionView) -> impl std::future::Future<Output = Result<(), crate::Error>> {
		async { Ok(()) }
	}
	/// Set or clear the issue belonging to this exact fact's session subject.
	fn reconciliation_issue(&mut self, fact: &Fact, error: Option<&str>);
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AdmissionError {
	Closed,
	Full,
	ContextRequired,
	Retired,
}
impl std::fmt::Display for AdmissionError {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		f.write_str(match self {
			Self::Closed => "Rooms session command owner is closed",
			Self::Full => "Rooms session command queue is full",
			Self::ContextRequired => "runtime membership facts require their live producer scope",
			Self::Retired => "the runtime fact scope has retired",
		})
	}
}
impl std::error::Error for AdmissionError {}
pub struct Reply<T>(oneshot::Receiver<Result<T, crate::Error>>);
impl<T> Reply<T> {
	/// Dropping a reply abandons observation; already admitted work continues.
	pub async fn wait(self) -> Result<T, crate::Error> {
		self.0
			.await
			.map_err(|_| crate::Error::closed("Rooms session worker retired before replying"))?
	}
}
/// Queue custody is reserved before a binding defers its current turn. Dropping
/// this ticket releases capacity without executing or retaining the command.
pub struct Admission<T> {
	slot: mpsc::OwnedPermit<Envelope>,
	envelope: Envelope,
	reply: Reply<T>,
	admitting: Rc<Cell<bool>>,
}
impl<T> Admission<T> {
	pub fn send(self) -> Result<Reply<T>, AdmissionError> {
		if !self.admitting.get() {
			return Err(AdmissionError::Closed);
		}
		self.slot.send(self.envelope);
		Ok(self.reply)
	}
}

pub(crate) struct BridgePreparation {
	directory: DocumentText,
	scope: DocumentText,
	secrets: Answers,
	revision: Option<DocumentText>,
	custody: BridgeSecrets,
}
impl BridgePreparation {
	pub(crate) fn new(
		directory: DocumentText,
		scope: DocumentText,
		secrets: Answers,
		revision: Option<DocumentText>,
		custody: BridgeSecrets,
	) -> Self {
		Self {
			directory,
			scope,
			secrets,
			revision,
			custody,
		}
	}
}

#[derive(Clone)]
pub struct SessionCommands {
	tx: mpsc::Sender<Envelope>,
	budget: Budget,
	admitting: Rc<Cell<bool>>,
	stop: watch::Sender<bool>,
	/// The worker's own completion, retained for every concurrent closer.
	done: watch::Receiver<Option<Result<(), crate::Error>>>,
	view: SessionView,
}
impl SessionCommands {
	/// Load and finish stored result recovery before returning a publishable
	/// view. Drive the returned worker on the application's LocalSet.
	pub async fn open<S: Documents, G: Entropy, C: Clock>(
		mut state: DurableSession<S, G>,
		clock: C,
	) -> Result<(Self, SessionWorker<S, G, C>), crate::session::state::Error<S::Error>> {
		if let LoadStatus::RecoverResult(id) = state.load().await? {
			while state.finish_result(&id).await?.1.is_some() {}
		}
		let view = state.view();
		let (tx, rx) = mpsc::channel(MAX_PENDING);
		let (stop, stopping) = watch::channel(false);
		let (finished, done) = watch::channel(None);
		let admitting = Rc::new(Cell::new(true));
		let commands = Self {
			tx,
			budget: Budget::new(),
			admitting: admitting.clone(),
			stop,
			done,
			view: view.clone(),
		};
		let worker = SessionWorker::new(state, rx, stopping, finished, admitting, view, clock);
		Ok((commands, worker))
	}
	pub fn view(&self) -> SessionView {
		self.view.clone()
	}
	pub fn prepare_fact(&self, fact: Fact) -> Result<Admission<()>, AdmissionError> {
		if matches!(
			fact,
			Fact::DirectAccepted { .. } | Fact::DirectRegistrationRetired { .. }
		) || fact.room_context().is_some()
		{
			return Err(AdmissionError::ContextRequired);
		}
		self.fact(fact, None)
	}
	/// The producer owns this scope. Retirement cancels queued attempts and
	/// retries; an immutable candidate already admitted to storage may complete.
	/// Consumers must recheck their context after observing a durable reply.
	pub fn prepare_scoped_fact(&self, fact: Fact, scope: &FactScope) -> Result<Admission<()>, AdmissionError> {
		if !scope.current() {
			return Err(AdmissionError::Retired);
		}
		self.fact(fact, Some(scope))
	}
	/// `prepare_scoped_fact` that waits for capacity instead of refusing it.
	/// A full fact budget is backpressure, not a failure of the producer, so
	/// a worker that observes facts waits here and never ends over it. The
	/// wait ends with the scope's retirement or the owner's stop, which are
	/// the two answers this method can return besides an admission.
	pub async fn admit_scoped_fact(&self, fact: &Fact, scope: &FactScope) -> Result<Admission<()>, AdmissionError> {
		let mut stopping = self.stop.subscribe();
		loop {
			let released = self.budget.released();
			tokio::pin!(released);
			released.as_mut().enable();
			match self.prepare_scoped_fact(fact.clone(), scope) {
				Err(AdmissionError::Full) => {}
				outcome => return outcome,
			}
			if *stopping.borrow() {
				return Err(AdmissionError::Closed);
			}
			tokio::select! {
				_ = &mut released => {}
				_ = stopping.changed() => return Err(AdmissionError::Closed),
				_ = scope.retired() => return Err(AdmissionError::Retired),
			}
		}
	}
	fn fact(&self, fact: Fact, scope: Option<&FactScope>) -> Result<Admission<()>, AdmissionError> {
		let bytes = core::mem::size_of::<Envelope>()
			.saturating_add(fact.retained_bytes().saturating_sub(core::mem::size_of::<Fact>()));
		self.admit(bytes, true, |answer| Work::Fact {
			fact,
			answer,
			guard: scope.map(FactScope::guard),
		})
	}
	fn admit<T>(
		&self,
		bytes: usize,
		fact: bool,
		make: impl FnOnce(oneshot::Sender<Result<T, crate::Error>>) -> Work,
	) -> Result<Admission<T>, AdmissionError> {
		let (slot, permit) = self.reserve(bytes, fact)?;
		let (answer, reply) = oneshot::channel();
		Ok(Admission {
			slot,
			envelope: Envelope {
				work: make(answer),
				permit,
			},
			reply: Reply(reply),
			admitting: self.admitting.clone(),
		})
	}
	fn reserve(&self, bytes: usize, fact: bool) -> Result<(mpsc::OwnedPermit<Envelope>, Permit), AdmissionError> {
		if !self.admitting.get() {
			return Err(AdmissionError::Closed);
		}
		let permit = self.budget.reserve(bytes, fact).ok_or(AdmissionError::Full)?;
		let slot = self.tx.clone().try_reserve_owned().map_err(|_| AdmissionError::Full)?;
		Ok((slot, permit))
	}
	/// Stops admission immediately. Already sent commands drain; fact retries
	/// stop and unsynchronized facts make close fail. Unsent admission tickets
	/// cannot hold shutdown open and will refuse a later send.
	pub fn stop(&self) {
		self.admitting.set(false);
		self.stop.send_replace(true);
	}
	/// Stop admission and await all admitted work.
	pub async fn close(&self) -> Result<(), crate::Error> {
		self.stop();
		self.closed().await
	}
	pub async fn closed(&self) -> Result<(), crate::Error> {
		let mut done = self.done.clone();
		loop {
			if let Some(result) = done.borrow().clone() {
				return result;
			}
			done.changed()
				.await
				.map_err(|_| crate::Error::closed("Rooms session worker disappeared"))?;
		}
	}
}

struct Envelope {
	work: Work,
	permit: Permit,
}
enum Work {
	Transaction(transactions::Transaction),
	Fact {
		fact: Fact,
		answer: oneshot::Sender<Result<(), crate::Error>>,
		guard: Option<FactGuard>,
	},
}
