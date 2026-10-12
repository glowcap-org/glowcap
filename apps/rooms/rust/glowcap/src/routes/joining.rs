//! Resolve submitted Rooms destinations through the existing locator parser.
use super::Address;
use rooms_application::{room::policy::RoomPolicy, session::checkpoint::Checkpoint};
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
	room: String,
	locator: String,
	#[serde(default)]
	hidden: bool,
	policy: Option<RoomPolicy>,
}
pub struct Destination {
	pub directory: String,
	pub locator: String,
	pub name: String,
	pub link: Option<String>,
	pub policy: RoomPolicy,
}
impl Request {
	pub fn resolve(self, checkpoint: &Checkpoint, default: &str) -> Result<Destination, String> {
		let locator = self.locator.trim();
		let room = self.room.trim();
		let linked = if locator.contains("/s/") {
			Some((locator, self.room.as_str()))
		} else if room.contains("/s/") {
			Some((room, ""))
		} else {
			None
		};
		if let Some((link, label)) = linked {
			let address = Address::capability(link)
				.map_err(|e| e.to_string())?
				.ok_or("that is not a room entry link")?;
			return Ok(Destination {
				directory: address.authority,
				locator: address.address,
				name: if label.is_empty() {
					"a room".into()
				} else {
					label.into()
				},
				link: Some(link.into()),
				policy: RoomPolicy::Private,
			});
		}
		let locator = if locator.is_empty() {
			checkpoint
				.directories()
				.find(|directory| directory.home)
				.and_then(|directory| directory.locator.text().as_str())
				.unwrap_or(default)
		} else {
			locator
		};
		if locator.is_empty() {
			return Err("Name the directory to join".into());
		}
		let address = Address::directory(locator)
			.map_err(|e| e.to_string())?
			.ok_or("The directory address is invalid")?;
		Ok(Destination {
			directory: address.authority,
			locator: locator.into(),
			name: self.room,
			link: None,
			policy: self.policy.unwrap_or(if self.hidden {
				RoomPolicy::Private
			} else {
				RoomPolicy::Open
			}),
		})
	}
}

impl Destination {
	pub fn check(&self, snapshot: &rooms_application::session::snapshot::Snapshot) -> Result<(), String> {
		if self.policy != RoomPolicy::Private || self.link.is_some() {
			return Ok(());
		}
		rooms_application::session::checkpoint::gestures::private_name_available(snapshot, &self.directory, &self.name)
			.map_err(String::from)
	}
}
