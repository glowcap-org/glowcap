//! The session owns actual tasks. Views only request retry or retirement.
//! Startup permits cap retained candidates independently of live callbacks.
use crate::Error;
use rooms_application::content::session::custody;
type Result<T> = core::result::Result<T, Error>;
use rooms_glowcap::client::Tasks;
use std::{
	cell::{Cell, RefCell},
	collections::BTreeMap,
	rc::{Rc, Weak},
};
use tokio::sync::{Notify, watch};

const MAX_STARTING: usize = 4;
// Failed cleanup still owns a task and its exact upstream target. Charge it
// against the complete workspace population before admitting another start.
const MAX_RETAINED: usize = rooms_application::content::session::workspace::MAX_DIRECTORIES
	+ rooms_application::content::session::workspace::MAX_CONVERSATIONS;

pub(in crate::session::managed) struct Budget<P: Tasks> {
	starting: Cell<usize>,
	startup_available: Notify,
	tasks: RefCell<BTreeMap<String, Running<P>>>,
}
struct Running<P: Tasks> {
	// Only a known-absent admission may replace this effect identity. The
	// registry key still owns the worker and its one exact retirement target.
	admission: String,
	_task: P::Task,
	// The owning worker's exact upstream identity, when admission must exclude
	// aliases. This is custody for cleanup, never another authority inventory.
	target: Option<glowcap::Ref>,
	stop: watch::Sender<bool>,
	ready: watch::Sender<Option<Result<()>>>,
	// Closing the view cannot turn a failed cleanup wait into a ready loop.
	retry: watch::Sender<u64>,
	ended: watch::Sender<Option<Result<()>>>,
	retirement: Option<Rc<super::retirement::Owner>>,
}
/// Local control reads the live registration worker through its exact inbox.
#[derive(Clone)]
pub struct DirectoryRegistrations<P: Tasks>(Weak<Budget<P>>);

impl<P: Tasks> DirectoryRegistrations<P> {
	pub(super) fn new(budget: &Rc<Budget<P>>) -> Self {
		Self(Rc::downgrade(budget))
	}
	/// A replacement callback or a retiring worker cannot confirm readiness.
	/// Only an explicit request can retry an occupied name.
	pub fn ready(&self, inbox: custody::FieldKey<custody::DirectoryInbox>, retry: bool) -> Result<bool> {
		let budget = self.0.upgrade().ok_or_else(|| Error::closed("Session is closed"))?;
		let tasks = budget.tasks.borrow();
		let worker = tasks.values().find(|worker| {
			worker
				.retirement
				.as_ref()
				.is_some_and(|owner| owner.exact_registration == Some(inbox))
		});
		let Some(worker) = worker else { return Ok(false) };
		if *worker.stop.borrow() || worker.ended.borrow().is_some() {
			return Ok(false);
		}
		let status = worker.ready.borrow().clone();
		match status {
			Some(Err(error)) if retry && error.refused_nickname() => {
				worker.ready.send_replace(None);
				worker
					.retry
					.send_modify(|generation| *generation = generation.wrapping_add(1));
				Ok(false)
			}
			Some(result) => result.map(|()| true),
			None => Ok(false),
		}
	}
}

impl<P: Tasks> Default for Budget<P> {
	fn default() -> Self {
		Self {
			starting: Cell::new(0),
			startup_available: Notify::new(),
			tasks: RefCell::new(BTreeMap::new()),
		}
	}
}
impl<P: Tasks> Budget<P> {
	/// The existing membership registry owns sibling lifetime accounting. Mark
	/// this retirement before inspecting siblings, so simultaneous final closes
	/// elect at least one closer without closing a still-live conversation.
	pub(super) async fn close_direct_connection(&self, owner: &super::retirement::Owner) -> Result<()> {
		owner.begin_close();
		let Some(session) = owner.connection() else {
			return Ok(());
		};
		let shared = self.tasks.borrow().values().any(|worker| {
			worker.retirement.as_ref().is_some_and(|other| {
				!other.closing() && other.connection().is_some_and(|peer| session.same_connection(&peer))
			})
		});
		if shared {
			return Ok(());
		}
		session.close(glowcap::PendingWork::Cancel).await.map_err(Error::from)
	}
	pub(in crate::session::managed) fn active(&self) -> usize {
		self.tasks.borrow().len() + self.starting.get()
	}
	pub(in crate::session::managed) fn all_closing(&self) -> bool {
		self.starting.get() == 0 && self.tasks.borrow().values().all(|worker| *worker.stop.borrow())
	}
	pub(in crate::session::managed) fn retry_closing(&self) {
		for worker in self.tasks.borrow().values() {
			if *worker.stop.borrow() {
				worker.stop.send_replace(true);
			}
		}
	}
	pub(in crate::session::managed) fn contains(&self, id: &str) -> bool {
		self.tasks.borrow().contains_key(id)
	}
	pub(in crate::session::managed) fn contains_target(&self, target: &glowcap::Ref) -> bool {
		self.tasks
			.borrow()
			.values()
			.any(|worker| worker.target.as_ref() == Some(target))
	}
	pub(in crate::session::managed) fn identify(&self, id: &str, target: glowcap::Ref) -> Result<()> {
		let mut tasks = self.tasks.borrow_mut();
		let worker = tasks
			.get_mut(id)
			.ok_or_else(|| Error::closed("spawned worker is not retained"))?;
		if worker.target.replace(target).is_some() {
			return Err(Error::busy("spawned worker already has a target"));
		}
		Ok(())
	}
	pub(in crate::session::managed) fn retirement(&self, id: &str) -> Option<Rc<super::retirement::Owner>> {
		let tasks = self.tasks.borrow();
		// Generated worker names contain no colon; a fresh, known-absent
		// attempt appends its ordinal. Lookup stays logarithmic on chat admission.
		let key = id.rsplit_once(':').map_or(id, |(worker, _)| worker);
		tasks
			.get(key)
			.filter(|worker| worker.admission == id)
			.and_then(|worker| worker.retirement.clone())
	}
	/// The live worker is still acquiring its own admission. Once the worker
	/// fails, becomes ready, or starts closing, its receipt cannot justify
	/// delaying a different request.
	pub(in crate::session::managed) fn acquiring(&self, admission: &str) -> bool {
		let key = admission.rsplit_once(':').map_or(admission, |(worker, _)| worker);
		self.tasks.borrow().get(key).is_some_and(|worker| {
			worker.admission == admission
				&& worker.retirement.is_some()
				&& !*worker.stop.borrow()
				&& worker.ready.borrow().is_none()
				&& worker.ended.borrow().is_none()
		})
	}
	pub(in crate::session::managed) fn worker_retirement(&self, id: &str) -> Option<Rc<super::retirement::Owner>> {
		self.tasks.borrow().get(id).and_then(|worker| worker.retirement.clone())
	}
	pub(super) fn select_admission(&self, worker: &str, admission: &str) -> Result<()> {
		let mut tasks = self.tasks.borrow_mut();
		let selected = tasks
			.get_mut(worker)
			.ok_or_else(|| Error::closed("startup owner is not retained"))?;
		selected.admission.clear();
		selected.admission.push_str(admission);
		Ok(())
	}
	pub(in crate::session::managed) async fn close_all(&self) -> Result<()> {
		if self.starting.get() != 0 {
			return Err(Error::busy("session activity startup is still pending"));
		}
		loop {
			let next = self.tasks.borrow().values().next().map(|worker| {
				worker.ended.send_replace(None);
				let ended = worker.ended.subscribe();
				worker.stop.send_replace(true);
				ended
			});
			let Some(ended) = next else { return Ok(()) };
			super::outcome(ended).await?;
		}
	}
}
pub(super) struct Charge<P: Tasks> {
	budget: Weak<Budget<P>>,
	id: String,
	active: Rc<Cell<bool>>,
}
impl<P: Tasks> Charge<P> {
	pub(super) fn new(budget: &Rc<Budget<P>>, id: String, active: Rc<Cell<bool>>) -> Self {
		Self {
			budget: Rc::downgrade(budget),
			id,
			active,
		}
	}
}
impl<P: Tasks> Drop for Charge<P> {
	fn drop(&mut self) {
		self.active.set(false);
		if let Some(budget) = self.budget.upgrade() {
			budget.tasks.borrow_mut().remove(&self.id);
		}
	}
}
pub(in crate::session::managed) struct Permit<P: Tasks>(Weak<Budget<P>>);
impl<P: Tasks> Permit<P> {
	pub(in crate::session::managed) fn reserve(budget: &Rc<Budget<P>>) -> Result<Self> {
		if budget.tasks.borrow().len() + budget.starting.get() >= MAX_RETAINED {
			return Err(Error::exhausted("Retained membership capacity is exhausted"));
		}
		if budget.starting.get() == MAX_STARTING {
			return Err(Error::busy("Membership startup capacity is exhausted"));
		}
		Ok(Self::charge(budget))
	}

	/// An explicitly retried worker already has a retained task slot. It only
	/// needs one active startup slot before preparing its next candidate.
	pub(super) async fn resume(budget: &Rc<Budget<P>>) -> Self {
		while budget.starting.get() == MAX_STARTING {
			budget.startup_available.notified().await;
		}
		Self::charge(budget)
	}

	fn charge(budget: &Rc<Budget<P>>) -> Self {
		budget.starting.set(budget.starting.get() + 1);
		Self(Rc::downgrade(budget))
	}
}

#[cfg(test)]
mod tests;
impl<P: Tasks> Drop for Permit<P> {
	fn drop(&mut self) {
		if let Some(budget) = self.0.upgrade() {
			budget.starting.set(budget.starting.get() - 1);
			budget.startup_available.notify_one();
		}
	}
}

pub(in crate::session::managed) struct Signals {
	pub ready: watch::Sender<Option<Result<()>>>,
	pub stopping: watch::Receiver<bool>,
	pub retrying: watch::Receiver<u64>,
	pub finished: watch::Sender<Option<Result<()>>>,
}
/// One task owner serves both membership and workspace observation. Views
/// request retirement. The registry retains the actual task until its cleanup
/// future succeeds. The running future holds only a weak registry charge.
pub(in crate::session::managed) fn spawn<P, F, W>(
	platform: &P,
	budget: &Rc<Budget<P>>,
	id: String,
	retirement: Option<Rc<super::retirement::Owner>>,
	run: F,
) -> super::Membership<P>
where
	P: Tasks + 'static,
	F: FnOnce(Signals) -> W + 'static,
	W: std::future::Future<Output = Result<()>> + 'static,
{
	assert!(!budget.contains(&id), "activity identity admitted before spawn");
	let (stop, stopping) = watch::channel(false);
	let (retry, retrying) = watch::channel(0);
	let (ready, _) = watch::channel(None);
	let readiness = ready.clone();
	let (finished, _) = watch::channel(None);
	let ended = finished.clone();
	let active = Rc::new(Cell::new(true));
	let charge = Charge::new(budget, id.clone(), active.clone());
	let completion = finished.clone();
	let task = platform.spawn(async move {
		let outcome = run(Signals {
			ready,
			stopping,
			retrying,
			finished,
		})
		.await;
		drop(charge);
		completion.send_replace(Some(outcome));
	});
	let worker = Running {
		admission: id.clone(),
		_task: task,
		target: None,
		stop: stop.clone(),
		ready: readiness.clone(),
		retry: retry.clone(),
		ended: ended.clone(),
		retirement,
	};
	let old = budget.tasks.borrow_mut().insert(id, worker);
	assert!(old.is_none(), "membership admitted before task insertion");
	super::Membership {
		_budget: budget.clone(),
		stop,
		retry,
		ready: readiness,
		ended,
		active,
	}
}
