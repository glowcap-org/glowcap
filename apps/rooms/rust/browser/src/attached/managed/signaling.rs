//! Browser inboxes follow exact managed registrations and the shared session feeds.
use super::super::retain;
use super::*;
use crate::signaling::Listener;
use glowcap::{DialOrigin, HintValue, Locator};
use rooms_glowcap::{client::directory::signaling::Route, routes::Address};
use rooms_runtime::session::managed::{SessionChanges, SignalingRegistration};
use std::{
	cell::RefCell,
	collections::BTreeMap,
	rc::{Rc, Weak},
};
use tokio::{sync::watch, task::JoinSet};

#[derive(Default)]
pub(in crate::attached) struct Routes(RefCell<BTreeMap<String, Entry>>);
struct Entry {
	authority: String,
	route: Route<Platform>,
}
impl Routes {
	pub fn select(&self, target: &Locator, origin: &DialOrigin) -> Result<Route<Platform>> {
		let entries = self.0.borrow();
		let hint = match target.hints.get("signaling-directory") {
			Some(HintValue::String(value)) => Some(
				Address::directory(value)
					.map_err(|e| e.to_string())?
					.ok_or("Invalid signaling directory")?
					.authority,
			),
			None => None,
			_ => return Err("Invalid signaling directory hint".into()),
		};
		let mut matching = entries.values().filter(|entry| {
			if hint.as_ref().is_some_and(|hint| hint != &entry.authority) {
				return false;
			}
			match origin {
				DialOrigin::Explicit => hint.is_some(),
				DialOrigin::Pending {
					introducer: Some(source),
				} => entry
					.route
					.session()
					.is_some_and(|session| session.same_session(source)),
				_ => false,
			}
		});
		let selected = matching
			.next()
			.ok_or("No held managed signaling registration for this route")?;
		if matching.next().is_some() {
			return Err("The managed signaling route is ambiguous".into());
		}
		Ok(selected.route.clone())
	}
}
pub(super) struct Owner {
	stop: watch::Sender<bool>,
	retry: watch::Sender<u64>,
	ended: watch::Receiver<Option<Result<()>>>,
}
impl Owner {
	pub fn start(environment: &Rc<Environment>, changes: SessionChanges) -> Self {
		let (stop, stopping) = watch::channel(false);
		let (finished, ended) = watch::channel(None);
		let (retry, retrying) = watch::channel(0);
		let environment = Rc::downgrade(environment);
		let shutdown = stop.clone();
		tokio::task::spawn_local(async move {
			finished.send_replace(Some(run(environment, changes, stopping, shutdown, retrying).await));
		});
		Self { stop, retry, ended }
	}
	pub fn retry(&self) {
		self.retry
			.send_modify(|generation| *generation = generation.wrapping_add(1));
	}
	pub async fn close(&self) -> Result<()> {
		self.stop.send_replace(true);
		super::super::connections::settled(&mut self.ended.clone()).await
	}
}
impl Drop for Owner {
	fn drop(&mut self) {
		self.stop.send_replace(true);
	}
}
async fn stopped(stop: &mut watch::Receiver<bool>) {
	if !*stop.borrow_and_update() {
		let _ = stop.changed().await;
	}
}
enum Preparation {
	Running,
	Refused(workspace::SignalingSelection),
}
async fn run(
	embedding: Weak<Environment>,
	mut changes: SessionChanges,
	mut stop: watch::Receiver<bool>,
	shutdown: watch::Sender<bool>,
	mut retry: watch::Receiver<u64>,
) -> Result<()> {
	let mut held = BTreeMap::<String, Preparation>::new();
	let mut workers = JoinSet::new();
	let mut outcome = Ok(());
	loop {
		if *stop.borrow() {
			break;
		}
		let Some(environment) = embedding.upgrade() else {
			break;
		};
		let reconciled = async {
			let owner = owner(&environment)?;
			let opened = owner.opened.lock().await;
			let snapshot = opened
				.workspace()
				.map_err(|e| e.to_string())?
				.snapshot()
				.await
				.map_err(|e| e.to_string())?;
			// Refused preparation belongs to its original scalar selection. Only
			// replacement, removal or an explicit retry permits another attempt.
			// Running registrations retain their own shared retirement barrier.
			held.retain(|_, state| match state {
				Preparation::Running => true,
				Preparation::Refused(selected) => selected.matches(&snapshot.intent),
			});
			for row in snapshot.intent.directories.as_slice() {
				let Some(selected) = workspace::SignalingSelection::directory(row) else {
					continue;
				};
				let id = row.id.text().as_str().ok_or("Invalid directory ID")?.to_owned();
				// A successor cannot file an inbox until the old listener has joined.
				if held.contains_key(&id) {
					continue;
				}
				let prepared = async {
					let source = opened
						.session()
						.directory_source(row)
						.await
						.map_err(|e| e.to_string())?;
					let location = source
						.directory_reader()
						.await
						.map_err(|e| e.to_string())?
						.advertised_location()
						.await
						.map_err(|e| e.to_string())?;
					let authority = Address::directory(&location)
						.map_err(|e| e.to_string())?
						.ok_or("Invalid advertised directory")?
						.authority;
					let registration = opened
						.session()
						.signaling_registration(row)
						.await
						.map_err(|e| e.to_string())?;
					Ok::<_, String>((authority, registration))
				}
				.await;
				match prepared {
					Ok((authority, registration)) => {
						held.insert(id.clone(), Preparation::Running);
						let (routes, ice, admission, trouble, stopping) = (
							environment.managed_signaling.clone(),
							environment.ice.clone(),
							environment.incoming.admission(),
							environment.trouble.clone(),
							stop.clone(),
						);
						workers.spawn_local(async move {
							let result =
								listen(&id, authority, registration, routes, ice, admission, trouble, stopping).await;
							(id, result)
						});
					}
					Err(error) => {
						held.insert(id, Preparation::Refused(selected));
						environment.trouble.report("Managed signaling", &error);
					}
				}
			}
			drop(opened);
			Ok::<_, String>(())
		}
		.await;
		if let Err(error) = reconciled {
			environment.trouble.report("Managed signaling", &error);
		}
		drop(environment);
		tokio::select! { biased;
			() = stopped(&mut stop) => break,
			_ = retry.changed() => {
				held.retain(|_, state| matches!(state, Preparation::Running));
				changes.retry();
			},
			changed = changes.changed() => {
				if let Err(error) = changed {
					if let Some(environment) = embedding.upgrade() { environment.trouble.report("Managed signaling changes", &error.to_string()); }
				}
			},
			ended = workers.join_next(), if !workers.is_empty() => {
				match ended {
					Some(Ok((id, result))) => { held.remove(&id); outcome = retain(outcome, result); },
					Some(Err(error)) => { outcome = retain(outcome, Err(error.to_string())); break; },
					None => unreachable!("nonempty signaling workers"),
				}
			},
		}
	}
	// Each worker owns its registrations and accepted-peer rejection barriers.
	// Request shutdown together, then join before closing the Loam attachment.
	if let Some(environment) = embedding.upgrade() {
		environment.managed_signaling.0.borrow_mut().clear();
	}
	shutdown.send_replace(true);
	while let Some(ended) = workers.join_next().await {
		match ended {
			Ok((_, result)) => outcome = retain(outcome, result),
			Err(error) => outcome = retain(outcome, Err(error.to_string())),
		}
	}
	outcome
}
async fn listen(
	id: &str,
	authority: String,
	mut registration: SignalingRegistration<Platform>,
	routes: Rc<Routes>,
	ice: crate::ice::Source,
	admission: super::super::peers::Admission,
	trouble: super::super::TroubleReporter,
	mut stop: watch::Receiver<bool>,
) -> Result<()> {
	let mut rejections = JoinSet::new();
	let mut delay = 1_000;
	let result = loop {
		if *stop.borrow() {
			break Ok(());
		}
		let route = registration.route().clone();
		if let Some(Err(error)) = registration.status() {
			trouble.report("Managed signaling", &error.to_string());
			registration.retry();
		}
		let result = match Listener::open(route.clone(), glowcap::HANDSHAKE_TIMEOUT).await {
			Ok(listener) => {
				routes.0.borrow_mut().insert(
					id.to_owned(),
					Entry {
						authority: authority.clone(),
						route,
					},
				);
				let fresh = ice.clone();
				let accepting = admission.clone();
				let reporting = trouble.clone();
				let (pressure, mut pressured) = watch::channel(false);
				let report = listener.serve_report(
                    move || { let ice = fresh.clone(); async move { ice.configuration().await.map_err(|_| crate::signaling::Error::Admission("Rooms could not obtain ICE configuration")) } },
                    async { tokio::select! { () = registration.retired() => {}, () = stopped(&mut stop) => {}, () = stopped(&mut pressured) => {} } },
                    |accepted| {
                        match accepted {
                            Ok(session) => if let Err(refused) = accepting.offer(session) {
                                pressure.send_replace(true);
                                if refused.capacity { reporting.report("Managed signaling", "Incoming connection capacity is exhausted"); }
                                rejections.spawn_local(async move { refused.session.close(glowcap::PendingWork::Cancel).await.map_err(|e| e.to_string()) });
                            },
                            Err(error) => reporting.report("Managed signaling", &error.to_string()),
                        }
                    },
                ).await;
				routes.0.borrow_mut().remove(id);
				if let Err(error) = report.activity {
					trouble.report("Managed signaling", &error.to_string());
				}
				report.retirement.map_err(|e| e.to_string())
			}
			Err(error) => {
				trouble.report("Managed signaling", &error.to_string());
				Ok(())
			}
		};
		let mut result = result;
		while let Some(ended) = rejections.join_next().await {
			result = retain(result, ended.map_err(|e| e.to_string()).and_then(|result| result));
		}
		if *stop.borrow() {
			break result;
		}
		if result.is_err() {
			break result;
		}
		tokio::select! { biased;
			() = stopped(&mut stop) => break Ok(()),
			() = registration.retired() => break Ok(()),
			() = gloo_timers::future::TimeoutFuture::new(delay) => {},
		}
		delay = (delay * 2).min(30_000);
	};
	routes.0.borrow_mut().remove(id);
	let mut result = retain(result, registration.close().await.map_err(|e| e.to_string()));
	while let Some(ended) = rejections.join_next().await {
		result = retain(result, ended.map_err(|e| e.to_string()).and_then(|result| result));
	}
	result
}
