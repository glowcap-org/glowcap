//! Browser-local composition. Volatile documents choose the Host identity;
//! archive identity belongs to the device. One supervisor owns all service work.
use super::{Environment, Result};
use crate::platform::Platform;
use rooms_application::{documents::SessionDocument, session::checkpoint::Checkpoint};
use rooms_runtime::{
	documents::{VolatileDocument, VolatileDocuments},
	grants::DurableGrants,
	service::{Inputs, Local, Session},
	session::{
		commands::{SessionCommands, SessionWorker},
		state::DurableSession,
	},
};
use std::rc::Rc;
use tokio::sync::{mpsc, oneshot, watch};

type Worker = SessionWorker<VolatileDocuments, Platform, Platform>;
pub(super) struct Prepared {
	commands: SessionCommands,
	worker: Worker,
}
impl Prepared {
	pub async fn open(platform: Platform) -> Result<Self> {
		let (commands, worker) = SessionCommands::open(
			DurableSession::new(VolatileDocuments::default(), platform.clone()),
			platform,
		)
		.await
		.map_err(|e| e.to_string())?;
		Ok(Self { commands, worker })
	}
	pub fn seed(&self) -> Result<[u8; 32]> {
		self.commands
			.view()
			.read(|state| state.identity_seed().copied())
			.map_err(|e| e.to_string())?
			.map_err(|e| e.to_string())
	}
}
pub(super) struct Owner {
	pub access: Local<Platform>,
	pub control: Control,
	pub publication: tokio::sync::Mutex<()>,
	eraser: crate::storage::Eraser,
	erased_pause: std::cell::RefCell<Option<rooms_runtime::archive::session::RecordingPause>>,
	publication_route: Rc<std::cell::RefCell<Option<super::signaling::RouteLease>>>,
	stop: watch::Sender<bool>,
	pub ended: watch::Receiver<Option<Result<()>>>,
}
enum Request {
	Publication(oneshot::Sender<Result<Option<String>>>),
	Publish(glowcap::Locator, oneshot::Sender<Result<String>>),
	Verify(String, oneshot::Sender<Result<()>>),
}
#[derive(Clone)]
pub(super) struct Control(mpsc::Sender<Request>);
impl Control {
	pub async fn verify(&self, link: String) -> Result<()> {
		let (reply, answer) = oneshot::channel();
		self.0
			.try_send(Request::Verify(link, reply))
			.map_err(|_| "Local Rooms control queue unavailable")?;
		answer
			.await
			.map_err(|_| "Local Rooms owner closed during verification")?
	}
}
impl Owner {
	pub async fn open(environment: &Environment, prepared: Prepared, checkpoint: Checkpoint) -> Result<Self> {
		let archive = crate::storage::PageArchive::open(environment.platform.clone())
			.await
			.map_err(|e| e.to_string())?;
		let source = archive.source().clone();
		let eraser = archive.eraser();
		let designator = environment.runtime.host().designator().map_err(|e| e.to_string())?;
		let locator = environment.relay.as_ref().map_or_else(
			|| glowcap::Locator::bare(glowcap::TRANSPORT_WEBRTC, &designator),
			|relay| relay.locator().clone(),
		);
		environment
			.runtime
			.host()
			.set_advertised_locator(&locator)
			.map_err(|e| e.to_string())?;
		let platform = environment.platform.clone();
		let mut session = Session::open_local(
			Inputs {
				platform: platform.clone(),
				connections: environment.connections.clone(),
				locator,
				recording_source: Some(source),
				entropy: || platform.clone(),
				trace: Rc::new(rooms_runtime::service::trace::Trace::new(platform.clone())),
				report: Rc::new(|notice| web_sys::console::error_1(&format!("Rooms session: {notice:?}").into())),
			},
			(prepared.commands, prepared.worker),
			DurableGrants::new(VolatileDocument::new(SessionDocument::Grants)),
			VolatileDocument::new(SessionDocument::BridgeSecrets),
			archive,
			Some(checkpoint),
		)
		.await
		.map_err(|e| e.to_string())?;
		let access = session.local();
		environment.signaling.local(session.directories());
		let incoming = environment.relay.is_none().then(|| {
			super::local_signaling::Owner::start(
				session.directories(),
				environment.signaling.clone(),
				environment.ice.clone(),
				environment.incoming.admission(),
				environment.trouble.clone(),
			)
		});
		let (control, mut requests) = mpsc::channel::<Request>(16);
		let (stop, mut stopping) = watch::channel(false);
		let (finished, ended) = watch::channel(None);
		let publication_route = Rc::new(std::cell::RefCell::new(None));
		let retiring_route = publication_route.clone();
		// The terminal signal is retained by the parent through final close.
		tokio::task::spawn_local(async move {
			let failure = loop {
				if *stopping.borrow() {
					break Ok(());
				}
				tokio::select! {
					biased;
					_ = stopping.changed() => break Ok(()),
					result = signaling_ended(&incoming) => break result.and(Err("Local signaling supervisor ended".into())),
					error = session.ended() => break Err(error.to_string()),
					request = requests.recv() => match request {
						Some(Request::Publication(reply)) => { let _ = reply.send(Ok(session.link().map(str::to_owned))); },
						Some(Request::Publish(locator, reply)) => { let _ = reply.send(session.publish_at(locator).await.map(str::to_owned).map_err(|e| e.to_string())); },
						Some(Request::Verify(link, reply)) => { let _ = reply.send(session.verify_sibling(&link).await.map_err(|e| e.to_string())); },
						None => break Ok(()),
					},
				}
			};
			retiring_route.borrow_mut().take();
			requests.close();
			while let Some(request) = requests.recv().await {
				match request {
					Request::Publication(reply) => {
						let _ = reply.send(Err("local Rooms session closed".into()));
					}
					Request::Publish(_, reply) => {
						let _ = reply.send(Err("local Rooms session closed".into()));
					}
					Request::Verify(_, reply) => {
						let _ = reply.send(Err("local Rooms session closed".into()));
					}
				}
			}
			let signaling = match incoming {
				Some(incoming) => incoming.close().await,
				None => Ok(()),
			};
			let outcome = super::retain(
				super::retain(failure, signaling),
				session.close().await.map_err(|e| e.to_string()),
			);
			finished.send_replace(Some(outcome));
		});
		Ok(Self {
			access,
			control: Control(control),
			publication: Default::default(),
			eraser,
			erased_pause: Default::default(),
			publication_route,
			stop,
			ended,
		})
	}
	pub async fn erase_browser_archive(&self) -> Result<()> {
		let pause = self.access.pause_recording().map_err(|e| e.to_string())?;
		self.eraser.erase().await.map_err(|e| e.to_string())?;
		*self.erased_pause.borrow_mut() = Some(pause);
		Ok(())
	}
	pub async fn published(&self) -> Result<Option<String>> {
		let (reply, answer) = oneshot::channel();
		self.control
			.0
			.try_send(Request::Publication(reply))
			.map_err(|_| "local Rooms publication queue unavailable")?;
		answer.await.map_err(|_| "local Rooms publication owner closed")?
	}
	pub async fn publish(&self, locator: glowcap::Locator) -> Result<String> {
		let (reply, answer) = oneshot::channel();
		self.control
			.0
			.try_send(Request::Publish(locator, reply))
			.map_err(|_| "local Rooms publication queue unavailable")?;
		answer.await.map_err(|_| "local Rooms publication owner closed")?
	}
	pub fn hold_publication_route(&self, route: Option<super::signaling::RouteLease>) {
		*self.publication_route.borrow_mut() = route;
	}
	pub async fn close(&self) -> Result<()> {
		self.publication_route.borrow_mut().take();
		self.stop.send_replace(true);
		let mut ended = self.ended.clone();
		loop {
			if let Some(result) = ended.borrow().clone() {
				return result;
			}
			ended
				.changed()
				.await
				.map_err(|_| "local Rooms owner ended without shutdown outcome")?;
		}
	}
}
async fn signaling_ended(incoming: &Option<super::local_signaling::Owner>) -> Result<()> {
	match incoming {
		Some(incoming) => incoming.ended().await,
		None => std::future::pending().await,
	}
}
impl Drop for Owner {
	fn drop(&mut self) {
		self.publication_route.borrow_mut().take();
		self.stop.send_replace(true);
	}
}
