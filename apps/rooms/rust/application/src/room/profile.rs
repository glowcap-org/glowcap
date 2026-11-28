//! A member's optional introduction to its room. It describes a live seat.
use alloc::string::String;
use serde::{Deserialize, Deserializer, Serialize};

pub use crate::protocol_data::{PROFILE as TAG, SET_PROFILE};
pub const MAX_ABOUT: usize = 120;
/// One late join receives at most two introduction batches at the room limit.
/// Even maximally quoted descriptions fit the attached event’s 64 Ki UTF-16 field.
pub const MAX_BATCH: usize = 128;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Entry<T> {
	pub name: T,
	pub member_kind: MemberKind,
	pub about: T,
}
impl<T> Entry<T> {
	pub fn map<U>(self, f: &mut impl FnMut(T) -> U) -> Entry<U> {
		Entry {
			name: f(self.name),
			member_kind: self.member_kind,
			about: f(self.about),
		}
	}
}
pub(crate) fn valid_entries<T: AsRef<str>>(entries: &[Entry<T>]) -> bool {
	let mut seen = alloc::collections::BTreeSet::new();
	!entries.is_empty()
		&& entries.len() <= MAX_BATCH
		&& entries.iter().all(|entry| {
			let name = entry.name.as_ref();
			let about = entry.about.as_ref();
			crate::room::inbox::valid_nick(name)
				&& valid_about(about)
				&& (entry.member_kind != MemberKind::Undeclared || !about.is_empty())
				&& seen.insert(crate::room::inbox::nick_key(name))
		})
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MemberKind {
	#[default]
	#[serde(rename = "")]
	Undeclared,
	Person,
	Bot,
	Assisted,
}

impl MemberKind {
	pub fn parse(kind: &str) -> Option<Self> {
		match kind {
			"" => Some(Self::Undeclared),
			"person" => Some(Self::Person),
			"bot" => Some(Self::Bot),
			"assisted" => Some(Self::Assisted),
			_ => None,
		}
	}
	pub const fn as_str(self) -> &'static str {
		match self {
			Self::Undeclared => "",
			Self::Person => "person",
			Self::Bot => "bot",
			Self::Assisted => "assisted",
		}
	}
}

pub fn valid_about(about: &str) -> bool {
	about.encode_utf16().take(MAX_ABOUT + 1).count() <= MAX_ABOUT
		&& !about
			.chars()
			.any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}'))
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MemberProfile {
	pub kind: MemberKind,
	#[serde(deserialize_with = "read_about")]
	about: String,
}

pub(crate) fn read_about<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
	let about = String::deserialize(d)?;
	if valid_about(&about) {
		Ok(about)
	} else {
		Err(serde::de::Error::custom("invalid room profile description"))
	}
}

impl crate::fields::footprint::HeapBytes for MemberProfile {
	fn heap_bytes(&self) -> usize {
		self.about.capacity()
	}
}

impl MemberProfile {
	pub fn parse(kind: &str, about: &str) -> Option<Self> {
		let kind = MemberKind::parse(kind)?;
		valid_about(about).then(|| Self {
			kind,
			about: about.into(),
		})
	}
	pub fn about(&self) -> &str {
		&self.about
	}
	pub fn is_empty(&self) -> bool {
		self.kind == MemberKind::Undeclared && self.about.is_empty()
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn profile_text_is_one_bounded_line_of_unicode() {
		let exact = "🦉".repeat(MAX_ABOUT / 2);
		for kind in ["", "person", "bot", "assisted"] {
			let profile = MemberProfile::parse(kind, &exact).unwrap();
			assert_eq!(
				serde_json::from_str::<MemberProfile>(&serde_json::to_string(&profile).unwrap()).unwrap(),
				profile
			);
		}
		for invalid in [exact + "a", "two\nlines".into(), "a\u{2028}b".into(), "a\u{85}".into()] {
			assert!(MemberProfile::parse("bot", &invalid).is_none());
		}
		assert!(MemberProfile::parse("machine", "").is_none());
		assert!(MemberProfile::parse("", "").unwrap().is_empty());
	}
}

#[cfg(test)]
mod batches {
	use super::*;
	use crate::room::inbox::metadata::{Presence, presence};
	use alloc::{format, vec};

	#[test]
	fn profile_batches_validate_every_row_before_projection() {
		let mut args = vec!["room".into(), "".into(), "profiles".into()];
		for i in 0..MAX_BATCH {
			args.extend([format!("member{i}"), "assisted".into(), "\\\"".repeat(MAX_ABOUT / 2)]);
		}
		let batch = presence(&args).unwrap();
		assert!(matches!(&batch, Presence::Profiles { entries } if entries.len() == MAX_BATCH));
		let encoded = serde_json::to_string(&batch).unwrap();
		assert!(encoded.encode_utf16().count() < 65_536);
		let event: crate::session::event::Presence = serde_json::from_str(&encoded).unwrap();
		assert!(matches!(event, crate::session::event::Presence::Profiles { .. }));
		args.extend(["extra".into(), "bot".into(), "".into()]);
		assert!(presence(&args).is_none());
		args.truncate(args.len() - 3);
		args[3] = "MEMBER1".into();
		assert!(presence(&args).is_none(), "another spelling of the same room member");
		let repeated = encoded.replace("\"name\":\"member0\"", "\"name\":\"MEMBER1\"");
		assert!(serde_json::from_str::<crate::session::event::Presence>(&repeated).is_err());
		args.pop();
		assert!(presence(&args).is_none(), "incomplete triple");
	}
}
