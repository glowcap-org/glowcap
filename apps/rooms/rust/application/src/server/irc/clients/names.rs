//! IRC nick leases preserve RFC casemapping and one holder per name.
use super::{
	super::{
		protocol::fold,
		registration::{Invalid as RegistrationInvalid, projected_nick, validate_nick},
	},
	PROJECTED_NAMES,
};
use alloc::{
	collections::BTreeMap,
	format,
	string::{String, ToString},
};

pub fn room_name(channel: &str) -> Result<&str, Invalid> {
	let name = channel
		.strip_prefix('#')
		.filter(|n| !n.is_empty())
		.ok_or(Invalid::ChannelName)?;
	if channel
		.chars()
		.any(|c| matches!(c, '\0' | '\r' | '\n' | ' ' | ',' | ':'))
	{
		return Err(Invalid::ChannelName);
	}
	if name.encode_utf16().count() > crate::server::document::MAX_ROOM {
		return Err(Invalid::NameLength);
	}
	Ok(name)
}
pub fn channel(name: &str) -> Option<String> {
	let channel = format!("#{name}");
	room_name(&channel).ok()?;
	Some(channel)
}
#[derive(Default)]
pub struct Names {
	projected: BTreeMap<String, String>,
	original: BTreeMap<String, String>,
}
impl Names {
	/// Reserve the connection's own spelling before any foreign roster arrives.
	pub fn new(nick: &str) -> Result<Self, Invalid> {
		validate_nick(nick)?;
		let mut names = Self::default();
		names.project(nick)?;
		Ok(names)
	}
	pub fn original<'a>(&'a self, wire: &'a str) -> &'a str {
		self.original.get(&fold(wire)).map(String::as_str).unwrap_or(wire)
	}
	pub fn project(&mut self, name: &str) -> Result<String, Invalid> {
		let key = name.to_lowercase();
		if let Some(held) = self.projected.get(&key) {
			return Ok(held.clone());
		}
		if self.projected.len() == PROJECTED_NAMES {
			return Err(Invalid::TableFull);
		}
		let mut projected = name.to_string();
		if validate_nick(name).is_err() || self.original.contains_key(&fold(name)) {
			let base = projected_nick(name);
			projected = base.clone();
			let mut suffix = 0;
			while self.original.contains_key(&fold(&projected)) {
				suffix += 1;
				projected = format!("{base}-{suffix}");
			}
		}
		self.original.insert(fold(&projected), name.into());
		self.projected.insert(key, projected.clone());
		Ok(projected)
	}
}

/// Why a channel or nick is refused. `Display` is the exact line the
/// connection reports.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Invalid {
	/// The channel is not `#` followed by one name.
	ChannelName,
	/// The Rooms name is over the character limit.
	NameLength,
	/// The projected nickname table is full.
	TableFull,
	/// The connection's own nick was refused.
	Nick(RegistrationInvalid),
}

impl core::fmt::Display for Invalid {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::ChannelName => f.write_str("a Rooms IRC channel must be # followed by one name"),
			Self::NameLength => f.write_str("the Rooms name exceeds its character limit"),
			Self::TableFull => f.write_str("IRC projected nickname table is full"),
			Self::Nick(source) => write!(f, "{source}"),
		}
	}
}

impl core::error::Error for Invalid {}

impl From<Invalid> for String {
	fn from(invalid: Invalid) -> Self {
		invalid.to_string()
	}
}

impl From<RegistrationInvalid> for Invalid {
	fn from(source: RegistrationInvalid) -> Self {
		Self::Nick(source)
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn every_invalid_line_is_the_line_it_replaced() {
		let lines = [
			(
				Invalid::ChannelName,
				"a Rooms IRC channel must be # followed by one name",
			),
			(Invalid::NameLength, "the Rooms name exceeds its character limit"),
			(Invalid::TableFull, "IRC projected nickname table is full"),
			(
				Invalid::Nick(RegistrationInvalid::NickCharacters),
				"IRC nickname must be 1..28 ASCII nickname characters and begin with a letter or special",
			),
		];
		for (invalid, line) in lines {
			assert_eq!(invalid.to_string(), line);
		}
	}
}
