//! One session worker retires credential bytes against committed Loam custody.
use super::{credentials::Credentials, *};
use crate::session::managed::{Membership, supervision};
use std::{future::Future, pin::Pin};
use tokio::sync::Mutex;

/// One scalar subscriber uses the existing session feeds. At most one complete
/// reconciliation future retains the journal fence and bounded document bytes;
/// a deadline drops only its observer. Retry and close resume that same future.
pub(in crate::session::managed) struct Owner<P: Tasks> {
	worker: Mutex<Membership<P>>,
	_budget: Rc<supervision::Budget<P>>,
}
impl<P: Tasks + Deadline + Clone + 'static> Owner<P> {
	pub fn start(session: &Session<P>, credentials: Rc<Credentials>) -> Result<Self> {
		let mut changes = session.changes()?;
		let writer = session.state.writer.clone();
		let platform = session.state.platform.clone();
		let budget = Rc::new(supervision::Budget::default());
		let worker = supervision::spawn(
			&platform.clone(),
			&budget,
			"bridge-credential-retention".into(),
			None,
			move |mut signals| async move {
				let mut pending: Option<Pin<Box<dyn Future<Output = Result<()>>>>> = None;
				loop {
					if pending.is_none() {
						let credentials = credentials.clone();
						let writer = writer.clone();
						pending = Some(Box::pin(async move { credentials.reconcile(&writer).await }));
					}
					let result = match platform.within(20_000, pending.as_mut().unwrap()).await {
						Some(result) => {
							pending.take();
							result
						}
						None => Err(glowcap::loam::refusal(
							"bridge credential cleanup remains pending; retry retirement",
						)),
					};
					signals.ready.send_replace(Some(result.clone()));
					if let Err(error) = &result {
						writer.report("Bridge credential retention", error);
						if *signals.stopping.borrow() {
							signals.finished.send_replace(Some(Err(error.clone())));
						}
					} else if *signals.stopping.borrow() {
						return Ok(());
					}
					tokio::select! {
						_ = signals.stopping.changed() => { signals.stopping.borrow_and_update(); },
						_ = signals.retrying.changed() => { signals.retrying.borrow_and_update(); },
						changed = changes.changed() => {
							if let Err(error) = changed {
								writer.report("Bridge credential retention feed", &error);
								tokio::select! {
									_ = signals.stopping.changed() => { signals.stopping.borrow_and_update(); },
									_ = signals.retrying.changed() => { signals.retrying.borrow_and_update(); },
								}
							}
						},
					}
				}
			},
		);
		Ok(Self {
			worker: Mutex::new(worker),
			_budget: budget,
		})
	}
	pub fn retry(&self) {
		if let Ok(worker) = self.worker.try_lock() {
			worker.retry();
		}
	}
	pub async fn close(&self) -> Result<()> {
		self.worker.lock().await.close().await
	}
}
