//! A link lookup provisionally owns its connection until checkpoint admission.
//! The directory worker takes successful custody; failed lookups relinquish
//! only their own handle, preserving other owners of the same connection.
use super::*;
use rooms_application::session::checkpoint::{
	reconciliation::{Field, Id},
	DirectoryIntent,
};
use rooms_glowcap::client::Client;

pub(super) struct Staged<P: Platform> {
	pub directory: Directory<P>,
	id: Id,
	locator: Id,
	nick: Field,
}
impl<P: Platform> Staged<P> {
	pub fn matches(&self, intent: DirectoryIntent<'_>) -> bool {
		&self.id == intent.id && &self.locator == intent.locator && &self.nick == intent.nick
	}
}

pub(crate) struct Entry<P: Platform> {
	owner: DirectoryRuntime<P>,
	pub directory: Directory<P>,
	client: Client<P>,
	id: Id,
	locator: Id,
	nick: Field,
	staged: Option<Rc<Staged<P>>>,
	connected: bool,
}
impl<P: Platform> DirectoryRuntime<P> {
	pub(crate) async fn entry(
		&self,
		id: &DocumentText,
		locator: &DocumentText,
		nick: &DocumentText,
	) -> Result<Entry<P>, String> {
		if self.is_closed() {
			return Err("directory runtime is closed".into());
		}
		let id = Id::new(id.clone()).ok_or("invalid directory identity")?;
		let locator = Id::new(locator.clone()).ok_or("invalid directory locator")?;
		let nick = Field::new(nick.clone()).ok_or("invalid directory nickname")?;
		let held = self.connected(&id);
		let connected = held.is_some();
		let (directory, client) = if let Some((directory, _)) = held {
			let client = directory.client().clone();
			(directory, client)
		} else {
			let route = locator
				.text()
				.as_str()
				.and_then(rooms_glowcap::routes::locator)
				.ok_or("invalid directory locator")?;
			let connection = self
				.connections
				.connect(&route)
				.await
				.map_err(|e| format!("could not reach the room directory: {e}"))?;
			let client = connection.client;
			match Directory::fetch(client.clone()).await {
				Ok(directory) => (directory, client),
				Err(error) => {
					let cleanup = client.relinquish().await.map_err(|e| e.to_string());
					return Err(crate::cleanup::combine(Err(error.to_string()), cleanup).unwrap_err());
				}
			}
		};
		Ok(Entry {
			owner: self.clone(),
			directory,
			client,
			id,
			locator,
			nick,
			staged: None,
			connected,
		})
	}
}

impl<P: Platform> Entry<P> {
	pub fn current(&self) -> bool {
		!self.owner.is_closed()
			&& self.client.session().is_open()
			&& (!self.connected
				|| self
					.owner
					.has_connection(self.id.text().as_str().unwrap_or(""), self.client.session()))
	}
	pub fn stage(&mut self) -> Result<(), String> {
		if !self.current() {
			return Err("the room directory connection changed during link resolution".into());
		}
		if self.connected {
			return Ok(());
		}
		let mut state = self.owner.shared.borrow_mut();
		if state.staged.is_some() {
			return Err("another directory admission is still completing".into());
		}
		let staged = Rc::new(Staged {
			directory: self.directory.clone(),
			id: self.id.clone(),
			locator: self.locator.clone(),
			nick: self.nick.clone(),
		});
		state.staged = Some(staged.clone());
		self.staged = Some(staged);
		Ok(())
	}
	pub async fn finish(self, committed: bool) -> Result<(), String> {
		if !committed {
			let mut state = self.owner.shared.borrow_mut();
			if self
				.staged
				.as_ref()
				.is_some_and(|held| state.staged.as_ref().is_some_and(|s| Rc::ptr_eq(s, held)))
			{
				state.staged = None;
			}
		}
		let Self {
			client,
			directory,
			staged,
			..
		} = self;
		drop(directory);
		drop(staged);
		client.relinquish().await.map_err(|e| e.to_string())
	}
}
