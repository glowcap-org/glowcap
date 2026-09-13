//! Attached-session operations views. Each requested capability selects one
//! bounded document shape; the platform does not inspect an untyped JSON tree.
pub mod wire;
use crate::{
	bridge::gateway::Description,
	fields::{List, Nullable, Object, SafeInteger},
	server::operations::{
		MAX_OPERATIONS_ROWS,
		operator::view::{
			MAX_JSON_UNITS, Refusal,
			rows::{Field, Name},
		},
	},
};
use alloc::boxed::Box;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Capability {
	Listeners,
	Diagnostics,
	Trace,
	Peering,
	Irc,
}
impl Capability {
	pub fn name(self) -> &'static str {
		match self {
			Self::Listeners => "listeners",
			Self::Diagnostics => "diagnostics",
			Self::Trace => "trace",
			Self::Peering => "peering",
			Self::Irc => "irc",
		}
	}
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Listener {
	pub transport: Field,
	pub description: Field,
	pub reference: Field,
	pub reference_name: Field,
	pub takes: List<Object<ListenerOption>, 32>,
	pub unavailable: Field,
	pub id: Nullable<SafeInteger<true>>,
	pub locator: Nullable<Field>,
	pub serving: bool,
}
impl Listener {
	pub fn validate(&self) -> Result<(), Refusal> {
		let live = self.id.as_ref().is_some();
		let empty = |text: &Field| text.text().utf16().next().is_none();
		if live != self.locator.as_ref().is_some()
			|| (self.serving && !live)
			|| empty(&self.reference) != empty(&self.reference_name)
		{
			return Err(Refusal::Relation);
		}
		Ok(())
	}
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ListenerOption {
	pub name: Field,
	pub kind: OptionKind,
	pub hint: Field,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OptionKind {
	Host,
	Port,
	Url,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Diagnostic {
	pub kind: Name,
	pub name: Name,
	pub note: Field,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Visualization {
	pub url: Name,
	pub connected: bool,
	pub refusal: Nullable<Name>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Peered {
	pub id: Name,
	pub name: Name,
	pub source: Name,
	pub phase: Phase,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Phase {
	Publishing,
	Live,
	Revoking,
	Failed,
}

#[derive(Clone, Debug)]
pub enum Snapshot {
	Listeners(List<Object<Listener>, MAX_OPERATIONS_ROWS>),
	Diagnostics(List<Object<Diagnostic>, MAX_OPERATIONS_ROWS>),
	Trace(Visualization),
	Peering(List<Object<Peered>, 256>),
	// The infrequent gateway read owns one large declaration; boxing it keeps
	// every small operations answer from reserving space for both forms.
	Irc(Box<Description>),
}
impl Snapshot {
	pub fn encode(&self) -> Result<alloc::string::String, Refusal> {
		let raw = match self {
			Self::Listeners(rows) => {
				for row in rows.as_slice() {
					row.validate()?;
				}
				serde_json::to_string(rows)
			}
			Self::Diagnostics(rows) => serde_json::to_string(rows),
			Self::Peering(rows) => serde_json::to_string(rows),
			Self::Trace(view) => serde_json::to_string(view),
			Self::Irc(view) => serde_json::to_string(view),
		}
		.map_err(|_| Refusal::Json)?;
		if raw.encode_utf16().take(MAX_JSON_UNITS + 1).count() > MAX_JSON_UNITS {
			return Err(Refusal::Budget);
		}
		Ok(raw)
	}
	pub fn decode(capability: Capability, raw: &str) -> Result<Self, Refusal> {
		if raw.encode_utf16().take(MAX_JSON_UNITS + 1).count() > MAX_JSON_UNITS {
			return Err(Refusal::Budget);
		}
		let invalid = |_| Refusal::Json;
		Ok(match capability {
			Capability::Listeners => {
				let rows: List<Object<Listener>, MAX_OPERATIONS_ROWS> = serde_json::from_str(raw).map_err(invalid)?;
				for row in rows.as_slice() {
					row.validate()?;
				}
				Self::Listeners(rows)
			}
			Capability::Diagnostics => Self::Diagnostics(serde_json::from_str(raw).map_err(invalid)?),
			Capability::Trace => Self::Trace(crate::fields::json_object(raw).map_err(invalid)?),
			Capability::Peering => Self::Peering(serde_json::from_str(raw).map_err(invalid)?),
			Capability::Irc => Self::Irc(Box::new(crate::fields::json_object(raw).map_err(invalid)?)),
		})
	}
}
