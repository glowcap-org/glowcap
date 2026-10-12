//! Operator response admission and attached-session JSON. Raw capability
//! arguments stay with the binding. This layer owns bounded inventory data.
mod footprint;
pub mod inventory;
pub mod rows;
pub(crate) mod wire;
use super::Category;
use crate::fields::{Nullable, Object, SafeInteger, Text};
use alloc::string::{String, ToString};
use rows::*;
use serde::{Deserialize, Serialize};
pub use wire::{read_page, read_retire, read_snapshot, read_stewardship};

pub const MAX_JSON_UNITS: usize = 512 * 1024;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
	Shape,
	Text,
	Number,
	Kind,
	Relation,
	Budget,
	Json,
}
impl core::fmt::Display for Refusal {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		write!(f, "invalid Rooms operator answer: {self:?}")
	}
}
impl core::error::Error for Refusal {}

/// The wire revision is an integer, the JSON revision a decimal string. This
/// keeps all admitted digits instead of rounding through a JavaScript number.
#[derive(Clone, Debug, Serialize)]
#[serde(transparent)]
pub struct Revision(#[serde(serialize_with = "decimal")] u128);
fn decimal<S: serde::Serializer>(value: &u128, s: S) -> Result<S::Ok, S::Error> {
	s.collect_str(value)
}
impl Revision {
	pub fn get(&self) -> u128 {
		self.0
	}
	pub(super) fn new(value: u128) -> Result<Self, Refusal> {
		if value.to_string().len() > 32 {
			return Err(Refusal::Number);
		}
		Ok(Self(value))
	}
}
impl<'de> Deserialize<'de> for Revision {
	fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		let text = Text::<32, true>::deserialize(d)?;
		// At most 32 decimal digits always fits a u128, which holds 39.
		text.text()
			.as_str()
			.filter(|s| s.bytes().all(|b| b.is_ascii_digit()))
			.and_then(|s| s.parse().ok())
			.map(Self)
			.ok_or_else(|| serde::de::Error::custom("operator revision"))
	}
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Categories<T> {
	pub stewardships: T,
	pub links: T,
	pub registrations: T,
	pub sessions: T,
	pub rooms: T,
	pub references: T,
	pub trouble: T,
}
impl<T> Categories<T> {
	pub fn get(&self, category: Category) -> &T {
		match category {
			Category::Stewardships => &self.stewardships,
			Category::Links => &self.links,
			Category::Registrations => &self.registrations,
			Category::Sessions => &self.sessions,
			Category::Rooms => &self.rooms,
			Category::References => &self.references,
			Category::Trouble => &self.trouble,
		}
	}
	pub(super) fn get_mut(&mut self, category: Category) -> &mut T {
		match category {
			Category::Stewardships => &mut self.stewardships,
			Category::Links => &mut self.links,
			Category::Registrations => &mut self.registrations,
			Category::Sessions => &mut self.sessions,
			Category::Rooms => &mut self.rooms,
			Category::References => &mut self.references,
			Category::Trouble => &mut self.trouble,
		}
	}
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
	pub revision: Revision,
	pub stewardships: Rows<Stewardship>,
	pub links: Rows<Link>,
	pub registrations: Rows<Registration>,
	pub sessions: Rows<Session>,
	pub rooms: Rows<Room>,
	pub references: Rows<Reference>,
	pub trouble: Rows<Trouble>,
	pub next: Object<Categories<Nullable<SafeInteger>>>,
	pub totals: Object<Categories<SafeInteger>>,
}
impl Snapshot {
	pub fn decode(raw: &str) -> Result<Self, Refusal> {
		if raw.encode_utf16().take(MAX_JSON_UNITS + 1).count() > MAX_JSON_UNITS {
			return Err(Refusal::Budget);
		}
		let value: Self = crate::fields::json_object(raw).map_err(|_| Refusal::Json)?;
		value.validate()?;
		Ok(value)
	}
	pub fn encode(&self) -> Result<String, Refusal> {
		self.validate()?;
		let text = serde_json::to_string(self).map_err(|_| Refusal::Json)?;
		if text.encode_utf16().take(MAX_JSON_UNITS + 1).count() > MAX_JSON_UNITS {
			return Err(Refusal::Budget);
		}
		Ok(text)
	}
	fn validate(&self) -> Result<(), Refusal> {
		for row in self.stewardships.as_slice() {
			row.validate()?;
		}
		Ok(())
	}
}
#[derive(Clone, Debug)]
pub enum PageRows {
	Stewardships(Rows<Stewardship>),
	Links(Rows<Link>),
	Registrations(Rows<Registration>),
	Sessions(Rows<Session>),
	Rooms(Rows<Room>),
	References(Rows<Reference>),
	Trouble(Rows<Trouble>),
}
#[derive(Clone, Debug)]
pub struct Page {
	pub revision: Revision,
	pub next: Nullable<SafeInteger>,
	pub total: SafeInteger,
	pub rows: PageRows,
}
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RetireBatch {
	pub retired: SafeInteger,
	pub remaining: SafeInteger,
	pub refused: Field,
}

/// Shared query admission for native and in-process session clients.
pub fn validate_query(scope: &str, query: &str) -> Result<(), Refusal> {
	if !rows::Name::accepts_utf16(scope.encode_utf16())
		|| query.encode_utf16().take(super::MAX_QUERY + 1).count() > super::MAX_QUERY
	{
		return Err(Refusal::Text);
	}
	Ok(())
}
