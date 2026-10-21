//! Directory establishment and guarded retirement of an unsuccessful attempt.
use super::*;
use crate::{grants::Access, session::snapshot::Snapshot};

pub struct Reach {
	pub preparation: Option<RoomGesture>,
	directory: Directory,
	standing: bool,
}
impl Checkpoint {
	pub(super) fn prepare_directory(
		&self,
		id: &str,
		locator: &str,
		nick: &str,
		nick_allocation: crate::directory::registration::NicknameAllocation,
		prepare: bool,
	) -> Result<(Directory, Option<RoomGesture>), &'static str> {
		let prior = self.gesture_directory(id).ok();
		let mut directory = if let Some(prior) = prior {
			prior.clone()
		} else {
			Directory {
				id: Id::new(id.into()).ok_or("Invalid directory identity")?,
				locator: Id::new(locator.into()).ok_or("Invalid directory locator")?,
				home: self.0.directories.0.is_empty(),
				reached: Some(false),
				nick: Field::new(nick.into()).ok_or("Invalid nickname")?,
				nick_allocation,
				standing: Nullable::Null,
			}
		};
		directory.nick = Field::new(nick.into()).ok_or("Invalid nickname")?;
		directory.nick_allocation = nick_allocation;
		let preparation = if !prepare {
			None
		} else if let Some(prior) = prior {
			if prior.nick == directory.nick && prior.nick_allocation == directory.nick_allocation {
				None
			} else {
				Some(RoomGesture {
					name: "setDirectoryNick",
					arguments: alloc::vec![id.into(), nick.into(), nick_allocation.wire().into()],
					directory: directory.id.clone(),
					expected: Some(super::expected(prior)),
				})
			}
		} else {
			Some(RoomGesture {
				name: "joinDirectory",
				arguments: alloc::vec![encode(&directory)?],
				directory: directory.id.clone(),
				expected: None,
			})
		};
		Ok((directory, preparation))
	}
	pub fn reach_directory_with_allocation(
		&self,
		id: &str,
		locator: &str,
		nick: &str,
		nick_allocation: crate::directory::registration::NicknameAllocation,
	) -> Result<Reach, &'static str> {
		let standing = self
			.gesture_directory(id)
			.is_ok_and(|prior| prior.home || prior.reached == Some(true));
		let (directory, preparation) = self.prepare_directory(id, locator, nick, nick_allocation, true)?;
		Ok(Reach {
			preparation,
			directory,
			standing,
		})
	}
}
impl Reach {
	pub fn retained_bytes(&self) -> usize {
		use crate::fields::footprint::HeapBytes;
		core::mem::size_of::<Self>()
			+ self.directory.heap_bytes()
			+ self.preparation.as_ref().map_or(0, RoomGesture::retained_bytes)
	}
	pub fn id(&self) -> &str {
		#[expect(
			clippy::expect_used,
			reason = "`new` read the directory `id` as scalar text when it admitted this gesture"
		)]
		self.directory.id.text().as_str().expect("admitted scalar directory")
	}
	pub fn outcome(&self, snapshot: &Snapshot) -> Option<Result<(), String>> {
		if !matches!(snapshot.access, Access::Admin | Access::Interact) {
			return Some(Err("This session no longer permits directory connections".into()));
		}
		let current = match snapshot.checkpoint.gesture_directory(self.id()) {
			Ok(current) => current,
			Err(_) => return Some(Err("The directory was removed while connecting".into())),
		};
		if current.locator != self.directory.locator || current.nick != self.directory.nick {
			return Some(Err("The directory or nickname changed while connecting".into()));
		}
		if snapshot
			.connected_directories
			.as_slice()
			.iter()
			.any(|id| id.text() == self.directory.id.text())
		{
			return Some(Ok(()));
		}
		let subject = alloc::format!("directory:{}", self.id());
		snapshot
			.issues
			.as_slice()
			.iter()
			.find(|(key, _)| {
				key.text()
					.as_str()
					.is_some_and(|key| key == "session" || key == "session-access" || key == subject)
			})
			.map(|(_, reason)| {
				Err(reason
					.text()
					.as_str()
					.unwrap_or("The directory could not be reached")
					.into())
			})
	}
	pub fn temporary(&self) -> bool {
		!self.standing
	}
}
