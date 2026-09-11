//! Browser listeners follow the shared runtime's actual registrations. Name
//! ownership, reconnect proofs and generation retirement stay in that runtime.
use super::{retain, signaling::Signaling, Result};
use crate::{ice, platform::Platform, signaling::Listener};
use rooms_runtime::directory_runtime::{DirectoryRuntime, RegisteredDirectory};
use std::{cell::RefCell, collections::BTreeMap, future::poll_fn, rc::Rc};
use tokio::{sync::watch, task::JoinSet};

type Lease = RegisteredDirectory<Platform>;
type Rejections = Rc<RefCell<JoinSet<Result<()>>>>;
pub(super) struct Owner {
	stop: watch::Sender<bool>,
	ended: watch::Receiver<Option<Result<()>>>,
}
impl Owner {
	pub fn start(
		directories: DirectoryRuntime<Platform>,
		routes: Rc<Signaling>,
		ice: ice::Source,
		admission: super::peers::Admission,
	) -> Self {
		let (stop, stopping) = watch::channel(false);
		let (finished, ended) = watch::channel(None);
		let shutdown = stop.clone();
		tokio::task::spawn_local(async move {
			finished.send_replace(Some(run(directories, routes, ice, stopping, shutdown, admission).await));
		});
		Self { stop, ended }
	}
	pub async fn ended(&self) -> Result<()> {
		super::connections::terminal(&mut self.ended.clone()).await
	}
	pub async fn close(&self) -> Result<()> {
		self.stop.send_replace(true);
		self.ended().await
	}
}
impl Drop for Owner {
	fn drop(&mut self) {
		self.stop.send_replace(true);
	}
}
async fn stopped(stop: &mut watch::Receiver<bool>) {
	if !*stop.borrow() {
		let _ = stop.changed().await;
	}
}
fn report(error: &str) {
	web_sys::console::error_1(&format!("Rooms WebRTC: {error}").into());
}
async fn run(
	directories: DirectoryRuntime<Platform>,
	routes: Rc<Signaling>,
	ice: ice::Source,
	mut stop: watch::Receiver<bool>,
	shutdown: watch::Sender<bool>,
	admission: super::peers::Admission,
) -> Result<()> {
	let mut changes = directories.changes();
	let mut held = BTreeMap::<String, Lease>::new();
	let mut listeners = JoinSet::new();
	let rejections = Rejections::default();
	let mut outcome = Ok(());
	loop {
		if *stop.borrow() || directories.is_closed() {
			break;
		}
		for lease in directories.registered() {
			let key = lease.id().text().as_str().expect("directory authority").to_owned();
			// A replaced generation joins before its successor may publish an
			// inbox on the same directory. At most 32 directory workers exist.
			if held.contains_key(&key) || held.len() >= 32 {
				continue;
			}
			held.insert(key.clone(), lease.clone());
			let (routes, ice, rejections, stop, admission) = (
				routes.clone(),
				ice.clone(),
				rejections.clone(),
				stop.clone(),
				admission.clone(),
			);
			listeners.spawn_local(async move { (key, listen(lease, routes, ice, rejections, stop, admission).await) });
		}
		tokio::select! { biased;
			() = stopped(&mut stop) => break,
			changed = changes.changed() => { if changed.is_err() { break; } },
			ended = listeners.join_next(), if !listeners.is_empty() => {
				match ended {
					Some(Ok((key, result))) => { held.remove(&key); outcome = retain(outcome, result); },
					Some(Err(error)) => { outcome = retain(outcome, Err(error.to_string())); break; },
					None => unreachable!("nonempty listener set"),
				}
			},
			Some(ended) = poll_fn(|cx| rejections.borrow_mut().poll_join_next(cx)) => {
				if let Err(error) = ended.map_err(|e| e.to_string()).and_then(|result| result) { report(&error); }
			},
		}
	}
	shutdown.send_replace(true);
	while let Some(ended) = listeners.join_next().await {
		outcome = retain(outcome, ended.map_err(|e| e.to_string()).and_then(|(_, result)| result));
	}
	while let Some(ended) = poll_fn(|cx| rejections.borrow_mut().poll_join_next(cx)).await {
		outcome = retain(outcome, ended.map_err(|e| e.to_string()).and_then(|result| result));
	}
	outcome
}
async fn listen(
	lease: Lease,
	routes: Rc<Signaling>,
	ice: ice::Source,
	rejections: Rejections,
	mut stop: watch::Receiver<bool>,
	admission: super::peers::Admission,
) -> Result<()> {
	let mut delay = 1_000;
	while lease.current() && !*stop.borrow() {
		// Opening is bounded by the directory client's ordinary call deadline.
		// Keep it owned through a generation change, then retire its inbox.
		let listener = Listener::open(lease.directory().clone(), glowcap::HANDSHAKE_TIMEOUT).await;
		let result = match listener {
			Ok(listener) => {
				routes.member(lease.clone());
				let (pressure, mut pressured) = watch::channel(false);
				let accepting = rejections.clone();
				let admission = admission.clone();
				let fresh = ice.clone();
				let result = listener
					.serve(
						move || {
							let ice = fresh.clone();
							async move {
								ice.configuration().await.map_err(|_| {
									crate::signaling::Error::Admission("Rooms could not obtain ICE configuration")
								})
							}
						},
						async {
							tokio::select! { () = lease.retired() => {}, () = stopped(&mut stop) => {}, () = stopped(&mut pressured) => {} }
						},
						move |accepted| {
							let session = match accepted {
								Ok(session) => session,
								Err(error) => {
									report(&error.to_string());
									return;
								}
							};
							if let Err(refused) = admission.offer(session) {
								let session = refused.session;
								pressure.send_replace(true);
								if refused.capacity {
									report("Incoming connection capacity is exhausted");
								}
								accepting.borrow_mut().spawn_local(async move {
									session
										.close(glowcap::PendingWork::Cancel)
										.await
										.map_err(|e| e.to_string())
								});
							}
						},
					)
					.await
					.map_err(|e| e.to_string());
				routes.forget_member(&lease);
				delay = 1_000;
				result
			}
			Err(error) => Err(error.to_string()),
		};
		if !lease.current() || *stop.borrow() {
			return result;
		}
		if let Err(error) = result {
			report(&error);
		}
		tokio::select! { biased;
			() = stopped(&mut stop) => return Ok(()),
			() = lease.retired() => return Ok(()),
			() = gloo_timers::future::TimeoutFuture::new(delay) => {},
		}
		delay = (delay * 2).min(30_000);
	}
	Ok(())
}
