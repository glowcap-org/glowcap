//! Accepted sessions have one Host-level owner, independent of the listener
//! generation that delivered them. Retiring a listener does not retire peers.
use super::{Result, retain};
use glowcap::{PendingWork, Session};
use std::{
	cell::{Cell, RefCell},
	future::poll_fn,
	rc::{Rc, Weak},
};
use tokio::{
	sync::{Notify, watch},
	task::JoinSet,
};

const MAX_PEERS: usize = 64;
struct State {
	closed: Cell<bool>,
	workers: RefCell<JoinSet<Result<()>>>,
	changed: Notify,
	stop: watch::Receiver<bool>,
}
#[derive(Clone)]
pub(super) struct Admission(Weak<State>);
pub(super) struct Refused {
	pub session: Session,
	pub capacity: bool,
}
pub(super) struct Peers {
	state: Rc<State>,
	stop: watch::Sender<bool>,
	ended: watch::Receiver<Option<Result<()>>>,
}
impl Peers {
	pub fn start() -> Self {
		let (stop, stopping) = watch::channel(false);
		let (finished, ended) = watch::channel(None);
		let state = Rc::new(State {
			closed: Cell::new(false),
			workers: RefCell::new(JoinSet::new()),
			changed: Notify::new(),
			stop: stopping.clone(),
		});
		let running = state.clone();
		tokio::task::spawn_local(async move {
			finished.send_replace(Some(run(running, stopping).await));
		});
		Self { state, stop, ended }
	}
	pub fn admission(&self) -> Admission {
		Admission(Rc::downgrade(&self.state))
	}
	pub async fn close(&self) -> Result<()> {
		self.state.closed.set(true);
		self.stop.send_replace(true);
		super::connections::settled(&mut self.ended.clone()).await
	}
}
impl Drop for Peers {
	fn drop(&mut self) {
		self.state.closed.set(true);
		self.stop.send_replace(true);
	}
}
impl Admission {
	/// Transfer custody or return the untouched session. On refusal the
	/// listener must stop admission and observe this session's close itself.
	pub fn offer(&self, session: Session) -> std::result::Result<(), Refused> {
		let Some(state) = self.0.upgrade() else {
			return Err(Refused {
				session,
				capacity: false,
			});
		};
		if state.closed.get() {
			return Err(Refused {
				session,
				capacity: false,
			});
		}
		let mut workers = state.workers.borrow_mut();
		if workers.len() >= MAX_PEERS {
			return Err(Refused {
				session,
				capacity: true,
			});
		}
		workers.spawn_local(serve(session, state.stop.clone()));
		state.changed.notify_one();
		Ok(())
	}
}
async fn stopped(stop: &mut watch::Receiver<bool>) {
	if !*stop.borrow() {
		let _ = stop.changed().await;
	}
}
async fn serve(session: Session, mut stop: watch::Receiver<bool>) -> Result<()> {
	let serving = session.serve();
	tokio::pin!(serving);
	let ended = tokio::select! { result = &mut serving => Some(result.map_err(|e| e.to_string())), () = stopped(&mut stop) => None };
	let result = retain(
		ended.clone().unwrap_or(Ok(())),
		session.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
	);
	if ended.is_none() {
		retain(result, serving.await.map_err(|e| e.to_string()))
	} else {
		result
	}
}
async fn run(state: Rc<State>, mut stop: watch::Receiver<bool>) -> Result<()> {
	loop {
		tokio::select! { biased;
			() = stopped(&mut stop) => break,
			Some(ended) = poll_fn(|cx| state.workers.borrow_mut().poll_join_next(cx)) => {
				if let Err(error) = ended.map_err(|e| e.to_string()).and_then(|outcome| outcome) { super::driver::report(&error); }
			},
			() = state.changed.notified() => {},
		}
	}
	state.closed.set(true);
	let mut outcome = Ok(());
	while let Some(ended) = poll_fn(|cx| state.workers.borrow_mut().poll_join_next(cx)).await {
		outcome = retain(outcome, ended.map_err(|e| e.to_string()).and_then(|outcome| outcome));
	}
	outcome
}
