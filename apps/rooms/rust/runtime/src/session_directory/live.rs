//! Capability and view custody can be held by the runtime while an independent
//! event stream waits. No live-view borrow spans a network await.
use rooms_application::{
	directory::{self, registration},
	session::directory::{Change, DirectoryView},
};
use rooms_glowcap::client::directory::{registration::Registration, watch::Updates, Directory};
use rooms_glowcap::client::{Deadline, Tasks};

pub struct DirectoryState<P: Tasks> {
	directory: Directory<P>,
	nick: String,
	view: DirectoryView,
	voucher: Option<Vec<u8>>,
}
pub struct DirectoryEvents<P: Tasks> {
	updates: Updates<P>,
	registration: Option<Registration<P>>,
	ended: bool,
}
pub struct LiveDirectory<P: Tasks> {
	state: DirectoryState<P>,
	events: DirectoryEvents<P>,
}
pub enum Notice {
	Discovery(directory::Event),
	Registration(registration::Event),
}
pub enum Event {
	Discovery(Change),
	Registration(registration::Event),
}
impl<P: Deadline + Tasks + Clone + 'static> DirectoryState<P> {
	pub fn nick(&self) -> &str {
		&self.nick
	}
	pub fn directory(&self) -> &Directory<P> {
		&self.directory
	}
	pub fn view(&self) -> &DirectoryView {
		&self.view
	}
	/// Transfer reconnect proof to the session owner, outside exported state.
	pub fn take_voucher(&mut self) -> Option<Vec<u8>> {
		self.voucher.take()
	}
	pub fn apply(&mut self, event: directory::Event) -> Change {
		self.view.apply(event)
	}
}
impl<P: Deadline + Tasks + Clone + 'static> LiveDirectory<P> {
	pub(super) fn new(
		directory: Directory<P>,
		nick: String,
		view: DirectoryView,
		updates: Updates<P>,
		registration: Option<Registration<P>>,
		voucher: Option<Vec<u8>>,
	) -> Self {
		Self {
			state: DirectoryState {
				directory,
				nick,
				view,
				voucher,
			},
			events: DirectoryEvents {
				updates,
				registration,
				ended: false,
			},
		}
	}
	pub fn into_parts(self) -> (DirectoryState<P>, DirectoryEvents<P>) {
		(self.state, self.events)
	}
	pub fn nick(&self) -> &str {
		self.state.nick()
	}
	pub fn directory(&self) -> &Directory<P> {
		self.state.directory()
	}
	pub fn view(&self) -> &DirectoryView {
		self.state.view()
	}
	pub fn take_voucher(&mut self) -> Option<Vec<u8>> {
		self.state.take_voucher()
	}
	pub async fn next(&mut self) -> Result<Option<Event>, String> {
		Ok(self.events.next().await?.map(|event| match event {
			Notice::Discovery(event) => Event::Discovery(self.state.apply(event)),
			Notice::Registration(event) => Event::Registration(event),
		}))
	}
}
impl<P: Deadline + Tasks + Clone + 'static> DirectoryEvents<P> {
	/// Receiving registration work does not acknowledge durable direct
	/// acceptance or mint an inbox. That effect belongs to the session owner.
	pub async fn next(&mut self) -> Result<Option<Notice>, String> {
		if self.ended {
			return Ok(None);
		}
		let update = self.updates.next();
		let notice = async {
			match &mut self.registration {
				Some(registration) => registration.next().await,
				None => core::future::pending().await,
			}
		};
		let result = tokio::select! {
			update = update => update.map(|event| event.map(Notice::Discovery)).map_err(|e| e.to_string()),
			notice = notice => notice.map(|event| event.map(Notice::Registration)).map_err(|e| e.to_string()),
		};
		if !matches!(result, Ok(Some(_))) {
			self.ended = true;
		}
		result
	}
}
