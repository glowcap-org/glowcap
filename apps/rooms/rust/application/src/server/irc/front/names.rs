use super::{
	super::{
		protocol::fold,
		registration::{projected_nick, validate_nick},
	},
	PROJECTED_NAMES,
};
use alloc::{
	collections::BTreeMap,
	format,
	string::{String, ToString},
};

pub fn room_name(channel: &str) -> Result<&str, String> {
	let name = channel
		.strip_prefix('#')
		.filter(|n| !n.is_empty())
		.ok_or("a Rooms IRC channel must be # followed by one name")?;
	if channel
		.chars()
		.any(|c| matches!(c, '\0' | '\r' | '\n' | ' ' | ',' | ':'))
	{
		return Err("a Rooms IRC channel must be # followed by one name".into());
	}
	if name.encode_utf16().count() > crate::server::document::MAX_ROOM {
		return Err("the Rooms name exceeds its character limit".into());
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
	pub fn new(nick: &str) -> Result<Self, String> {
		validate_nick(nick)?;
		let mut names = Self::default();
		names.project(nick)?;
		Ok(names)
	}
	pub fn original<'a>(&'a self, wire: &'a str) -> &'a str {
		self.original.get(&fold(wire)).map(String::as_str).unwrap_or(wire)
	}
	pub fn project(&mut self, name: &str) -> Result<String, String> {
		let key = name.to_lowercase();
		if let Some(held) = self.projected.get(&key) {
			return Ok(held.clone());
		}
		if self.projected.len() == PROJECTED_NAMES {
			return Err("IRC projected nickname table is full".into());
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
