//! One held directory capability over a shared client connection. Transport
//! acquisition belongs to the Runtime that supplied that connection.
use super::*;
use crate::Value;
use rooms_application::{
	directory::{
		self,
		creation::{self, RecoveryKey},
	},
	room::policy::RoomPolicy,
};
pub mod entry;
pub mod introduction;
pub mod registration;
pub mod signaling;
pub mod watch;

#[derive(Clone)]
pub struct Directory<D> {
	client: Client<D>,
	reference: Ref,
	introductions: introduction::Notifications,
	signaling: signaling::Registry,
}
pub struct ManagedRoom {
	pub room: Ref,
	pub room_link: String,
	pub manager_link: String,
}
impl<D: Deadline> Directory<D> {
	pub fn new(client: Client<D>, reference: Ref) -> Self {
		Self {
			client,
			reference,
			introductions: Default::default(),
			signaling: Default::default(),
		}
	}
	pub async fn fetch(client: Client<D>) -> Result<Self, Error> {
		let reference = client
			.deadline
			.within(authority::REQUEST_TIMEOUT_MS, client.session.fetch(directory::NAME))
			.await
			.ok_or(Error::Timeout("the peer did not answer fetching its directory"))??;
		Ok(Self::new(client, reference))
	}
	pub fn reference(&self) -> &Ref {
		&self.reference
	}
	pub fn client(&self) -> &Client<D> {
		&self.client
	}
	async fn capability(&self, verb: &'static str, name: &str) -> Result<Ref, Error> {
		let answer = self
			.client
			.ask(
				&self.reference,
				verb,
				&[name],
				"the directory did not answer the room request",
			)
			.await?;
		match answer.0 {
			Argument::Reference(room) => Ok(room),
			_ => Err(directory::Error::Capability.into()),
		}
	}
	pub async fn open(&self, name: &str) -> Result<Ref, Error> {
		self.capability(creation::OPEN, name).await
	}
	pub async fn enter(&self, name: &str) -> Result<Ref, Error> {
		self.capability(creation::ENTER, name).await
	}
	pub async fn enter_publication(&self, id: &str) -> Result<Ref, Error> {
		self.capability(creation::ENTER_PUBLICATION, id).await
	}
	pub async fn open_private(&self, label: &str, key: &RecoveryKey) -> Result<Ref, Error> {
		let pending = {
			let args = [
				Argument::String(label.into()),
				true.into(),
				Argument::String(key.as_str().into()),
			];
			self.client.call(
				&self.reference,
				creation::OPEN,
				&args,
				"the directory did not answer private room creation",
			)
		};
		match pending.await?.0 {
			Argument::Reference(room) => Ok(room),
			_ => Err(directory::Error::Capability.into()),
		}
	}
	pub async fn private_link(&self, key: &RecoveryKey) -> Result<String, Error> {
		let reply = self
			.client
			.ask(
				&self.reference,
				creation::PRIVATE_LINK,
				&[key.as_str()],
				"the directory did not answer private room creation",
			)
			.await?;
		link(reply.0)
	}
	pub async fn link(&self, name: &str) -> Result<String, Error> {
		let reply = self
			.client
			.ask(
				&self.reference,
				creation::LINK,
				&[name],
				"the directory did not answer linking a room",
			)
			.await?;
		link(reply.0)
	}
	pub async fn advertised_location(&self) -> Result<String, Error> {
		let reply = self
			.client
			.call(
				&self.reference,
				creation::LOCATION,
				&[],
				"the directory did not answer its advertised location",
			)
			.await?;
		match reply.0 {
			Argument::String(location) if !location.is_empty() => Ok(location),
			_ => Err(directory::Error::Location.into()),
		}
	}
	pub async fn list(&self) -> Result<Vec<directory::RoomInfo>, Error> {
		let reply = self
			.client
			.call(
				&self.reference,
				directory::LIST,
				&[],
				"the directory did not answer its room list",
			)
			.await?;
		Ok(directory::rooms(&Value(&reply.0))?)
	}
	/// The caller retains its recovery key until the durable effect is settled.
	/// Both temporary capabilities stay owned across the bootstrap observation.
	pub async fn open_managed(&self, name: &str, policy: RoomPolicy, key: &RecoveryKey) -> Result<ManagedRoom, Error> {
		let [visibility, entry, speaking] = policy.modes();
		let reply = self
			.client
			.ask(
				&self.reference,
				creation::OPEN_MANAGED,
				&[name, visibility, entry, speaking, key.as_str()],
				"the directory did not answer managed room creation",
			)
			.await?;
		let Argument::List(pair) = &reply.0 else {
			return Err(directory::Error::Bootstrap.into());
		};
		let values = crate::values(pair).collect::<Vec<_>>();
		let creation::Bootstrap { room, bootstrap } = creation::read_bootstrap(&values)?;
		let reply = self
			.client
			.call(
				&bootstrap,
				creation::AUTHORITIES,
				&[],
				"the room bootstrap did not answer its authorities",
			)
			.await?;
		let value = Value(&reply.0);
		let [room_link, manager_link] = creation::authorities(&value)?;
		let room_link = link(room_link.into())?;
		let manager_link = link(manager_link.into())?;
		Ok(ManagedRoom {
			room,
			room_link,
			manager_link,
		})
	}
}
fn link(reply: Argument) -> Result<String, Error> {
	let Argument::String(link) = reply else {
		return Err(directory::Error::Link.into());
	};
	let parsed = glowcap::parse_sturdyref(&link, glowcap::CaptpVersion::V1_0)?;
	if parsed.swissnum.is_empty() {
		return Err(directory::Error::Link.into());
	}
	Ok(link)
}
