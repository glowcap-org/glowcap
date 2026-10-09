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
/// dropping this view requests retirement; actual cleanup stays at the session.
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
					request: None,
					observation: None,
					cursor: None,
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
	request: Option<ObservationRequest>,
	observation: Option<Observation<P>>,
	cursor: Option<loam::ObservationCursor>,
	pending_receive: super::changes::Receive,
	refresh: std::rc::Rc<Refresh>,
	refreshed: u64,
	recovery_delay: u64,
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
			if self.request.is_none() {
				match self.workspace.mutation_sequence().await {
					Ok(sequence) => {
						let mut identity = [0; 16];
						if let Err(failure) = self.entropy.fill(&mut identity) {
							self.fail(loam::refusal(failure.to_string()));
							self.retry().await;
							continue;
						}
						self.request =
							Some(ObservationRequest::new_live(sequence, identity).expect("validated mutation sequence"))
					}
					Err(failure) => {
						self.fail(error(failure));
						self.retry().await;
						continue;
					}
				}
			}
			match self.workspace.observe(self.request.as_ref().unwrap()).await {
				Ok(observation) => {
					self.observation = Some(observation);
					self.request.take();
					break;
				}
				Err(failure) => {
					self.fail(error(failure));
					self.retry().await;
				}
			}
		}
		loop {
			match self.observation.as_ref().unwrap().poll(None).await {
				Ok(state) => {
					self.cursor = Some(*state.view().cursor);
					break;
				}
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
					let observation = self.observation.as_ref().unwrap();
					let cursor = self.cursor.as_ref().unwrap();
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
								Ok(state) => self.cursor = Some(*state.view().cursor),
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
		let _ = self.signals.retrying.changed().await;
	}
	async fn changed(&mut self) {
		let observation = self.observation.as_ref().unwrap();
		let cursor = self.cursor.as_ref().unwrap();
		let result = tokio::select! {
			biased;
			_ = self.refresh.wake.notified() => return,
			_ = self.signals.retrying.changed() => return,
			_ = self.platform.within(self.recovery_delay, std::future::pending::<()>()), if self.refresh.recovering.get() => {
				self.recovery_delay = (self.recovery_delay * 2).min(5_000);
				return;
			},
			result = self.pending_receive.next(observation, cursor) => result,
		};
		match result {
			Ok(state) => self.cursor = Some(*state.view().cursor),
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
			if let Some(request) = &self.request {
				self.observation = Some(self.workspace.observe(request).await.map_err(error)?);
				self.request.take();
			}
			if let Some(observation) = &self.observation {
				observation.cancel().await.map_err(error)?;
				self.pending_receive.drain().await;
				self.observation.take();
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
