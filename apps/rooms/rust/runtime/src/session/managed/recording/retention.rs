//! Canonical retention intent owns recovery; the local archive owns erasure.
//! One scalar subscriber shares the session's existing two change feeds.
use super::*;
use crate::session::managed::{Membership, supervision};
use tokio::sync::Mutex;

pub(super) struct Owner<P: Platform> {
	worker: Mutex<Membership<P>>,
	_budget: Rc<supervision::Budget<P>>,
	availability: Rc<super::availability::Availability>,
}
impl<P: Platform> Owner<P> {
	pub fn observe_archive(
		&self,
		key: Option<
			rooms_application::content::session::custody::FieldKey<
				rooms_application::content::session::custody::ArchiveAccess,
			>,
		>,
		session: Option<glowcap::Session>,
	) {
		self.availability.observe(key, session);
	}
	pub fn retry(&self) {
		if let Ok(worker) = self.worker.try_lock() {
			worker.retry();
		}
	}
	pub fn is_running(&self) -> bool {
		match self.worker.try_lock() {
			Ok(worker) => worker.is_active() && worker.status().is_none_or(|result| result.is_ok()),
			Err(_) => true,
		}
	}
	pub fn start(session: &Session<P>, archive: Rc<SessionArchive<P>>, source: DocumentText) -> Result<Self> {
		let changes = session.changes()?;
		let writer = session.state.writer.clone();
		let platform = session.state.platform.clone();
		let budget = Rc::new(supervision::Budget::default());
		let availability = Rc::new(super::availability::Availability::default());
		let observed = availability.clone();
		let activity = session.state.activity.clone();
		let worker = supervision::spawn(
			&platform.clone(),
			&budget,
			"history-retention".into(),
			None,
			move |signals| async move {
				let mut worker = Worker {
					signals,
					changes,
					writer,
					archive,
					source,
					platform,
					availability: observed,
					activity,
				};
				worker.run().await
			},
		);
		Ok(Self {
			worker: Mutex::new(worker),
			_budget: budget,
			availability,
		})
	}
	pub async fn close(&self) -> Result<()> {
		self.worker.lock().await.close().await
	}
}
struct Worker<P: Platform> {
	availability: Rc<super::availability::Availability>,
	activity: Rc<crate::session::managed::activity::Activity<P>>,
	signals: supervision::Signals,
	changes: crate::session::managed::SessionChanges,
	writer: Rc<crate::session::managed::executor::Writer>,
	archive: Rc<SessionArchive<P>>,
	source: DocumentText,
	platform: P,
}
impl<P: Platform> Worker<P> {
	async fn reconcile(&self) -> Result<()> {
		let root = self.writer.root()?;
		let intent = self
			.writer
			.host
			.send(&root, "retention-intent", &[root.clone().into()])
			.await?;
		let Some([glowcap::Argument::Boolean(keep), operation]) = intent.as_list() else {
			return Err(loam::refusal("invalid retention intent"));
		};
		if let glowcap::Argument::String(operation) = operation {
			if *keep {
				return Err(loam::refusal("invalid pending history erasure"));
			}
			self.archive
				.clear_source_when_ready(&self.source)
				.await
				.map_err(|e| loam::refusal(e.to_string()))?;
			self.writer
				.idempotent(
					"settle-history-erasure",
					&[root.clone().into(), operation.as_str().into()],
				)
				.await?;
		}
		self.writer
			.host
			.send(&root, "observe-archive-connection", &[root.clone().into()])
			.await?;
		Ok(())
	}
	async fn run(&mut self) -> Result<()> {
		loop {
			let result = self
				.platform
				.within(20_000, self.reconcile())
				.await
				.unwrap_or_else(|| Err(loam::refusal("history erasure remains pending; retry retirement")));
			self.signals.ready.send_replace(Some(result.clone()));
			if let Err(error) = &result {
				self.writer.report("History retention", error);
				if *self.signals.stopping.borrow() {
					self.signals.finished.send_replace(Some(Err(error.clone())));
				}
			} else if *self.signals.stopping.borrow() {
				return Ok(());
			}
			// A failed attempt stays owned, awaiting explicit recovery or a new
			// committed change. The durable marker fences enabling history.
			tokio::select! {
				key = self.availability.ended() => {
					match self.activity.archive_ended(self.writer.root()?, key) {
						Ok(()) => self.availability.reported(key),
						Err(error) => return Err(error),
					}
				},
				_ = self.signals.stopping.changed() => { self.signals.stopping.borrow_and_update(); },
				_ = self.signals.retrying.changed() => { self.signals.retrying.borrow_and_update(); },
				changed = self.changes.changed() => {
					if let Err(error) = changed {
						self.writer.report("History retention feed", &error);
						tokio::select! {
							_ = self.signals.stopping.changed() => { self.signals.stopping.borrow_and_update(); },
							_ = self.signals.retrying.changed() => { self.signals.retrying.borrow_and_update(); },
						}
					}
				},
			}
		}
	}
}
