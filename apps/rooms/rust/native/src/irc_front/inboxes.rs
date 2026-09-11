//! One public inbox Host, independent directory Hosts. A Noise attachment
//! transfers capabilities once; subsequent DMs reach the public Host directly.
use crate::{cleanup, serving};
use glowcap::{tcp, ConnectOptions, Host, ListenerIdentity, Locator, PendingWork, Runtime, Session};
use std::{cell::RefCell, collections::BTreeMap, rc::Rc, time::Duration};
use tokio::{sync::oneshot, task::JoinSet};

type Waiting = Rc<RefCell<BTreeMap<String, oneshot::Sender<Session>>>>;
pub(super) struct Inboxes {
	listener: Option<tcp::Server>,
	local: Locator,
	public: Locator,
	waiting: Waiting,
}
impl Inboxes {
	pub async fn open(host: &Host, public: &Locator, selected: &serving::Listener, bind: &str) -> Result<Self, String> {
		// The driver owns one listener per transport profile. Reuse public
		// Noise for attachments, dialing its bound address rather than requiring
		// a machine to reach itself through its public DNS/NAT route.
		let (listener, local) = match selected {
			serving::Listener::Tcp(server) if public.transport == glowcap::TRANSPORT_NOISE_TCP => {
				let local_bind = match bind {
					"0.0.0.0" => "127.0.0.1",
					"::" | "[::]" => "::1",
					bind => bind,
				};
				(
					None,
					tcp::noise::locator(
						&public.designator,
						local_bind,
						server.port().map_err(|e| e.to_string())?,
					),
				)
			}
			_ => {
				let listener = tcp::noise::listen(
					"127.0.0.1",
					0,
					tcp::ListenOptions {
						identity: ListenerIdentity::Host(host.clone()),
						..Default::default()
					},
				)
				.await
				.map_err(|e| format!("opening the local inbox listener failed: {e}"))?;
				let setup = (|| {
					let local = listener.locator().map_err(|e| e.to_string())?;
					selected.select().map_err(|e| e.to_string())?;
					Ok::<_, String>(local)
				})();
				match setup {
					Ok(local) => (Some(listener), local),
					Err(error) => {
						return Err(
							cleanup::combine(Err(error), listener.close().await.map_err(|e| e.to_string()))
								.expect_err("inbox listener setup failed"),
						)
					}
				}
			}
		};
		Ok(Self {
			listener,
			local,
			public: public.clone(),
			waiting: Default::default(),
		})
	}
	/// Match attachments by their fresh user Host's authenticated identity.
	/// A waiter cancelled after matching drops the yielded session.
	pub fn attaching(&self, session: Session) -> Result<Option<Session>, String> {
		let identity = session.partner_identity().map_err(|e| e.to_string())?;
		if identity.durable_identity_authenticated() {
			let waiter = self.waiting.borrow_mut().remove(&identity.designator);
			if let Some(waiter) = waiter {
				let _ = waiter.send(session.with_gc());
				return Ok(None);
			}
		}
		Ok(Some(session))
	}
	pub async fn accept_private(&self) -> Result<Session, serving::TransportError> {
		match &self.listener {
			Some(listener) => listener.accept().await.map_err(Box::new),
			None => std::future::pending().await,
		}
	}
	pub async fn attach(&self, runtime: &Runtime) -> Result<Rc<Attachment>, String> {
		let key = runtime.host().designator().map_err(|e| e.to_string())?;
		let (ready, accepted) = oneshot::channel();
		if self.waiting.borrow().contains_key(&key) {
			return Err("this user Host is already attaching an inbox".into());
		}
		self.waiting.borrow_mut().insert(key.clone(), ready);
		let _pending = Pending {
			waiting: self.waiting.clone(),
			key,
		};
		let accepting = async { accepted.await.map_err(|_| "local inbox acceptance ended".to_owned()) };
		let dialing = async {
			runtime
				.connect(&self.local, ConnectOptions::default())
				.await
				.map(|s| s.with_gc())
				.map_err(|e| e.to_string())
		};
		let (importer, exporter) =
			tokio::time::timeout(Duration::from_secs(10), async { tokio::try_join!(dialing, accepting) })
				.await
				.map_err(|_| "local inbox attachment timed out")??;
		importer
			.set_exporter_locator(Some(&self.public))
			.map_err(|e| e.to_string())?;
		// Registration identifies the user peer. The shared inbox's public
		// reachability is carried by its capability's handoff, separately.
		let identity = glowcap::format_locator_uri(&Locator {
			transport: glowcap::TRANSPORT_NOISE_TCP.into(),
			designator: runtime.host().designator().map_err(|e| e.to_string())?,
			hints: Default::default(),
			hint_wire_form: glowcap::HintWireForm::BooleanFalse,
		})
		.map_err(|e| e.to_string())?;
		let (imported, exported) = (importer.borrowed(), exporter.borrowed());
		let mut serving = JoinSet::new();
		// Both ends admit inbound immediately. An importer may redeem a gift
		// on this existing session before ever fetching an alias itself.
		serving.spawn_local(serving::serve_partner(importer));
		serving.spawn_local(serving::serve_partner(exporter));
		Ok(Rc::new(Attachment {
			identity,
			importer: imported,
			exporter: exported,
			serving: RefCell::new(Some(serving)),
		}))
	}
	pub async fn close(&self) -> Result<(), String> {
		self.waiting.borrow_mut().clear();
		match &self.listener {
			Some(listener) => listener.close().await.map_err(|e| e.to_string()),
			None => Ok(()),
		}
	}
}
struct Pending {
	waiting: Waiting,
	key: String,
}
impl Drop for Pending {
	fn drop(&mut self) {
		self.waiting.borrow_mut().remove(&self.key);
	}
}

pub(super) struct Attachment {
	pub identity: String,
	pub importer: Session,
	pub exporter: Session,
	serving: RefCell<Option<JoinSet<Result<(), serving::Ended>>>>,
}
impl Attachment {
	pub async fn close(&self) -> Result<(), String> {
		let result = self
			.importer
			.close(PendingWork::Cancel)
			.await
			.map_err(|e| e.to_string());
		let mut result = cleanup::combine(
			result,
			self.exporter
				.close(PendingWork::Cancel)
				.await
				.map_err(|e| e.to_string()),
		);
		let task = self.serving.borrow_mut().take();
		if let Some(mut tasks) = task {
			while let Some(ended) = tasks.join_next().await {
				result = cleanup::combine(
					result,
					ended
						.map_err(|e| e.to_string())
						.and_then(|r| r.map_err(|e| e.to_string())),
				);
			}
		}
		result
	}
}
