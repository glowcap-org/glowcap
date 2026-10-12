//! One held workspace observation drives membership realization without polling.
//! The session retains the actual task through exact cancellation and retry.
use super::{Membership, MembershipReceiver, MembershipReport, MembershipTarget, Memberships, Session, supervision};
use glowcap::{Ref, Result, loam};
use rooms_glowcap::client::{
	Deadline, Tasks,
	access::{Observation, ObservationRequest},
	workspace::Workspace,
};
use std::rc::Weak;
mod discovery;

/// One scalar request generation and wake per session. Lost viewer events
/// require fresh upstream snapshots, while membership and exact source custody
/// stay with their existing owners. No snapshot or capability is copied here.
#[derive(Default)]
pub(super) struct Refresh {
	generation: std::cell::Cell<u64>,
	wake: tokio::sync::Notify,
	recovering: std::cell::Cell<bool>,
	recovery_generation: std::cell::Cell<u64>,
}
impl Refresh {
	pub(super) fn recover(&self) {
		self.recovery_generation
			.set(self.recovery_generation.get().wrapping_add(1));
		self.recovering.set(true);
		self.wake.notify_one();
	}
	pub(super) fn request(&self) -> Result<()> {
		let next = self
			.generation
			.get()
			.checked_add(1)
			.ok_or_else(|| loam::refusal("discovery refresh identity exhausted"))?;
		self.generation.set(next);
		self.wake.notify_one();
		Ok(())
	}
}

/// A view onto the session-owned observation worker. Abandoning readiness or
/// dropping this view requests retirement. Actual cleanup stays at the session.
pub struct WorkspaceActivity<P: Tasks>(Membership<P>);
impl<P: Tasks> WorkspaceActivity<P> {
	pub fn is_active(&self) -> bool {
		self.0.is_active()
	}
	pub fn status(&self) -> Option<Result<()>> {
		self.0.status()
	}
	pub async fn ready(&self) -> Result<()> {
		self.0.ready().await
	}
	pub fn retry(&self) {
		self.0.retry();
	}
	pub async fn close(&mut self) -> Result<()> {
		self.0.close().await
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Session<P> {
	/// Observe the supplied held use endpoint. Rows still restore and execute
	/// only through their saved initiating sources, never this observer or root.
	/// One fixed observation/cursor and one bounded temporary snapshot serve the
	/// whole workspace. The session admits at most one such owner at a time.
	pub fn supervise_workspace<E: crate::entropy::Entropy + 'static>(
		&self,
		source: &Ref,
		locator: &str,
		entropy: E,
		kinds: super::MembershipKinds,
		receive: impl FnMut(&MembershipTarget) -> MembershipReceiver + 'static,
		report: impl FnMut(Result<&MembershipReport>) + 'static,
	) -> Result<WorkspaceActivity<P>> {
		if self.state.closing.get() {
			return Err(loam::refusal("Session is closing"));
		}
		if locator.len() > 16384 {
			return Err(loam::refusal("Workspace locator exceeds its bound"));
		}
		let id = "workspace-observation";
		if self.state.workspace_observers.contains(id) {
			return Err(loam::refusal("Workspace realization is already active"));
		}
		let session = std::rc::Rc::downgrade(&self.state);
		let workspace = Workspace::local(
			self.state.writer.host.clone(),
			self.state.platform.clone(),
			source.clone(),
		);
		let locator = locator.to_owned();
		let refresh = self.state.discovery_refresh.clone();
		// Cold restoration can fail before a connection exists to report loss.
		// Drive the same bounded recovery until initial realization succeeds.
		refresh.recover();
		let platform = self.state.platform.clone();
		Ok(WorkspaceActivity(supervision::spawn(
			&self.state.platform,
			&self.state.workspace_observers,
			id.into(),
			None,
			move |signals| async move {
				let mut worker = Worker {
					session,
					platform,
					workspace,
					locator,
					entropy,
					receive,
					report,
					signals,
					memberships: Memberships::with_kinds(kinds),
					discover: kinds.discovery,
					discovery: discovery::Discoveries::default(),
					watch: Watch::Idle,
					pending_receive: super::changes::Receive::default(),
					refresh,
					refreshed: 0,
					recovery_delay: 200,
				};
				let mut stopping = worker.signals.stopping.clone();
				tokio::select! {
					biased;
					_ = stopping.changed() => {},
					_ = worker.run() => {},
				}
				if worker.signals.ready.borrow().is_none() {
					worker.signals.ready.send_replace(Some(Err(loam::refusal(
						"Workspace realization closed before readiness",
					))));
				}
				loop {
					worker.signals.stopping.borrow_and_update();
					worker.signals.retrying.borrow_and_update();
					let result = worker.cleanup().await;
					if result.is_ok() {
						return result;
					}
					worker.signals.finished.send_replace(Some(result));
					// Both observation and membership failures retain their exact
					// cleanup custody. No failed barrier spins or closes storage.
					tokio::select! {
						_ = worker.signals.stopping.changed() => {},
						_ = worker.signals.retrying.changed() => {},
					}
				}
			},
		)))
	}
}
struct Worker<P: Tasks + Deadline + Clone + 'static, E, F, R> {
	session: Weak<super::State<P>>,
	platform: P,
	workspace: Workspace<P>,
	locator: String,
	entropy: E,
	receive: F,
	report: R,
	signals: supervision::Signals,
	memberships: Memberships<P>,
	discovery: discovery::Discoveries<P>,
	discover: bool,
	watch: Watch<P>,
	pending_receive: super::changes::Receive,
	refresh: std::rc::Rc<Refresh>,
	refreshed: u64,
	recovery_delay: u64,
}
/// Where the worker is in establishing its workspace observation. `run` walks
/// the phases forward. `changed` reads only a polled observation, and
/// `cleanup` cancels whichever phase was reached.
enum Watch<P: Tasks + Deadline + Clone + 'static> {
	Idle,
	Requested(ObservationRequest),
	Observing(Observation<P>),
	Polled {
		observation: Observation<P>,
		cursor: loam::ObservationCursor,
	},
}
impl<P: Tasks + Deadline + Clone + 'static> Watch<P> {
	/// Record the cursor a poll or change delivered. A phase without an
	/// observation has no cursor to move.
	fn polled(&mut self, cursor: loam::ObservationCursor) {
		*self = match std::mem::replace(self, Self::Idle) {
			Self::Observing(observation) | Self::Polled { observation, .. } => Self::Polled { observation, cursor },
			other => other,
		};
	}
}
fn error(error: rooms_glowcap::client::Error) -> glowcap::Error {
	loam::refusal(error.to_string())
}
impl<P, E, F, R> Worker<P, E, F, R>
where
	P: Tasks + Deadline + Clone + 'static,
	E: crate::entropy::Entropy,
	F: FnMut(&MembershipTarget) -> MembershipReceiver,
	R: FnMut(Result<&MembershipReport>),
{
	async fn run(&mut self) {
		loop {
			let observed = match &self.watch {
				Watch::Idle => None,
				Watch::Requested(request) => Some(self.workspace.observe(request).await),
				Watch::Observing(_) | Watch::Polled { .. } => break,
			};
			match observed {
				None => match self.workspace.mutation_sequence().await {
					Ok(sequence) => {
						let mut identity = [0; 16];
						if let Err(failure) = self.entropy.fill(&mut identity) {
							self.fail(loam::refusal(failure.to_string()));
							self.retry().await;
							continue;
						}
						match ObservationRequest::new_live(sequence, identity) {
							Ok(request) => self.watch = Watch::Requested(request),
							Err(failure) => {
								self.fail(error(failure));
								self.retry().await;
							}
						}
					}
					Err(failure) => {
						self.fail(error(failure));
						self.retry().await;
					}
				},
				Some(Ok(observation)) => {
					self.watch = Watch::Observing(observation);
					break;
				}
				Some(Err(failure)) => {
					self.fail(error(failure));
					self.retry().await;
				}
			}
		}
		while let Watch::Observing(observation) = &self.watch {
			match observation.poll(None).await {
				Ok(state) => self.watch.polled(*state.view().cursor),
				Err(failure) => {
					self.fail(error(failure));
					self.retry().await;
				}
			}
		}
		loop {
			match self.workspace.snapshot().await {
				Ok(snapshot) => {
					// Report known losses before waiting on restoration. Otherwise an
					// unavailable directory can hide a sibling's connection failure.
					let mut status = MembershipReport::default();
					self.discovery.append_status(&mut status);
					self.memberships.append_status(&mut status);
					if !status.failures.is_empty() {
						(self.report)(Ok(&status));
					}
					let recovery_generation = self.refresh.recovery_generation.get();
					let generation = self.refresh.generation.get();
					if self.discover && generation != self.refreshed {
						// Join every previous callback and exact UNWATCH before creating
						// replacement observers. Their WATCH snapshots cover the gap;
						// old queued notifications cannot overwrite the new snapshot.
						if let Err(failure) = self.discovery.close().await {
							self.fail(failure);
							self.retry().await;
							continue;
						}
						self.refreshed = generation;
					}
					// A workspace change can retire a row while its effect is
					// pending. Interrupt only this reconciliation observer; the
					// registry retains every inserted worker and exact request.
					let Watch::Polled { observation, cursor } = &self.watch else {
						return;
					};
					let Some(state) = self.session.upgrade() else {
						self.fail(loam::refusal("Workspace session owner has closed"));
						return;
					};
					let session = Session { state };
					let outcome = tokio::select! {
						biased;
						_ = self.refresh.wake.notified() => None,
						change = self.pending_receive.next(observation, cursor) => {
							match change {
								Ok(state) => self.watch.polled(*state.view().cursor),
								Err(failure) => { self.fail(error(failure)); self.retry().await; }
							}
							None
						},
						report = async {
							let mut report = if self.discover { self.discovery.reconcile(&session, &snapshot.intent, &mut self.receive).await }
							else { MembershipReport::default() };
							let members = self.memberships.reconcile(&session, &snapshot.intent, &self.locator, &mut self.entropy, &mut self.receive).await;
							report.ready += members.ready;
							report.failures.extend(members.failures);
							report
						} => Some(report),
					};
					let Some(report) = outcome else { continue };
					self.signals.ready.send_replace(Some(match report.failures.first() {
						Some((_, failure)) => Err(failure.clone()),
						None => Ok(()),
					}));
					(self.report)(Ok(&report));
					if report.failures.is_empty() && recovery_generation == self.refresh.recovery_generation.get() {
						self.refresh.recovering.set(false);
						self.recovery_delay = 200;
					}
				}
				Err(failure) => self.fail(error(failure)),
			}
			self.changed().await;
		}
	}
	fn fail(&mut self, failure: glowcap::Error) {
		self.signals.ready.send_replace(Some(Err(failure.clone())));
		(self.report)(Err(failure));
	}
	async fn retry(&mut self) {
		if self.signals.retrying.changed().await.is_ok() {
			self.memberships.retry_failed();
		}
	}
	async fn changed(&mut self) {
		let Watch::Polled { observation, cursor } = &self.watch else {
			return;
		};
		let result = tokio::select! {
			biased;
			_ = self.refresh.wake.notified() => return,
			result = self.signals.retrying.changed() => {
				if result.is_ok() { self.memberships.retry_failed(); }
				return;
			},
			_ = self.platform.within(self.recovery_delay, std::future::pending::<()>()), if self.refresh.recovering.get() => {
				self.recovery_delay = (self.recovery_delay * 2).min(5_000);
				return;
			},
			result = self.pending_receive.next(observation, cursor) => result,
		};
		match result {
			Ok(state) => self.watch.polled(*state.view().cursor),
			Err(failure) => {
				self.fail(error(failure));
				self.retry().await;
			}
		}
	}
	async fn cleanup(&mut self) -> Result<()> {
		let members = self.memberships.close().await;
		let discovery = self.discovery.close().await;
		let members = match members {
			Ok(()) => discovery,
			Err(error) => Err(error.with_cleanup(discovery)),
		};
		let observation = async {
			if let Watch::Requested(request) = &self.watch {
				let observation = self.workspace.observe(request).await.map_err(error)?;
				self.watch = Watch::Observing(observation);
			}
			if let Watch::Observing(observation) | Watch::Polled { observation, .. } = &self.watch {
				observation.cancel().await.map_err(error)?;
				self.pending_receive.drain().await;
				self.watch = Watch::Idle;
			}
			Ok(())
		}
		.await;
		match members {
			Ok(()) => observation,
			Err(failure) => Err(failure.with_cleanup(observation)),
		}
	}
}
