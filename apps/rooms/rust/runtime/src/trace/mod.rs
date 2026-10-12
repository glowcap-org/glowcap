//! One publisher follows exact managed workspace custody. Its socket and trace
//! hook retire before another selection starts or the attachment closes.
pub(crate) mod publish;
use crate::{Error, session::managed::SessionChanges};
use publish::Publisher;
pub use publish::{Input, Socket, Transport};
use rooms_application::{content::session::custody, session::operations::mutation::Kind};
use rooms_glowcap::client::workspace::Workspace;
use std::{cell::RefCell, rc::Rc};
use tokio::sync::watch;

pub trait Status {
	fn snapshot(&self, selected: custody::Coordinate) -> Result<String, Error>;
}
pub struct Trace<T: Transport> {
	state: Rc<State>,
	stop: watch::Sender<u64>,
	ended: watch::Receiver<Option<Result<(), Error>>>,
	finished: watch::Sender<Option<Result<(), Error>>>,
	_transport: std::marker::PhantomData<T>,
}
struct State {
	held: RefCell<Option<Held>>,
	failure: RefCell<Option<(custody::Coordinate, String, String)>>,
}
struct Held {
	selected: custody::Coordinate,
	scope: String,
	swiss: String,
	publisher: Publisher,
	uninstall: Option<Box<dyn FnOnce()>>,
	label: Option<String>,
}
impl Held {
	fn stop(&mut self) {
		if let Some(uninstall) = self.uninstall.take() {
			uninstall();
		}
		self.publisher.stop();
	}
}
impl<T: Transport> Status for Trace<T> {
	fn snapshot(&self, selected: custody::Coordinate) -> Result<String, Error> {
		let held = self.state.held.borrow();
		let (scope, connected, refusal) = match held.as_ref().filter(|held| held.selected == selected) {
			Some(held) => (held.scope.clone(), held.publisher.connected(), held.publisher.refusal()),
			None => match self
				.state
				.failure
				.borrow()
				.as_ref()
				.filter(|(coordinate, _, _)| *coordinate == selected)
			{
				Some((_, scope, reason)) => (scope.clone(), false, Some(reason.clone())),
				None => (
					String::new(),
					false,
					Some("Awaiting an authorized trace publication".into()),
				),
			},
		};
		Ok(serde_json::json!({"url":scope,"connected":connected,"refusal":refusal}).to_string())
	}
}
impl<T: Transport> Trace<T> {
	pub fn start(transport: T, workspace: Workspace<T>, mut changes: SessionChanges, report: Rc<dyn Fn(&str)>) -> Self {
		let state = Rc::new(State {
			held: RefCell::new(None),
			failure: RefCell::new(None),
		});
		let (stop, mut stopping) = watch::channel(0);
		let (finished, ended) = watch::channel(None);
		let owned = state.clone();
		let physical = transport.clone();
		let completion = finished.clone();
		tokio::task::spawn_local(async move {
			loop {
				let mut attempted = None;
				let selection = async {
					changes.ready().await.map_err(Error::from)?;
					let snapshot = workspace.snapshot().await.map_err(Error::peer)?;
					let directory = snapshot
						.intent
						.active
						.as_ref()
						.and_then(|id| {
							snapshot
								.intent
								.conversations
								.as_slice()
								.iter()
								.find(|row| row.id() == id)
						})
						.map(|row| match row {
							rooms_application::content::session::workspace::Conversation::Room(row) => &row.directory,
							rooms_application::content::session::workspace::Conversation::Direct(row) => &row.directory,
						});
					let label = snapshot
						.intent
						.directories
						.as_slice()
						.iter()
						.find(|row| directory.map_or(row.home, |id| &row.id == id))
						.and_then(|row| row.name.and(row.assigned_nick.as_ref()))
						.and_then(|nick| nick.text().as_str())
						.map(str::to_owned);
					let selected = snapshot
						.intent
						.operations
						.as_slice()
						.iter()
						.find(|row| row.kind == Kind::Trace);
					let Some(selected) = selected else {
						return Ok(None);
					};
					attempted = Some(selected.handle);
					// Inspection checks UseOperations independently of publication export.
					workspace.trace_snapshot(selected.handle).await.map_err(Error::peer)?;
					let uri = workspace
						.custody_recipe(selected.handle)
						.await
						.map_err(Error::peer)?
						.ok_or_else(|| Error::refused("the selected trace has no saved publication recipe"))?;
					let (scope, swiss) = publication(&uri)?;
					Ok::<_, Error>(Some((selected.handle, scope, swiss, label)))
				};
				let selected = tokio::select! { biased;
					_ = stopping.changed() => break,
					selected = selection => selected,
				};
				let selected = match selected {
					Ok(selected) => selected,
					Err(error) => {
						report(&error.to_string());
						let held = owned.held.borrow();
						if let Some(coordinate) = attempted.or_else(|| held.as_ref().map(|held| held.selected)) {
							let scope = held
								.as_ref()
								.filter(|held| held.selected == coordinate)
								.map_or_else(String::new, |held| held.scope.clone());
							*owned.failure.borrow_mut() = Some((coordinate, scope, error.to_string()));
						}
						None
					}
				};
				let same = match (&*owned.held.borrow(), &selected) {
					(Some(held), Some((coordinate, scope, swiss, _))) => {
						held.selected == *coordinate && held.scope == *scope && held.swiss == *swiss
					}
					(None, None) => true,
					_ => false,
				};
				if !same {
					if let Err(error) = retire(&owned).await {
						report(&error.to_string());
						break;
					}
					if let Some((selected, scope, swiss, label)) = selected {
						let publisher =
							Publisher::start(physical.clone(), scope.clone(), swiss.clone(), Rc::new(|_| {}), {
								let report = report.clone();
								Rc::new(move |reason| report(&reason))
							});
						owned.failure.borrow_mut().take();
						let recorder = publisher.clone();
						let installed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
							glowcap::enable_trace(Box::new(move |event| recorder.record(event)), label.as_deref())
						}));
						let (uninstall, failed) = match installed {
							Ok(uninstall) => (Some(Box::new(uninstall) as Box<dyn FnOnce()>), false),
							Err(_) => (None, true),
						};
						*owned.held.borrow_mut() = Some(Held {
							selected,
							scope: scope.clone(),
							swiss,
							publisher,
							uninstall,
							label,
						});
						if failed {
							let error = Error::closed("trace hook installation failed");
							report(&error.to_string());
							*owned.failure.borrow_mut() = Some((selected, scope, error.to_string()));
							break;
						}
					}
				} else if let Some((_, _, _, label)) = selected {
					let mut held = owned.held.borrow_mut();
					if let Some(held) = held.as_mut()
						&& held.label != label
					{
						glowcap::set_trace_label(label.as_deref());
						held.label = label;
					}
				}
				tokio::select! { biased;
					_ = stopping.changed() => break,
					changed = changes.changed() => if let Err(error) = changed {
							report(&error.to_string());
							if let Some(held) = owned.held.borrow().as_ref() {
								*owned.failure.borrow_mut() = Some((held.selected, held.scope.clone(), error.to_string()));
							}
						// Failed observation cannot authorize continued publication.
						if let Err(error) = retire(&owned).await { report(&error.to_string()); break; }
						changes.retry();
					},
				}
			}
			loop {
				stopping.borrow_and_update();
				let result = retire(&owned).await;
				let complete = result.is_ok();
				finished.send_replace(Some(result));
				if complete {
					break;
				}
				if stopping.changed().await.is_err() {
					break;
				}
			}
		});
		Self {
			state,
			stop,
			ended,
			finished: completion,
			_transport: std::marker::PhantomData,
		}
	}
	pub async fn close(&self) -> Result<(), Error> {
		if matches!(&*self.ended.borrow(), Some(Ok(()))) {
			return Ok(());
		}
		self.finished.send_replace(None);
		if let Some(held) = self.state.held.borrow_mut().as_mut() {
			held.stop();
		}
		self.stop
			.send_modify(|generation| *generation = generation.wrapping_add(1));
		let mut ended = self.ended.clone();
		loop {
			if let Some(result) = ended.borrow_and_update().clone() {
				return result;
			}
			ended
				.changed()
				.await
				.map_err(|_| Error::closed("trace publisher lost its close barrier"))?;
		}
	}
}
impl<T: Transport> Drop for Trace<T> {
	fn drop(&mut self) {
		if let Some(held) = self.state.held.borrow_mut().as_mut() {
			held.stop();
		}
		self.stop
			.send_modify(|generation| *generation = generation.wrapping_add(1));
	}
}
async fn retire(state: &State) -> Result<(), Error> {
	let held = state.held.borrow_mut().take();
	let Some(mut held) = held else {
		return Ok(());
	};
	held.stop();
	match held.publisher.close().await {
		Ok(()) => Ok(()),
		Err(error) => {
			*state.failure.borrow_mut() = Some((held.selected, held.scope.clone(), error.to_string()));
			*state.held.borrow_mut() = Some(held);
			Err(error)
		}
	}
}
/// The exporter advertises its producer route in the saved capability recipe.
/// An arbitrary UI endpoint cannot redirect this held credential to another host.
fn publication(uri: &str) -> Result<(String, String), Error> {
	let parsed = glowcap::parse_sturdyref(uri, glowcap::CaptpVersion::V1_0).map_err(Error::from)?;
	let scope = match parsed.locator.hints.get("trace-publish") {
		Some(glowcap::HintValue::String(scope)) if scope.len() <= 2048 => scope.clone(),
		_ => {
			return Err(Error::refused(
				"the trace publication has no advertised producer endpoint",
			));
		}
	};
	let swiss = String::from_utf8(parsed.swissnum).map_err(|_| Error::invalid("invalid trace publication token"))?;
	rooms_application::server::trace::producer_endpoint(&scope).map_err(Error::invalid)?;
	if !rooms_application::server::operations::is_swiss(&swiss) {
		return Err(Error::invalid("invalid trace publication token"));
	}
	Ok((scope, swiss))
}
