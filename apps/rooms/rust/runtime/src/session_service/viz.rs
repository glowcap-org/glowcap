//! One serialized visualization publisher per session. Configuration changes
//! coalesce while the previous socket retires; shutdown joins that same owner.
use super::error::Error;
use crate::session_commands::SessionCommands;
use glowcap::{enable_trace, Argument};
use std::{
	cell::{Cell, RefCell},
	future::Future,
	ops::Deref,
	pin::Pin,
	rc::Rc,
};
use tokio::sync::watch;
mod publish;
#[cfg(test)]
mod publish_tests;
use publish::Publisher;
pub use publish::{Input, Socket, Transport};

type Notify = Rc<dyn Fn(&str)>;
type Choice = (String, String);
#[derive(Clone)]
pub struct Viz<T: Transport>(Rc<Owner<T>>);
struct Owner<T: Transport> {
	state: Rc<State<T>>,
}
impl<T: Transport> Deref for Owner<T> {
	type Target = State<T>;
	fn deref(&self) -> &Self::Target {
		&self.state
	}
}
impl<T: Transport> Drop for Owner<T> {
	fn drop(&mut self) {
		stop(&self.state);
	}
}
struct State<T: Transport> {
	transport: T,
	held: RefCell<Option<Held>>,
	wanted: RefCell<Option<Choice>>,
	failure: RefCell<Option<(String, String)>>,
	dirty: watch::Sender<()>,
	requested: watch::Sender<()>,
	notify: RefCell<Option<Notify>>,
	started: Cell<bool>,
	stopped: Cell<bool>,
	finished: watch::Sender<Option<Result<(), String>>>,
}
struct Held {
	scope: String,
	swiss: String,
	publisher: Publisher,
	uninstall: Option<Box<dyn FnOnce()>>,
}
impl Held {
	fn stop(&mut self) {
		if let Some(uninstall) = self.uninstall.take() {
			uninstall();
		}
		self.publisher.stop();
	}
}
impl<T: Transport> Viz<T> {
	pub fn new(transport: T) -> Self {
		Self(Rc::new(Owner {
			state: Rc::new(State {
				transport,
				held: RefCell::new(None),
				wanted: RefCell::new(None),
				failure: RefCell::new(None),
				dirty: watch::channel(()).0,
				requested: watch::channel(()).0,
				notify: RefCell::new(None),
				started: Cell::new(false),
				stopped: Cell::new(false),
				finished: watch::channel(None).0,
			}),
		}))
	}
	pub fn on_invalidated(&self, notify: Notify) {
		*self.0.notify.borrow_mut() = Some(notify);
	}
	pub fn kick(&self) {
		self.0.dirty.send_replace(());
	}
	pub fn changes(&self) -> watch::Receiver<()> {
		self.0.dirty.subscribe()
	}
	pub fn snapshot(&self, scope: &str, commands: &SessionCommands) -> Result<Argument, Error> {
		let present = commands.view().read(|state| {
			Ok::<_, Error>(
				state
					.checkpoint()?
					.operations()
					.any(|credential| credential.capability == "viz" && credential.scope == scope),
			)
		})??;
		if !present {
			return Err(Error::refused(format!(
				"this session has no viz capability for {scope}"
			)));
		}
		let held = self.0.held.borrow();
		let (connected, refusal) = match held.as_ref().filter(|held| held.scope == scope) {
			Some(held) => (held.publisher.connected(), held.publisher.refusal()),
			None => (
				false,
				self.0
					.failure
					.borrow()
					.as_ref()
					.filter(|(failed, _)| failed == scope)
					.map(|(_, reason)| reason.clone()),
			),
		};
		Ok(Argument::String(
			serde_json::json!({
				"url": scope,
				"connected": connected,
				"refusal": refusal,
			})
			.to_string(),
		))
	}
	pub fn reconcile(&self, commands: &SessionCommands) {
		if self.0.stopped.get() {
			return;
		}
		let wanted = commands
			.view()
			.read(|state| {
				state.checkpoint().ok().and_then(|checkpoint| {
					checkpoint
						.operations()
						.find(|credential| credential.capability == "viz")
						.map(|credential| (credential.scope.to_owned(), credential.swiss.to_owned()))
				})
			})
			.ok()
			.flatten();
		if *self.0.wanted.borrow() == wanted {
			return;
		}
		*self.0.wanted.borrow_mut() = wanted;
		self.0.requested.send_replace(());
		if !self.0.started.replace(true) {
			let state = self.0.state.clone();
			tokio::task::spawn_local(async move {
				let result = supervise(&state).await;
				state.stopped.set(true);
				state.finished.send_replace(Some(result));
			});
		}
	}
	pub async fn close(&self) -> Result<(), Error> {
		stop(&self.0);
		let mut ended = self.0.finished.subscribe();
		loop {
			if let Some(result) = ended.borrow().clone() {
				return result.map_err(Error::runtime);
			}
			ended
				.changed()
				.await
				.map_err(|_| Error::runtime("visualizer supervisor lost its shutdown owner"))?;
		}
	}
}
fn stop<T: Transport>(state: &State<T>) {
	state.stopped.set(true);
	if let Some(held) = state.held.borrow_mut().as_mut() {
		held.stop();
	}
	state.requested.send_replace(());
	if !state.started.get() {
		state.finished.send_replace(Some(Ok(())));
	}
}
fn invalidated<T: Transport>(state: &State<T>, scope: &str) {
	state.dirty.send_replace(());
	let notify = state.notify.borrow().clone();
	if let Some(notify) = notify {
		notify(scope);
	}
}
async fn retire<T: Transport>(state: &State<T>) -> Result<(), String> {
	let held = state.held.borrow_mut().take();
	let Some(mut held) = held else { return Ok(()) };
	held.stop();
	invalidated(state, &held.scope);
	let result = held.publisher.close().await;
	if let Err(error) = &result {
		*state.failure.borrow_mut() = Some((held.scope.clone(), error.clone()));
		invalidated(state, &held.scope);
	}
	result
}
async fn supervise<T: Transport>(state: &Rc<State<T>>) -> Result<(), String> {
	let mut requested = state.requested.subscribe();
	loop {
		if state.stopped.get() {
			return retire(state).await;
		}
		let matches = {
			let held = state.held.borrow();
			let wanted = state.wanted.borrow();
			match (held.as_ref(), wanted.as_ref()) {
				(Some(held), Some((scope, swiss))) => held.scope == *scope && held.swiss == *swiss,
				(None, None) => true,
				_ => false,
			}
		};
		if matches {
			if requested.changed().await.is_err() {
				return retire(state).await;
			}
			continue;
		}
		retire(state).await?;
		if state.stopped.get() {
			continue;
		}
		let wanted = state.wanted.borrow().clone();
		let Some((scope, swiss)) = wanted else {
			continue;
		};
		let publisher = Publisher::start(
			state.transport.clone(),
			scope.clone(),
			swiss.clone(),
			Rc::new({
				let state = Rc::downgrade(state);
				let scope = scope.clone();
				move |_| {
					if let Some(state) = state.upgrade() {
						invalidated(&state, &scope);
					}
				}
			}),
			Rc::new({
				let state = Rc::downgrade(state);
				let scope = scope.clone();
				move |_| {
					if let Some(state) = state.upgrade() {
						invalidated(&state, &scope);
					}
				}
			}),
		);
		let installed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
			let publisher = publisher.clone();
			enable_trace(Box::new(move |event| publisher.record(event)), None)
		}));
		let uninstall = match installed {
			Ok(uninstall) => Box::new(uninstall) as Box<dyn FnOnce()>,
			Err(_) => {
				let result = publisher.close().await;
				let error = match result {
					Ok(()) => "visualizer trace installation failed".into(),
					Err(error) => format!("visualizer trace installation failed; cleanup: {error}"),
				};
				*state.failure.borrow_mut() = Some((scope.clone(), error.clone()));
				invalidated(state, &scope);
				return Err(error);
			}
		};
		state.failure.borrow_mut().take();
		*state.held.borrow_mut() = Some(Held {
			scope: scope.clone(),
			swiss,
			publisher,
			uninstall: Some(uninstall),
		});
		invalidated(state, &scope);
	}
}
impl<T: Transport> super::Visualization for Viz<T> {
	fn stop(&self) {
		stop(&self.0);
	}
	fn close(&self) -> Pin<Box<dyn Future<Output = Result<(), Error>> + '_>> {
		Box::pin(self.close())
	}
	fn on_invalidated(&self, notify: Notify) {
		self.on_invalidated(notify);
	}
	fn kick(&self) {
		self.kick();
	}
	fn changes(&self) -> watch::Receiver<()> {
		self.changes()
	}
	fn snapshot(&self, scope: &str, commands: &SessionCommands) -> Result<Argument, Error> {
		self.snapshot(scope, commands)
	}
	fn reconcile(&self, commands: &SessionCommands) {
		self.reconcile(commands);
	}
}
