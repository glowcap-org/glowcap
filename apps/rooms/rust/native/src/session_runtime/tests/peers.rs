use glowcap::{tcp, Argument, Host, ListenerIdentity, PendingWork, Ref, Session};
use std::{cell::Cell, rc::Rc};
use tokio::{
	sync::{mpsc, oneshot},
	task::JoinHandle,
};
const ID: &str = "11111111-1111-4111-8111-111111111111";
pub struct Arrival {
	pub index: usize,
	pub connection: usize,
	pub nick: String,
	pub voucher: Option<Vec<u8>>,
	pub session: Rc<Session>,
	inbox: Ref,
}
impl Arrival {
	pub async fn ack(&self) {
		self.session
			.send(
				&self.inbox,
				"notify",
				&["registered".into(), self.nick.clone().into(), ID.into()],
			)
			.await
			.unwrap();
	}
	pub async fn notify(&self, kind: &str) {
		self.notify_registration(kind, ID).await;
	}
	pub async fn notify_registration(&self, kind: &str, registration: &str) {
		self.session
			.send(&self.inbox, "notify", &[kind.into(), "bob".into(), registration.into()])
			.await
			.unwrap();
	}
}
pub struct Peer {
	pub offers: mpsc::Receiver<Offer>,
	pub delay_offer: Rc<Cell<bool>>,
	pub delay_ready: Rc<Cell<bool>>,
	pub ready_answers: mpsc::Receiver<glowcap::Resolver>,
	pub fail_introduction: Rc<Cell<bool>>,
	pub pending_introduction: Rc<Cell<bool>>,
	pub introductions: Rc<Cell<usize>>,
	pub direct_calls: mpsc::Receiver<DirectCall>,
	server: Rc<tcp::Server>,
	stop: oneshot::Sender<()>,
	task: JoinHandle<()>,
}
pub enum DirectCall {
	Requested,
	Message {
		text: String,
		reply: Option<Ref>,
		session: Session,
	},
	Ready {
		reply: Ref,
		session: Session,
	},
}
pub struct Offer {
	pub inbox: Ref,
	pub session: Session,
	pub answer: Option<glowcap::Resolver>,
}
impl Offer {
	pub async fn typing(&self) -> Result<Argument, String> {
		self.session
			.send(&self.inbox, "typing", &[true.into()])
			.await
			.map_err(|e| e.to_string())
	}
}
impl Peer {
	pub async fn start(index: usize, tx: mpsc::Sender<Arrival>) -> Self {
		let host = Host::from_seed([120 + index as u8; 32]).unwrap();
		let server = Rc::new(
			tcp::listen(
				"127.0.0.1",
				0,
				tcp::ListenOptions {
					identity: ListenerIdentity::Host(host.clone()),
					..Default::default()
				},
			)
			.await
			.unwrap(),
		);
		let listener = server.clone();
		let (offer, offers) = mpsc::channel(16);
		let delay_offer = Rc::new(Cell::new(false));
		let delay = delay_offer.clone();
		let delay_ready = Rc::new(Cell::new(false));
		let ready_delay = delay_ready.clone();
		let (ready_answer, ready_answers) = mpsc::channel(32);
		let fail_introduction = Rc::new(Cell::new(false));
		let pending_introduction = Rc::new(Cell::new(false));
		let introductions = Rc::new(Cell::new(0));
		let (fail, introduced) = (fail_introduction.clone(), introductions.clone());
		let pending = pending_introduction.clone();
		let (direct_tx, direct_calls) = mpsc::channel(32);
		let (stop, mut stopping) = oneshot::channel();
		let task = tokio::task::spawn_local(async move {
			let mut sessions = Vec::new();
			loop {
				let session = tokio::select! { _=&mut stopping=>break, session=listener.accept()=>Rc::new(session.unwrap().with_gc()) };
				let connection = sessions.len() + 1;
				assert!(connection <= 2, "fixture only expects one reconnect per directory");
				let name = session
					.spawn_owned(move |verb, _| {
						assert_eq!(verb, "voucher");
						Ok(Argument::Bytes(vec![index as u8, 9]))
					})
					.unwrap();
				let (service, arrive) = (session.clone(), tx.clone());
				let (offer, delay) = (offer.clone(), delay.clone());
				let (fail, introduced, requests) = (fail.clone(), introduced.clone(), direct_tx.clone());
				let pending = pending.clone();
				let calls = direct_tx.clone();
				let (ready_delay, ready_answer) = (ready_delay.clone(), ready_answer.clone());
				let direct = session
					.spawn_owned(rooms_glowcap::client::direct::receiver(move |notice, session| {
						use rooms_application::direct::Notice;
						let call = match notice {
							Notice::Message { text, reply, .. } => DirectCall::Message {
								text: text.into(),
								reply,
								session,
							},
							Notice::Ready(reply) => {
								if ready_delay.replace(false) {
									ready_answer.try_send(session.host().defer_turn().unwrap()).unwrap();
								}
								DirectCall::Ready { reply, session }
							}
							_ => return Err("fixture direct verb".into()),
						};
						calls.try_send(call).map_err(|_| "fixture direct queue is full")?;
						Ok(Argument::Void)
					}))
					.unwrap();
				let root = session
					.publish("directory", move |verb, args| match verb {
						"introduce" => {
							assert_eq!(args[0].as_str(), Some("bob"));
							assert_eq!(args[1].as_str(), Some(ID));
							introduced.set(introduced.get() + 1);
							if pending.get() {
								return Err(rooms_application::failure::Failure {
									code: rooms_application::failure::FailureCode::IntroductionPending,
									detail: "the fixture introduction is pending",
								}
								.to_string());
							}
							if fail.get() {
								Err("the normal route is unavailable".into())
							} else {
								Ok(direct.clone().into())
							}
						}
						"requestDirect" => {
							requests
								.try_send(DirectCall::Requested)
								.map_err(|_| "fixture request queue is full")?;
							Ok(Argument::Void)
						}
						"memberRegistration" => Ok(ID.into()),
						"offerInbox" => {
							assert_eq!(args.len(), 3);
							assert_eq!(args[0].as_str(), Some("bob"));
							assert_eq!(args[1].as_str(), Some(ID));
							let Argument::Reference(inbox) = &args[2] else {
								panic!("offered inbox")
							};
							let session = glowcap::current_session().unwrap().unwrap();
							let answer = delay.replace(false).then(|| session.host().defer_turn().unwrap());
							offer
								.try_send(Offer {
									inbox: inbox.clone(),
									session,
									answer,
								})
								.unwrap();
							Ok(Argument::Void)
						}
						"watchPublications" => Ok(Argument::List(vec![
							Argument::List(vec![Argument::List(vec![
								"shared".into(),
								Argument::Void,
								format!("foreign-{index}").into(),
								"foreign".into(),
								"origin.id".into(),
								"authenticated".into(),
								"participant".into(),
							])]),
							Argument::List(vec![]),
							0.into(),
						])),
						"register" => {
							let Argument::Reference(inbox) = &args[2] else {
								panic!("registration callback")
							};
							arrive
								.try_send(Arrival {
									index,
									connection,
									nick: args[0].as_str().unwrap().into(),
									voucher: args.get(3).and_then(|v| v.as_bytes()).map(|v| v.to_vec()),
									session: service.clone(),
									inbox: inbox.clone(),
								})
								.unwrap();
							Ok(name.clone().into())
						}
						_ => Err("unknown directory method".into()),
					})
					.unwrap();
				let serving = {
					let session = session.clone();
					tokio::task::spawn_local(async move { session.serve().await })
				};
				sessions.push((session, root, serving));
			}
			listener.close().await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			for (session, root, serving) in sessions {
				session.close(PendingWork::Cancel).await.unwrap();
				serving.await.unwrap().unwrap();
				drop(root);
			}
		});
		Self {
			server,
			stop,
			task,
			offers,
			delay_offer,
			delay_ready,
			ready_answers,
			fail_introduction,
			pending_introduction,
			introductions,
			direct_calls,
		}
	}
	pub fn locator(&self) -> String {
		glowcap::format_locator_uri(&self.server.locator().unwrap()).unwrap()
	}
	pub async fn close(self) {
		self.stop.send(()).unwrap();
		self.task.await.unwrap();
	}
}
