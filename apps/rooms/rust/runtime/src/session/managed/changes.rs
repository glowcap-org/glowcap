//! Private content and inventory feeds wake every membership. Wakes carry no authority:
//! consumers check their own held source.
use super::{Membership, State, supervision};
use glowcap::{Result, loam};
use rooms_glowcap::client::{
	Deadline, Tasks,
	access::{Observation, ObservationRequest, ObservationState},
	workspace::Workspace,
};
use std::{cell::RefCell, future::Future, pin::Pin, rc::Rc};
use tokio::sync::watch;

pub(super) struct Owner<P: Tasks> {
	budget: Rc<supervision::Budget<P>>,
	worker: RefCell<Option<[Membership<P>; 2]>>,
	updates: watch::Sender<[Option<Result<()>>; 2]>,
	inspection: Rc<tokio::sync::Mutex<()>>,
}
impl<P: Tasks> Default for Owner<P> {
	fn default() -> Self {
		Self {
			budget: Rc::new(supervision::Budget::default()),
			worker: RefCell::new(None),
			updates: watch::channel([None, None]).0,
			inspection: Rc::new(tokio::sync::Mutex::new(())),
		}
	}
}
impl<P: Tasks> Owner<P> {
	/// Terminal execution can change Pending into Unknown without changing
	/// durable content. Wake readers to inspect their original receipt again.
	pub(super) fn execution_changed(&self) {
		self.updates.send_modify(|_| {});
	}
	pub fn started(&self) -> bool {
		self.worker.borrow().is_some()
	}
}
/// Two parked Loam receives cover content and all child grant changes, regardless
/// of membership count. Each view owns a scalar watch and two retry signals.
pub struct Wake {
	updates: watch::Receiver<[Option<Result<()>>; 2]>,
	feedback: watch::Sender<[Option<Result<()>>; 2]>,
	retry: [watch::Sender<u64>; 2],
	inspection: Rc<tokio::sync::Mutex<()>>,
}
impl Wake {
	/// A shared wake can make every membership runnable at once. One session
	/// lane bounds these short inspections and preparations independently of
	/// membership count. The guard never covers upstream effects or parked feeds.
	pub(super) async fn inspect(&self) -> tokio::sync::MutexGuard<'_, ()> {
		self.inspection.lock().await
	}
	/// Readiness requires both retained feeds to have recovered. A retry signal
	/// alone carries no evidence that observation is working again.
	pub async fn ready(&mut self) -> Result<()> {
		loop {
			let ready = {
				let updates = self.updates.borrow_and_update();
				for status in updates.iter().flatten() {
					status.clone()?;
				}
				updates.iter().all(|status| matches!(status, Some(Ok(()))))
			};
			if ready {
				return Ok(());
			}
			self.updates
				.changed()
				.await
				.map_err(|_| loam::refusal("Session change feed has closed"))?;
		}
	}
	pub fn retry(&self) {
		// A stopped feed's previous failure is not a new retry outcome. Clear
		// that evidence before signaling restart; retain healthy sibling state.
		self.feedback.send_if_modified(|updates| {
			let mut changed = false;
			for status in updates {
				if matches!(status, Some(Err(_))) {
					*status = None;
					changed = true;
				}
			}
			changed
		});
		for retry in &self.retry {
			retry.send_modify(|generation| *generation = generation.wrapping_add(1));
		}
	}
	pub async fn changed(&mut self) -> Result<()> {
		self.updates
			.changed()
			.await
			.map_err(|_| loam::refusal("Session change feed has closed"))?;
		for status in self.updates.borrow_and_update().iter().flatten() {
			status.clone()?;
		}
		Ok(())
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Owner<P> {
	pub fn subscribe(&self, owner: &Rc<State<P>>) -> Result<Wake> {
		if owner.closing.get() {
			return Err(loam::refusal("Session is closing"));
		}
		let mut worker = self.worker.borrow_mut();
		if worker.is_none() {
			let roots = [
				(owner.writer.root()?, 0, "session-content-feed"),
				(owner.writer.root_control()?, 1, "session-inventory-feed"),
			];
			*worker = Some(roots.map(|(root, index, name)| {
				let workspace = Workspace::local(owner.writer.host.clone(), owner.platform.clone(), root);
				let updates = self.updates.clone();
				let reporter = owner.writer.clone();
				supervision::spawn(
					&owner.platform,
					&self.budget,
					name.into(),
					None,
					move |signals| async move {
						let mut feed = Feed {
							workspace,
							request: None,
							observation: None,
							receive: Receive::default(),
							signals,
							updates,
							index,
							writer: reporter.clone(),
						};
						let mut stopping = feed.signals.stopping.clone();
						tokio::select! {
							biased;
							_ = stopping.changed() => {},
							_ = feed.run() => {},
						}
						loop {
							feed.signals.stopping.borrow_and_update();
							feed.signals.retrying.borrow_and_update();
							match feed.close().await {
								Ok(()) => return Ok(()),
								Err(error) => {
									reporter.report("Session change feed close", &error);
									feed.signals.finished.send_replace(Some(Err(error)));
								}
							}
							tokio::select! {
								_ = feed.signals.stopping.changed() => {},
								_ = feed.signals.retrying.changed() => {},
							}
						}
					},
				)
			}));
		}
		let worker = worker.as_ref().expect("installed change feed");
		let mut updates = self.updates.subscribe();
		// Startup callers must observe the initial ready notification, including
		// subscribers that arrive after it. They still poll their own source.
		updates.mark_changed();
		Ok(Wake {
			updates,
			feedback: self.updates.clone(),
			inspection: self.inspection.clone(),
			retry: std::array::from_fn(|index| worker[index].retry_signal()),
		})
	}
	pub async fn close(&self) -> Result<()> {
		self.budget.close_all().await?;
		self.worker.borrow_mut().take();
		Ok(())
	}
}
struct Feed<P: Tasks> {
	workspace: Workspace<P>,
	request: Option<ObservationRequest>,
	observation: Option<Observation<P>>,
	receive: Receive,
	signals: supervision::Signals,
	updates: watch::Sender<[Option<Result<()>>; 2]>,
	index: usize,
	writer: Rc<super::executor::Writer>,
}
/// One admitted receive survives interruption. Cancelling its registration
/// wakes this same call; observing it drains the work borrowing the attachment.
#[derive(Default)]
pub(super) struct Receive {
	pending: Option<PendingReceive>,
}
type PendingReceive =
	Pin<Box<dyn Future<Output = std::result::Result<ObservationState, rooms_glowcap::client::Error>>>>;
impl Receive {
	pub(super) async fn next<P: Deadline + 'static>(
		&mut self,
		observation: &Observation<P>,
		cursor: &loam::ObservationCursor,
	) -> std::result::Result<ObservationState, rooms_glowcap::client::Error> {
		let pending = self
			.pending
			.get_or_insert_with(|| Box::pin(observation.receive(cursor)));
		let result = pending.await;
		self.pending.take();
		result
	}
	pub(super) async fn drain(&mut self) {
		if let Some(pending) = self.pending.as_mut() {
			// Cancellation or revoked authority can refuse the receive. Either
			// terminal outcome establishes that its admitted work has retired.
			let _ = pending.await;
			self.pending.take();
		}
	}
}
fn error(error: rooms_glowcap::client::Error) -> glowcap::Error {
	loam::refusal(error.to_string())
}
impl<P: Tasks + Deadline + Clone + 'static> Feed<P> {
	async fn run(&mut self) {
		loop {
			let result = self.advance().await;
			if let Err(error) = result {
				self.writer.report("Session change feed", &error);
				self.signals.ready.send_replace(Some(Err(error.clone())));
				self.updates
					.send_modify(|updates| updates[self.index] = Some(Err(error)));
				if self.signals.retrying.changed().await.is_err() {
					return;
				}
			}
		}
	}
	async fn advance(&mut self) -> Result<()> {
		if self.observation.is_none() {
			let _serial = self.writer.mutation_guard().await;
			if self.request.is_none() {
				self.request = Some(
					// This private feed has one owner per exact root and live scope.
					ObservationRequest::new_live(
						self.workspace.mutation_sequence().await.map_err(error)?,
						[self.index as u8; 16],
					)
					.map_err(error)?,
				);
			}
			self.observation = Some(
				self.workspace
					.observe(self.request.as_ref().unwrap())
					.await
					.map_err(error)?,
			);
			self.request.take();
		}
		let observation = self.observation.as_ref().unwrap();
		let mut cursor = *observation.poll(None).await.map_err(error)?.view().cursor;
		self.signals.ready.send_replace(Some(Ok(())));
		self.updates.send_modify(|updates| updates[self.index] = Some(Ok(())));
		loop {
			cursor = *self
				.receive
				.next(observation, &cursor)
				.await
				.map_err(error)?
				.view()
				.cursor;
			self.updates.send_modify(|updates| updates[self.index] = Some(Ok(())));
		}
	}
	async fn close(&mut self) -> Result<()> {
		if let Some(request) = self.request.as_ref() {
			let _serial = self.writer.mutation_guard().await;
			self.observation = Some(self.workspace.observe(request).await.map_err(error)?);
			self.request.take();
		}
		if let Some(observation) = self.observation.as_ref() {
			observation.cancel().await.map_err(error)?;
			self.receive.drain().await;
			self.observation.take();
		}
		Ok(())
	}
}
