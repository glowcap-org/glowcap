//! Incoming and outgoing lines use the existing Rooms introduction and reply
//! protocol. IRC socket delivery owns the deferred acknowledgement.
use super::{
	notice::{Notice as ServerNotice, Report},
	output::Output,
};
use glowcap::{Argument, Behavior, Resolver, Session};
use rooms_application::{
	direct::Notice,
	directory::registration::{Id, Kind},
	server::irc::clients,
};
use rooms_glowcap::client::{
	self, Client,
	direct::{
		Direct,
		publisher::{Offerer, Publisher},
	},
	directory::{Directory, registration::Registration},
};
use rooms_platform::HostPlatform;
use std::{
	cell::{Cell, RefCell},
	collections::BTreeMap,
	rc::{Rc, Weak},
	sync::Arc,
};
use tokio::{
	sync::{OwnedSemaphorePermit, Semaphore, mpsc, watch},
	task::JoinHandle,
};
const PENDING: usize = 64;
struct Pending {
	frames: Vec<Vec<u8>>,
	answer: Resolver,
	caller: Session,
	_permit: OwnedSemaphorePermit,
}
struct State {
	live: Cell<bool>,
	output: Output,
	routes: RefCell<BTreeMap<String, Rc<Direct<HostPlatform>>>>,
	jobs: mpsc::Sender<Pending>,
	slots: Arc<Semaphore>,
}
impl State {
	fn new(output: Output) -> (Rc<Self>, mpsc::Receiver<Pending>) {
		let (jobs, incoming) = mpsc::channel::<Pending>(PENDING);
		let state = Rc::new(Self {
			live: Cell::new(true),
			output,
			routes: RefCell::new(BTreeMap::new()),
			jobs,
			slots: Arc::new(Semaphore::new(PENDING)),
		});
		(state, incoming)
	}
}
pub(super) struct Directs {
	state: Rc<State>,
	offerer: Rc<Offerer<HostPlatform>>,
	stop: watch::Sender<bool>,
	registration: Option<JoinHandle<Result<(), String>>>,
	delivery: Option<JoinHandle<Result<(), String>>>,
}
impl Directs {
	pub fn open(
		publisher: &Publisher<HostPlatform>,
		attachment: Rc<super::inboxes::Attachment>,
		directory: Directory<HostPlatform>,
		mut registration: Registration<HostPlatform>,
		output: Output,
		report: Report,
	) -> Result<Self, String> {
		let (state, incoming) = State::new(output.clone());
		let weak = Rc::downgrade(&state);
		let offerer = Rc::new(
			publisher
				.offerer(move |peer, id| Ok(behavior(weak.clone(), peer.into(), id.clone())))
				.map_err(|e| e.to_string())?,
		);
		let offering = offerer.clone();
		let (stop, mut stopping) = watch::channel(false);
		let notices = output.clone();
		let registration = tokio::task::spawn_local(async move {
			let result: Result<(), String> = async {
			loop {
				let event = tokio::select! {
					_ = stopping.changed() => return Ok(()),
					event = registration.next() => event.map_err(|e|e.to_string())?,
				};
				let Some(event) = event else {
					return Err("Rooms registration ended".into());
				};
				if event.kind == Kind::MintInboxFor {
					let offered = tokio::select! {
						_ = stopping.changed() => return Ok(()),
						result = offering.offer_via(&directory,&attachment.exporter,&attachment.importer,event.peer.text().as_str().ok_or("IRC cannot address this Rooms name")?,&event.registration,event.opening.as_ref().ok_or("missing direct opening")?.text().as_str().ok_or("invalid direct opening")?) => result,
					};
					if let Err(error) = offered {
						notices
							.notice(&format!("Could not prepare direct messages: {error}"))
							.await?;
					}
				}
			}
			}.await;
			if let Err(error) = &result {
				notices.writer.fail(error.clone());
			}
			result
		});
		let delivery = tokio::task::spawn_local(deliver(output, incoming, report));
		Ok(Self {
			state,
			offerer,
			stop,
			registration: Some(registration),
			delivery: Some(delivery),
		})
	}
	pub async fn say(&self, directory: &Directory<HostPlatform>, peer: &str, text: &str) -> Result<(), String> {
		let key = peer.to_lowercase();
		self.state.routes.borrow_mut().retain(|_, d| d.live());
		let held = self.state.routes.borrow().get(&key).cloned();
		let direct = match held {
			Some(direct) => direct,
			None => {
				if self.state.routes.borrow().len() >= clients::DIRECTS {
					return Err(capacity_refusal());
				}
				let direct = directory.direct(peer, None).await.map_err(|e| e.to_string())?;
				let id = direct.registration().clone();
				let direct = Rc::new(
					direct
						.with_behavior(behavior(Rc::downgrade(&self.state), peer.into(), id))
						.map_err(|e| e.to_string())?,
				);
				let mut routes = self.state.routes.borrow_mut();
				if let Some(arriving) = routes.get(&key).filter(|d| d.live()) {
					arriving.clone()
				} else {
					if routes.len() >= clients::DIRECTS {
						return Err(capacity_refusal());
					}
					routes.insert(key, direct.clone());
					direct
				}
			}
		};
		drop(direct.say(text).await.map_err(|e| e.to_string())?);
		Ok(())
	}
	pub async fn close(mut self) -> Result<(), String> {
		self.state.live.set(false);
		self.state.slots.close();
		self.offerer.retire();
		self.stop.send_replace(true);
		self.state.routes.borrow_mut().clear();
		let mut result = self.offerer.close().await.map_err(|e| e.to_string());
		if let Some(task) = self.registration.take() {
			result = crate::cleanup::combine(result, task.await.map_err(|e| e.to_string()).and_then(|r| r));
		}
		// The receiver has only weak references to state. Drop the sender after
		// publication retirement, then observe every admitted acknowledgement.
		let delivery = self.delivery.take();
		drop(self);
		if let Some(task) = delivery {
			result = crate::cleanup::combine(result, task.await.map_err(|e| e.to_string()).and_then(|r| r));
		}
		result
	}
}
impl Drop for Directs {
	fn drop(&mut self) {
		self.state.live.set(false);
		self.offerer.retire();
		self.stop.send_replace(true);
		if let Some(task) = self.registration.take() {
			task.abort();
		}
		if let Some(task) = self.delivery.take() {
			task.abort();
		}
	}
}
fn behavior(state: Weak<State>, peer: String, id: Id) -> Behavior {
	Box::new(client::direct::receiver(move |notice, session| {
		let state = state
			.upgrade()
			.filter(|s| s.live.get())
			.ok_or("the IRC recipient disconnected")?;
		match notice {
			Notice::Message {
				text,
				attachments,
				reply,
				previews: _,
			} => {
				let count = attachments.len();
				drop(attachments);
				let mut frames = vec![state.output.chat_bytes(&peer, text, &state.output.nick)?];
				if count > 0 {
					frames.push(state.output.notice_bytes(&format!(
						"{peer} sent {count} file(s); IRC cannot carry their capabilities"
					))?);
				}
				let permit = state
					.slots
					.clone()
					.try_acquire_owned()
					.map_err(|_| "the IRC direct delivery queue is full")?;
				let slot = state
					.jobs
					.try_reserve()
					.map_err(|_| "the IRC direct delivery owner ended")?;
				if let Some(reply) = reply {
					remember(&state, &peer, &id, &session, reply)?;
				}
				let answer = session.host().defer_turn().map_err(|e| e.to_string())?;
				slot.send(Pending {
					frames,
					answer,
					caller: session,
					_permit: permit,
				});
				Ok(Argument::Void)
			}
			Notice::Ready(reply) => {
				remember(&state, &peer, &id, &session, reply)?;
				Ok(Argument::Void)
			}
			Notice::Typing(_) => Ok(Argument::Void),
			_ => Err("IRC cannot receive that capability offer".into()),
		}
	}))
}
fn remember(state: &Rc<State>, peer: &str, id: &Id, session: &Session, reply: glowcap::Ref) -> Result<(), String> {
	let mut routes = state.routes.borrow_mut();
	routes.retain(|_, d| d.live());
	let key = peer.to_lowercase();
	if routes.get(&key).is_some_and(|held| held.uses_route(session, &reply)) {
		return Ok(());
	}
	if !routes.contains_key(&key) && routes.len() >= clients::DIRECTS {
		return Err(capacity_refusal());
	}
	let direct = Direct::adopt(Client::new(session.borrowed(), HostPlatform), reply, id.clone())
		.with_behavior(behavior(Rc::downgrade(state), peer.into(), id.clone()))
		.map_err(|e| e.to_string())?;
	routes.insert(key, Rc::new(direct));
	Ok(())
}

async fn deliver(output: Output, mut incoming: mpsc::Receiver<Pending>, report: Report) -> Result<(), String> {
	while let Some(mut job) = incoming.recv().await {
		let mut result = Ok(());
		for frame in job.frames {
			result = match output.enqueue(frame) {
				Ok(receipt) => receipt.wait().await.map_err(|e| e.reason),
				Err(error) => Err(error),
			};
			if result.is_err() {
				break;
			}
		}
		let answer = match result {
			Ok(()) => job.answer.fulfill_value(&Argument::Void),
			Err(reason) => job.answer.break_with(&reason),
		};
		if let Err(error) = answer
			&& job.caller.is_open()
		{
			report(ServerNotice::DirectAcknowledgementFailed(error.to_string()));
		}
	}
	Ok(())
}

#[cfg(test)]
mod tests;

fn capacity_refusal() -> String {
	use rooms_application::failure::{Failure, FailureCode};
	Failure {
		code: FailureCode::TooManyDirects,
		detail: "IRC direct line capacity reached",
	}
	.to_string()
}
