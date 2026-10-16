//! A seat reserves one worker before Loam stages its effect, and installs
//! the observation once the receipt callback hands over its continuation.
use super::super::{MAX_JOBS, State};
use super::{Action, CallIntent, Intent, Job, Phase, Work, resume};
use glowcap::{
	Argument, Ref, Result,
	loam::{self, PendingContinuation},
};
use rooms_application::session::effect::Reply;
use rooms_glowcap::client::{Deadline, Tasks};
use std::{
	cell::Cell,
	rc::{Rc, Weak},
};
use tokio::sync::Mutex;

/// Reserve before Loam staging. Failure withdraws this inert worker seat.
pub(in super::super) struct Seat<P: Tasks + Deadline + Clone + 'static> {
	owner: Weak<State<P>>,
	id: String,
	installed: bool,
	retirement: Option<Rc<super::super::supervision::retirement::Owner>>,
}
impl<P: Tasks + Deadline + Clone + 'static> Seat<P> {
	pub fn reserve(owner: &Rc<State<P>>, id: &str) -> Result<Self> {
		if owner.closing.get() {
			return Err(loam::refusal("session is closing"));
		}
		let mut jobs = owner.jobs.borrow_mut();
		// A refused attempt's commit is confirmed absent before its worker
		// wakes to retire it. That seat holds nothing, so a retry takes it.
		// An observer that cannot answer keeps its seat, and the retry is
		// refused as busy below.
		let superseded = match jobs.get(id).and_then(|job| job.confirming.upgrade()) {
			Some(pending) if matches!(pending.absent(), Ok(true)) => jobs.remove(id),
			_ => None,
		};
		// Removing a seat leaves room under the cap and no entry for `id`, so
		// only a retry that superseded nothing is refused here.
		if jobs.len() >= MAX_JOBS || jobs.contains_key(id) {
			drop(jobs);
			drop(superseded);
			return Err(loam::refusal("session effect workers are full"));
		}
		jobs.insert(
			id.into(),
			Job {
				task: None,
				work: Rc::new(Mutex::new(None)),
				confirming: Weak::new(),
				failure: None,
				batch_released: None,
			},
		);
		drop(jobs);
		// Dropping its task cancels the old worker before it polls again.
		drop(superseded);
		let retirement = owner.memberships.retirement(id);
		if let Some(retirement) = &retirement {
			retirement.begin();
		}
		Ok(Self {
			owner: Rc::downgrade(owner),
			id: id.into(),
			installed: false,
			retirement,
		})
	}
	pub fn start(
		self,
		pending: PendingContinuation,
		source: Ref,
		canonical: String,
		intent: CallIntent,
		outgoing: Option<super::super::outgoing::Capture<P>>,
	) -> Result<()> {
		self.install(
			pending,
			source,
			canonical,
			intent.reply,
			Action::Call {
				verb: intent.verb,
				args: intent.args,
			},
			outgoing,
		)
	}
	pub fn start_upload(
		self,
		pending: PendingContinuation,
		source: Ref,
		canonical: String,
		intent: super::super::uploads::Intent,
		direct: bool,
		outgoing: Option<super::super::outgoing::Capture<P>>,
	) -> Result<()> {
		let released = Rc::new(Cell::new(false));
		if let Some(owner) = self.owner.upgrade() {
			owner
				.jobs
				.borrow_mut()
				.get_mut(&self.id)
				.ok_or_else(|| loam::refusal("effect has no live observation"))?
				.batch_released = Some(Rc::clone(&released));
		}
		self.install(
			pending,
			source,
			canonical,
			Reply::Upload,
			Action::Upload {
				intent,
				released,
				direct,
			},
			outgoing,
		)
	}
	pub fn start_bridge(
		self,
		pending: PendingContinuation,
		source: Ref,
		canonical: String,
		intent: super::super::bridge::pipeline::Intent,
	) -> Result<()> {
		self.install(
			pending,
			source,
			canonical,
			Reply::Acknowledgment,
			Action::Bridge(Box::new(intent)),
			None,
		)
	}
	pub fn start_archive(
		self,
		pending: PendingContinuation,
		source: Ref,
		canonical: String,
		intent: super::super::archive_sharing::Intent,
	) -> Result<()> {
		self.install(
			pending,
			source,
			canonical,
			Reply::Acknowledgment,
			Action::Archive(Box::new(intent)),
			None,
		)
	}
	fn install(
		mut self,
		pending: PendingContinuation,
		source: Ref,
		canonical: String,
		reply: Reply,
		action: Action,
		outgoing: Option<super::super::outgoing::Capture<P>>,
	) -> Result<()> {
		let owner = self
			.owner
			.upgrade()
			.ok_or_else(|| loam::refusal("session owner is closed"))?;
		let pending = Rc::new(pending);
		let work = {
			let mut jobs = owner.jobs.borrow_mut();
			let job = jobs
				.get_mut(&self.id)
				.ok_or_else(|| loam::refusal("effect has no live observation"))?;
			job.confirming = Rc::downgrade(&pending);
			Rc::clone(&job.work)
		};
		*work
			.try_lock()
			.map_err(|_| loam::refusal("effect observation is already started"))? = Some(Work {
			intent: Intent { source, canonical },
			reply,
			outgoing,
			provenance: Argument::Void,
			retirement: self.retirement.clone(),
			phase: Phase::Confirming {
				pending,
				action: Some(action),
			},
		});
		resume(&owner, &self.id)?;
		self.installed = true;
		Ok(())
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Drop for Seat<P> {
	fn drop(&mut self) {
		if !self.installed
			&& let Some(owner) = self.owner.upgrade()
		{
			if let Some(retirement) = &self.retirement {
				retirement.absent();
			}
			let retired = owner.jobs.borrow_mut().remove(&self.id);
			drop(retired);
			owner.changed.notify_waiters();
		}
	}
}
