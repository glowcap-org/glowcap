//! Room gestures become command material from the authoritative checkpoint.
//! The directory identity captured here is checked again before every retry.
use super::{Checkpoint, fields::*, model::*};
use crate::room::policy::RoomPolicy;
use alloc::{
	string::{String, ToString},
	vec::Vec,
};
use serde::Serialize;
mod direct;
mod directory;
mod sharing;
pub use direct::{DirectGesture, Invalid as DirectInvalid};
pub use directory::Reach;
pub use sharing::ShareRoom;

pub struct RoomGesture {
	name: &'static str,
	arguments: Vec<String>,
	directory: Id,
	expected: Option<(Id, Field, crate::directory::registration::NicknameAllocation)>,
}
fn expected(directory: &Directory) -> (Id, Field, crate::directory::registration::NicknameAllocation) {
	(
		directory.locator.clone(),
		directory.nick.clone(),
		directory.nick_allocation,
	)
}
impl RoomGesture {
	pub fn retained_bytes(&self) -> usize {
		use crate::fields::footprint::HeapBytes;
		core::mem::size_of::<Self>()
			+ self.directory.heap_bytes()
			+ self.arguments.capacity() * core::mem::size_of::<String>()
			+ self.arguments.iter().map(String::capacity).sum::<usize>()
			+ self
				.expected
				.as_ref()
				.map_or(0, |(locator, nick, _)| locator.heap_bytes() + nick.heap_bytes())
	}
	pub fn name(&self) -> &'static str {
		self.name
	}
	pub fn arguments(&self) -> &[String] {
		&self.arguments
	}
	pub fn check(&self, checkpoint: &Checkpoint) -> Result<(), &'static str> {
		let actual = checkpoint
			.0
			.directories
			.0
			.iter()
			.find(|directory| directory.id == self.directory);
		let stable = match (actual, &self.expected) {
			(None, None) => true,
			(Some(actual), Some(expected)) => {
				actual.locator == expected.0 && actual.nick == expected.1 && actual.nick_allocation == expected.2
			}
			_ => false,
		};
		if stable {
			Ok(())
		} else {
			Err("The room's directory or nickname changed; repeat the action from the current view")
		}
	}
}
pub struct Destination<'a> {
	pub directory: &'a str,
	pub locator: &'a str,
	pub name: &'a str,
	pub nick: &'a str,
	pub nick_allocation: crate::directory::registration::NicknameAllocation,
	pub link: Option<&'a str>,
	pub policy: RoomPolicy,
}
pub struct JoinPlan {
	pub readiness: Option<Reach>,
	pub preparation: Option<RoomGesture>,
	pub admission: RoomGesture,
}
fn encode(value: &impl Serialize) -> Result<String, &'static str> {
	serde_json::to_string(value).map_err(|_| "Could not encode the Rooms gesture")
}
impl Checkpoint {
	fn gesture_directory(&self, id: &str) -> Result<&Directory, &'static str> {
		self.0
			.directories
			.0
			.iter()
			.find(|directory| directory.id.text().as_str() == Some(id))
			.ok_or("The room's directory is no longer in this session")
	}
}

pub fn private_name_available(
	snapshot: &crate::session::snapshot::Snapshot,
	directory: &str,
	name: &str,
) -> Result<(), Invalid> {
	let folded = crate::text::DocumentText::from(name).lowercase();
	if snapshot
		.directory_views
		.as_slice()
		.iter()
		.filter(|view| view.directory_id.text().as_str() == Some(directory))
		.flat_map(|view| view.rooms.as_slice())
		.any(|room| room.name.text().lowercase() == folded)
	{
		return Err(Invalid::NameLive { name: name.into() });
	}
	Ok(())
}

/// Why a private room cannot be opened under a name. `Display` is the exact
/// line the member reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Invalid {
	/// A room with this name is already live in the directory.
	NameLive { name: String },
}

impl core::fmt::Display for Invalid {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::NameLive { name } => write!(
				f,
				"#{name} is already live here. Turn off Private to open it, or choose another name for a new private room."
			),
		}
	}
}

impl core::error::Error for Invalid {}

impl From<Invalid> for String {
	fn from(invalid: Invalid) -> Self {
		invalid.to_string()
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn every_invalid_line_is_the_line_it_replaced() {
		assert_eq!(
			Invalid::NameLive { name: "x".into() }.to_string(),
			"#x is already live here. Turn off Private to open it, or choose another name for a new private room."
		);
	}
}
