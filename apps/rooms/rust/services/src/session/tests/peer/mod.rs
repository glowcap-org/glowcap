use glowcap::{Argument, PendingWork, tcp};
use std::{cell::Cell, cell::RefCell, rc::Rc};
mod directory;
mod managed;
mod ops;
pub const REGISTRATION: &str = "11111111-1111-4111-8111-111111111111";
pub struct DirectoryPeer {
	pub locator: String,
	heard: Rc<RefCell<Vec<String>>>,
	published: Rc<RefCell<Vec<String>>>,
	reciprocal: Rc<RefCell<Option<(glowcap::Session, glowcap::Ref)>>>,
	allow_managed: Rc<Cell<bool>>,
	kicked: Rc<RefCell<Vec<String>>>,
	room_inbox: directory::RoomInbox,
	/// How many times the room has been subscribed to, so a test can tell one
	/// membership from a session that keeps leaving and rejoining.
	room_subscriptions: Rc<Cell<u32>>,
	bridge_calls: Rc<RefCell<Vec<(String, String)>>>,
	stop: tokio::sync::oneshot::Sender<()>,
	task: tokio::task::JoinHandle<()>,
}
impl DirectoryPeer {
	pub async fn start() -> Self {
		let heard = Rc::new(RefCell::new(Vec::<String>::new()));
		let published = Rc::new(RefCell::new(Vec::<String>::new()));
		let reciprocal = Rc::new(RefCell::new(None));
		let allow_managed = Rc::new(Cell::new(true));
		let room_inbox: directory::RoomInbox = Rc::new(RefCell::new(None));
		let room_subscriptions = Rc::new(Cell::new(0u32));
		let bridge_calls = Rc::new(RefCell::new(Vec::new()));
		let host = glowcap::Host::from_seed([121; 32]).unwrap();
		let server = std::rc::Rc::new(
			tcp::listen(
				"127.0.0.1",
				0,
				tcp::ListenOptions {
					identity: glowcap::ListenerIdentity::Host(host.clone()),
					..Default::default()
				},
			)
			.await
			.unwrap(),
		);
		let locator = glowcap::format_locator_uri(&server.locator().unwrap()).unwrap();
		let host_locator = server.locator().unwrap();
		let swiss = host
			.publish_durable_with_entropy([7; 16], || Box::new(|_, _| Ok(Argument::Void)))
			.unwrap();
		let garden_link =
			glowcap::format_sturdyref(&host_locator, swiss.as_bytes(), glowcap::CaptpVersion::V1_0).unwrap();
		let managed = managed::publish(&host, &host_locator, published.clone());
		let kicked = managed.kicked.clone();
		let listener = server.clone();
		let received = heard.clone();
		let published_names = published.clone();
		let reply_line = reciprocal.clone();
		let allow = allow_managed.clone();
		let room_subscriber = room_inbox.clone();
		let subscriptions = room_subscriptions.clone();
		let bridge_log = bridge_calls.clone();
		let (stop, mut stopping) = tokio::sync::oneshot::channel();
		let task = tokio::task::spawn_local(async move {
			let mut sessions = Vec::new();
			loop {
				let session = tokio::select! {
					_ = &mut stopping => break,
					session = listener.accept() => std::rc::Rc::new(session.unwrap().with_gc()),
				};
				let (root, extras) = directory::publish(
					session.as_ref(),
					&garden_link,
					received.clone(),
					published_names.clone(),
					reply_line.clone(),
					allow.clone(),
					managed.clone(),
					room_subscriber.clone(),
					subscriptions.clone(),
					bridge_log.clone(),
				);
				let ops = ops::publish(session.as_ref(), published_names.clone());
				let serving = {
					let session = session.clone();
					tokio::task::spawn_local(async move { session.serve().await })
				};
				sessions.push((session, root, extras, ops, serving));
			}
			listener.close().await.unwrap();
			host.close(PendingWork::Cancel).await.unwrap();
			for (session, root, extras, ops, serving) in sessions {
				session.close(PendingWork::Cancel).await.unwrap();
				serving.await.unwrap().unwrap();
				drop((root, extras, ops));
			}
		});
		Self {
			locator,
			heard,
			published,
			reciprocal,
			allow_managed,
			kicked,
			room_inbox,
			room_subscriptions,
			bridge_calls,
			stop,
			task,
		}
	}
	pub fn room_subscriptions(&self) -> u32 {
		self.room_subscriptions.get()
	}
	pub fn bridge_calls(&self) -> Vec<(String, String)> {
		self.bridge_calls.borrow().clone()
	}
	/// Speak for the room to its latest subscriber.
	fn notify_room(&self, args: &[Argument]) {
		let held = self.room_inbox.borrow();
		let (session, inbox) = held.as_ref().expect("a member subscribed to the room");
		session
			.tell(inbox, rooms_application::room::inbox::NOTIFY, args)
			.unwrap();
	}
	pub fn end_room_membership(&self, reason: &str) {
		self.notify_room(&[
			"room".into(),
			reason.into(),
			rooms_application::room::inbox::ENDED.into(),
		]);
	}
	pub fn change_room_policy(&self, policy: rooms_application::room::policy::RoomPolicy) {
		let [visibility, entry, speaking] = policy.modes();
		self.notify_room(&[
			"room".into(),
			"".into(),
			rooms_application::room::inbox::POLICY_CHANGED.into(),
			visibility.into(),
			entry.into(),
			speaking.into(),
		]);
	}
	pub fn received(&self) -> Vec<String> {
		self.heard.borrow().clone()
	}
	pub fn published(&self) -> Vec<String> {
		self.published.borrow().clone()
	}
	pub fn reciprocal(&self) -> Option<(glowcap::Session, glowcap::Ref)> {
		self.reciprocal
			.borrow()
			.as_ref()
			.map(|(session, reply)| (session.borrowed(), reply.clone()))
	}
	pub fn allow_managed(&self, allow: bool) {
		self.allow_managed.set(allow);
	}
	pub fn kicked(&self) -> Vec<String> {
		self.kicked.borrow().clone()
	}
	pub async fn close(self) {
		self.stop.send(()).unwrap();
		self.task.await.unwrap();
	}
}
