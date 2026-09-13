//! A link lookup provisionally owns its connection until checkpoint admission.
//! The directory worker takes successful custody; failed lookups relinquish
//! only their own handle, preserving other owners of the same connection.
use super::*;
use rooms_application::session::checkpoint::{
	DirectoryIntent,
	reconciliation::{Field, Id},
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
	) -> Result<Entry<P>, Error> {
		if self.is_closed() {
			return Err(Error::closed("directory runtime is closed"));
		}
		let id = Id::new(id.clone()).ok_or_else(|| Error::invalid("invalid directory identity"))?;
		let locator = Id::new(locator.clone()).ok_or_else(|| Error::invalid("invalid directory locator"))?;
		let nick = Field::new(nick.clone()).ok_or_else(|| Error::invalid("invalid directory nickname"))?;
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
				.ok_or_else(|| Error::invalid("invalid directory locator"))?;
			let connection = self.connections.connect(&route).await?;
			let client = connection.client;
			match Directory::fetch(client.clone()).await {
				Ok(directory) => (directory, client),
				Err(error) => {
					let cleanup = client.relinquish().await.map_err(Error::from);
					return Err(Error::peer(error).retain_result(cleanup));
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
	pub fn stage(&mut self) -> Result<(), Error> {
		if !self.current() {
			return Err(Error::stale(
				"the room directory connection changed during link resolution",
			));
		}
		if self.connected {
			return Ok(());
		}
		let mut state = self.owner.shared.borrow_mut();
		if state.staged.is_some() {
			return Err(Error::busy("another directory admission is still completing"));
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
	pub async fn finish(self, committed: bool) -> Result<(), Error> {
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
		Ok(client.relinquish().await?)
	}
}
