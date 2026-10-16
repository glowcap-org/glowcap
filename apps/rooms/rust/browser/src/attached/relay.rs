//! Sustained relay reachability for the page's existing Host. Idle seats and
//! handshakes stay bounded. Established peers transfer to the Host owner.
use super::{Result, retain};
use crate::platform::Platform;
use glowcap::{Host, Locator, PendingWork, Session, browser::relay::Registration};
use rooms_glowcap::client::Deadline;
use std::sync::Arc;
use tokio::{
	sync::{OwnedSemaphorePermit, Semaphore, mpsc, watch},
	task::JoinSet,
};

const SEATS: usize = 2;
const CAPACITY: usize = SEATS * 2;
#[derive(Clone, Default)]
struct Status {
	ready: usize,
	failure: Option<String>,
	closed: bool,
}
impl Status {
	/// What a waiter for readiness learns now, or None to keep waiting. A
	/// listener that has stopped is never ready, and its failure, when it has
	/// one, is the reason it gives.
	fn verdict(&self, stopping: bool) -> Option<Result<()>> {
		let ended = self.closed || stopping;
		if self.ready > 0 && !ended {
			return Some(Ok(()));
		}
		if let Some(error) = &self.failure {
			return Some(Err(error.clone()));
		}
		ended.then(|| Err("Rooms relay listener is closed".into()))
	}
}
pub(super) struct Relay {
	locator: Locator,
	stop: watch::Sender<bool>,
	status: watch::Receiver<Status>,
	ended: watch::Receiver<Option<Result<()>>>,
}
struct Ready(watch::Sender<Status>);
impl Ready {
	fn new(status: &watch::Sender<Status>) -> Self {
		status.send_modify(|state| {
			state.ready += 1;
			state.failure = None;
		});
		Self(status.clone())
	}
}
impl Drop for Ready {
	fn drop(&mut self) {
		self.0.send_modify(|state| state.ready -= 1);
	}
}
impl Relay {
	pub fn start(
		host: &Host,
		platform: Platform,
		locator: Locator,
		register: String,
		admission: super::peers::Admission,
	) -> Result<Self> {
		// Validate configuration before starting a supervisor. Constructing the
		// locator is separate from opening a socket, so invalid routes cannot
		// leave a partial registration pool behind.
		glowcap::browser::relay::dial_url(&locator).map_err(|e| e.to_string())?;
		host.set_advertised_locator(&locator).map_err(|e| e.to_string())?;
		let (stop, stopping) = watch::channel(false);
		let (status, observed) = watch::channel(Status::default());
		let (ended, outcome) = watch::channel(None);
		let host = host.clone();
		let shutdown = stop.clone();
		let route = locator.clone();
		tokio::task::spawn_local(async move {
			let result = run(
				host,
				platform,
				route,
				register,
				(stopping, shutdown),
				status.clone(),
				admission,
			)
			.await;
			// A listener that ended on an error keeps it as the reason it is
			// closed, so a waiter reports the cause and not only the closing.
			status.send_modify(|state| {
				state.closed = true;
				if let Err(error) = &result {
					state.failure = Some(error.clone());
				}
			});
			ended.send_replace(Some(result));
		});
		Ok(Self {
			locator,
			stop,
			status: observed,
			ended: outcome,
		})
	}
	pub fn locator(&self) -> &Locator {
		&self.locator
	}
	pub async fn ready(&self) -> Result<()> {
		let mut status = self.status.clone();
		loop {
			if let Some(verdict) = status.borrow_and_update().verdict(*self.stop.borrow()) {
				return verdict;
			}
			status
				.changed()
				.await
				.map_err(|_| "Rooms relay listener lost its supervisor")?;
		}
	}
	pub async fn close(&self) -> Result<()> {
		self.stop.send_replace(true);
		super::connections::settled(&mut self.ended.clone()).await
	}
}
impl Drop for Relay {
	fn drop(&mut self) {
		self.stop.send_replace(true);
	}
}
async fn stopped(stop: &mut watch::Receiver<bool>) {
	if !*stop.borrow() {
		let _ = stop.changed().await;
	}
}
type Accepted = (Session, OwnedSemaphorePermit);
async fn run(
	host: Host,
	platform: Platform,
	locator: Locator,
	register: String,
	control: (watch::Receiver<bool>, watch::Sender<bool>),
	status: watch::Sender<Status>,
	admission: super::peers::Admission,
) -> Result<()> {
	let (mut stop, shutdown) = control;
	let budget = Arc::new(Semaphore::new(CAPACITY));
	let (incoming, mut accepted) = mpsc::channel(SEATS);
	let mut seats = JoinSet::new();
	for _ in 0..SEATS {
		seats.spawn_local(
			Seat {
				host: host.clone(),
				platform: platform.clone(),
				locator: locator.clone(),
				register: register.clone(),
				stop: stop.clone(),
				status: status.clone(),
				budget: budget.clone(),
				incoming: incoming.clone(),
			}
			.run(),
		);
	}
	drop(incoming);
	let mut outcome = Ok(());
	loop {
		tokio::select! { biased;
			() = stopped(&mut stop) => break,
			ended = seats.join_next(), if !seats.is_empty() => {
				outcome = retain(outcome, joined(ended));
				// A seat returns only at shutdown or if physical retirement
				// failed. Surface the loss instead of claiming a full pool.
				break;
			},
			next = accepted.recv() => match next {
				Some((session, permit)) => {
					if let Err(refused) = admission.offer(session) {
						let session = refused.session;
						if refused.capacity { report(&status, "Rooms incoming connection capacity is exhausted".into()); }
						outcome = retain(outcome, session.close(PendingWork::Cancel).await.map_err(|e| e.to_string()));
					}
					drop(permit);
				},
				None => break,
			},
		}
	}
	shutdown.send_replace(true);
	accepted.close();
	while let Some((session, _permit)) = accepted.recv().await {
		outcome = retain(
			outcome,
			session.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
		);
	}
	while let Some(ended) = seats.join_next().await {
		outcome = retain(outcome, joined(Some(ended)));
	}
	outcome
}
fn joined(result: Option<std::result::Result<Result<()>, tokio::task::JoinError>>) -> Result<()> {
	result
		.ok_or_else(|| "Rooms relay worker disappeared".to_string())?
		.map_err(|e| e.to_string())?
}
fn report(status: &watch::Sender<Status>, error: String) {
	web_sys::console::error_1(&format!("Rooms relay: {error}").into());
	status.send_modify(|state| state.failure = Some(error));
}
struct Seat {
	host: Host,
	platform: Platform,
	locator: Locator,
	register: String,
	stop: watch::Receiver<bool>,
	status: watch::Sender<Status>,
	budget: Arc<Semaphore>,
	incoming: mpsc::Sender<Accepted>,
}
enum Failure {
	Retry(String),
	Retirement(String),
}
impl Failure {
	fn message(self) -> String {
		match self {
			Self::Retry(error) | Self::Retirement(error) => error,
		}
	}
}
async fn retire(registration: Registration, primary: Result<()>) -> std::result::Result<(), Failure> {
	let cleanup = registration.close().await.map_err(|e| e.to_string());
	let failed = cleanup.is_err();
	retain(primary, cleanup).map_err(|error| {
		if failed {
			Failure::Retirement(error)
		} else {
			Failure::Retry(error)
		}
	})
}
impl Seat {
	async fn run(self) -> Result<()> {
		let Self {
			host,
			platform,
			locator,
			register,
			mut stop,
			status,
			budget,
			incoming,
		} = self;
		let mut delay = 1_000;
		loop {
			let permit = tokio::select! { biased;
				() = stopped(&mut stop) => return Ok(()),
				permit = budget.clone().acquire_owned() => permit.map_err(|_| "Rooms relay admission closed")?,
			};
			let attempt = async {
			let registration = Registration::open(&host, &locator, &register).map_err(|e| Failure::Retry(e.to_string()))?;
			let ready = tokio::select! { biased;
				() = stopped(&mut stop) => None,
				result = platform.within(10_000, registration.ready()) => Some(result.ok_or_else(|| "Rooms relay registration timed out".to_string()).and_then(|r| r.map_err(|e| e.to_string()))),
			};
			if !matches!(ready, Some(Ok(()))) {
				return retire(registration, ready.unwrap_or(Ok(()))).await;
			}
			let ready = Ready::new(&status);
			let called = tokio::select! { biased;
				() = stopped(&mut stop) => None,
				result = registration.incoming() => Some(result.map_err(|e| e.to_string())),
			};
			drop(ready);
			if !matches!(called, Some(Ok(()))) {
				return retire(registration, called.unwrap_or(Ok(()))).await;
			}
			// Once transferred, the Host owns cancellation and the finite
			// handshake. Do not drop that observation at application stop.
			let session = registration.accept(glowcap::HANDSHAKE_TIMEOUT).await.map_err(|e| {
				if e.secondary_error_count() > 0 { Failure::Retirement(e.to_string()) } else { Failure::Retry(e.to_string()) }
			})?;
			if let Err(error) = incoming.try_send((session, permit)) {
				let (session, _permit) = error.into_inner();
				return session.close(PendingWork::Cancel).await.map_err(|e| Failure::Retirement(e.to_string()));
			}
			Ok(())
		}.await;
			if *stop.borrow() {
				return attempt.map_err(Failure::message);
			}
			match attempt {
				Ok(()) => {
					delay = 1_000;
				}
				Err(Failure::Retirement(error)) => return Err(error),
				Err(Failure::Retry(error)) => {
					report(&status, error);
					tokio::select! { biased; () = stopped(&mut stop) => return Ok(()), () = gloo_timers::future::TimeoutFuture::new(delay) => {} }
					delay = (delay * 2).min(30_000);
				}
			}
		}
	}
}
