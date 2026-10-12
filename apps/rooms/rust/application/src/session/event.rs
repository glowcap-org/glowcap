//! Attached-session events. Admission validates the whole notice before
//! retaining any attachment capabilities. Transport custody stays in the binding.
use crate::{
	archive::Coordinates,
	fields::{List, SafeInteger, Text},
	room::{
		attachment::{self, Attachment, AttachmentArgument},
		carries::Carries,
		inbox::metadata::{MAX_SEAT_BADGE, MAX_SEAT_SAID},
		line::MAX_LINE_BYTES,
		message::ChangeKind,
	},
	session::snapshot::views::{Bridge, SeatPhase},
};
use alloc::{borrow::Cow, string::String, vec::Vec};
use serde::{Deserialize, Serialize};

const MAX_FIELD_UNITS: usize = 65536;
pub const HEADER_FIELDS: usize = 16;
pub const MAX_FIELDS: usize = HEADER_FIELDS + attachment::RECORD_SPAN * crate::room::line::MAX_MESSAGE_FILES;

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum Presence {
	Typing {
		name: Text<32, true>,
		on: bool,
	},
	Roster {
		names: List<Text<32, true>, { crate::server::rooms::MAX_ROSTER_SEEN }>,
	},
	Join {
		name: Text<32, true>,
	},
	Leave {
		name: Text<32, true>,
	},
	Offline {
		names: List<Text<32, true>, { crate::server::rooms::MAX_ROOM_OFFLINE }>,
	},
	Away {
		name: Text<32, true>,
		reason: Text<120>,
	},
	Seat {
		name: Text<32, true>,
		state: SeatPhase,
		nick: Text<32, true>,
		network: Text<32, true>,
		badge: Text<MAX_SEAT_BADGE, true>,
		said: Text<MAX_SEAT_SAID, true>,
	},
}
// Read each record from its raw JSON. Serde's internally tagged buffering
// cannot preserve DocumentText's isolated UTF-16 surrogates.
impl<'de> Deserialize<'de> for Presence {
	fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
		let raw = <&serde_json::value::RawValue>::deserialize(d)?;
		#[derive(Deserialize)]
		struct Tag<'a> {
			#[serde(borrow)]
			kind: Cow<'a, str>,
		}
		let tag: Tag<'_> = crate::fields::json_object(raw.get()).map_err(serde::de::Error::custom)?;
		fn read<'a, T: Deserialize<'a>, E: serde::de::Error>(raw: &'a str) -> Result<T, E> {
			serde_json::from_str(raw).map_err(E::custom)
		}
		match tag.kind.as_ref() {
			crate::protocol_data::TYPING => {
				#[derive(Deserialize)]
				#[serde(deny_unknown_fields)]
				struct Record {
					#[serde(rename = "kind")]
					_kind: serde::de::IgnoredAny,
					name: Text<32, true>,
					on: bool,
				}
				let r: Record = read(raw.get())?;
				Ok(Self::Typing { name: r.name, on: r.on })
			}
			crate::protocol_data::ROSTER | crate::protocol_data::OFFLINE => {
				#[derive(Deserialize)]
				#[serde(deny_unknown_fields)]
				struct Record<const N: usize> {
					#[serde(rename = "kind")]
					_kind: serde::de::IgnoredAny,
					names: List<Text<32, true>, N>,
				}
				if tag.kind == crate::protocol_data::ROSTER {
					let r: Record<{ crate::server::rooms::MAX_ROSTER_SEEN }> = read(raw.get())?;
					Ok(Self::Roster { names: r.names })
				} else {
					let r: Record<{ crate::server::rooms::MAX_ROOM_OFFLINE }> = read(raw.get())?;
					Ok(Self::Offline { names: r.names })
				}
			}
			crate::protocol_data::JOIN | crate::protocol_data::LEAVE => {
				#[derive(Deserialize)]
				#[serde(deny_unknown_fields)]
				struct Record {
					#[serde(rename = "kind")]
					_kind: serde::de::IgnoredAny,
					name: Text<32, true>,
				}
				let r: Record = read(raw.get())?;
				Ok(if tag.kind == crate::protocol_data::JOIN {
					Self::Join { name: r.name }
				} else {
					Self::Leave { name: r.name }
				})
			}
			crate::protocol_data::AWAY => {
				#[derive(Deserialize)]
				#[serde(deny_unknown_fields)]
				struct Record {
					#[serde(rename = "kind")]
					_kind: serde::de::IgnoredAny,
					name: Text<32, true>,
					reason: Text<120>,
				}
				let r: Record = read(raw.get())?;
				Ok(Self::Away {
					name: r.name,
					reason: r.reason,
				})
			}
			crate::protocol_data::SEAT => {
				#[derive(Deserialize)]
				#[serde(deny_unknown_fields)]
				struct Record {
					#[serde(rename = "kind")]
					_kind: serde::de::IgnoredAny,
					name: Text<32, true>,
					state: SeatPhase,
					nick: Text<32, true>,
					network: Text<32, true>,
					badge: Text<MAX_SEAT_BADGE, true>,
					said: Text<MAX_SEAT_SAID, true>,
				}
				let r: Record = read(raw.get())?;
				Ok(Self::Seat {
					name: r.name,
					state: r.state,
					nick: r.nick,
					network: r.network,
					badge: r.badge,
					said: r.said,
				})
			}
			_ => Err(serde::de::Error::custom("invalid Rooms presence kind")),
		}
	}
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Facts {
	#[serde(
		default,
		deserialize_with = "super::fields::present",
		skip_serializing_if = "Option::is_none"
	)]
	pub topic: Option<Text<300>>,
	#[serde(
		default,
		deserialize_with = "super::fields::present",
		skip_serializing_if = "Option::is_none"
	)]
	pub line_bytes: Option<SafeInteger<true>>,
	#[serde(
		default,
		deserialize_with = "super::fields::present",
		skip_serializing_if = "Option::is_none"
	)]
	pub listed: Option<bool>,
	#[serde(
		default,
		deserialize_with = "crate::fields::present_object",
		skip_serializing_if = "Option::is_none"
	)]
	pub bridge: Option<Bridge>,
	/// See `crate::room::carries`. What a membership in this room can use.
	#[serde(
		default,
		deserialize_with = "crate::fields::present_object",
		skip_serializing_if = "Option::is_none"
	)]
	pub carries: Option<Carries>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
	Shape,
	Text,
	Number,
	Metadata,
	History,
	Attachments,
	Mutation,
}
impl core::fmt::Display for Refusal {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		write!(f, "invalid Rooms session event: {self:?}")
	}
}
impl core::error::Error for Refusal {}

impl Facts {
	pub fn decode(raw: &str) -> Result<Self, serde_json::Error> {
		crate::fields::json_object(raw)
	}
}

pub struct Event<C> {
	pub source: String,
	pub sequence: u64,
	pub conversation_id: String,
	pub from: String,
	pub text: String,
	pub at: u64,
	pub line_id: Option<u64>,
	pub change: Option<ChangeKind>,
	pub editable: bool,
	pub history: Option<Coordinates>,
	pub system: bool,
	pub presence: Option<Presence>,
	pub facts: Option<Facts>,
	pub previews: crate::open_graph::Selection,
	pub attachments: Vec<Attachment<C>>,
}

fn names_bytes<const N: usize>(names: &List<Text<32, true>, N>) -> usize {
	names.capacity() * core::mem::size_of::<Text<32, true>>()
		+ names
			.as_slice()
			.iter()
			.map(|name| name.text().heap_bytes())
			.sum::<usize>()
}

impl<C> Event<C> {
	/// Transfer attachment custody independently of the retained event metadata.
	pub fn into_parts(self) -> (Event<()>, Vec<Attachment<C>>) {
		let metadata = Event {
			source: self.source,
			sequence: self.sequence,
			conversation_id: self.conversation_id,
			from: self.from,
			text: self.text,
			at: self.at,
			line_id: self.line_id,
			change: self.change,
			editable: self.editable,
			history: self.history,
			system: self.system,
			presence: self.presence,
			facts: self.facts,
			previews: self.previews,
			attachments: Vec::new(),
		};
		(metadata, self.attachments)
	}
	/// Metadata graph capacity. The adapter separately charges capability custody.
	pub fn retained_bytes(&self) -> usize {
		let history = self.history.as_ref().map_or(0, |h| {
			h.source.heap_bytes() + h.generation.heap_bytes() + h.id.heap_bytes()
		});
		let presence = self.presence.as_ref().map_or(0, |p| match p {
			Presence::Typing { name, .. } | Presence::Join { name } | Presence::Leave { name } => {
				name.text().heap_bytes()
			}
			Presence::Roster { names } => names_bytes(names),
			Presence::Offline { names } => names_bytes(names),
			Presence::Away { name, reason } => name.text().heap_bytes() + reason.text().heap_bytes(),
			Presence::Seat {
				name,
				nick,
				network,
				badge,
				said,
				..
			} => {
				name.text().heap_bytes()
					+ nick.text().heap_bytes()
					+ network.text().heap_bytes()
					+ badge.text().heap_bytes()
					+ said.text().heap_bytes()
			}
		});
		let facts = self.facts.as_ref().map_or(0, |f| {
			f.topic.as_ref().map_or(0, |t| t.text().heap_bytes())
				+ f.bridge.as_ref().map_or(0, |b| {
					b.prefix.text().heap_bytes()
						+ b.badge.text().heap_bytes()
						+ b.said.text().heap_bytes()
						+ b.scope.text().heap_bytes()
				})
		});
		core::mem::size_of::<Self>()
			+ self.source.capacity()
			+ self.conversation_id.capacity()
			+ self.from.capacity()
			+ self.text.capacity()
			+ history + presence
			+ facts + self.attachments.capacity() * core::mem::size_of::<Attachment<C>>()
			+ self.previews.retained_bytes()
			+ self
				.attachments
				.iter()
				.map(|file| file.description.retained_bytes())
				.sum::<usize>()
	}
}
impl<C: Clone> Event<C> {
	pub fn read<A: AttachmentArgument<Capability = C>>(args: &[A]) -> Result<Self, Refusal> {
		if !(HEADER_FIELDS..=MAX_FIELDS).contains(&args.len()) {
			return Err(Refusal::Shape);
		}
		let text = |at: usize, limit: usize, nonempty: bool| {
			args[at]
				.text()
				.filter(|s| (!nonempty || !s.is_empty()) && s.encode_utf16().take(limit + 1).count() <= limit)
				.ok_or(Refusal::Text)
		};
		let number = |at: usize, positive: bool| {
			args[at]
				.integer()
				.and_then(|n| u64::try_from(n).ok())
				.filter(|n| *n < (1 << 53) && (!positive || *n != 0))
				.ok_or(Refusal::Number)
		};
		let source = text(0, MAX_FIELD_UNITS, true)?;
		let sequence = number(1, true)?;
		let conversation_id = text(2, MAX_FIELD_UNITS, false)?;
		let from = text(3, 32, false)?;
		let line = args[4]
			.text()
			.filter(|s| s.len() <= MAX_LINE_BYTES)
			.ok_or(Refusal::Text)?;
		let at = number(5, false)?;
		let line_id = if args[6].is_null() {
			None
		} else {
			Some(number(6, true)?)
		};
		let change = if args[7].is_null() {
			None
		} else {
			Some(match args[7].text() {
				Some("said") => ChangeKind::Said,
				Some(crate::protocol_data::EDITED) => ChangeKind::Edited,
				Some(crate::protocol_data::REFILED) => ChangeKind::Refiled,
				Some(crate::protocol_data::WITHDRAWN) => ChangeKind::Withdrawn,
				_ => return Err(Refusal::Mutation),
			})
		};
		let editable = args[8].boolean().ok_or(Refusal::Shape)?;
		let history = if args[9..12].iter().all(|a| a.is_null()) {
			None
		} else {
			Some(
				Coordinates::new(
					text(9, crate::archive::MAX_ID_BYTES, true)?.into(),
					text(10, crate::archive::MAX_ID_BYTES, true)?.into(),
					text(11, crate::archive::MAX_ID_BYTES, true)?.into(),
				)
				.map_err(|_| Refusal::History)?,
			)
		};
		let system = args[12].boolean().ok_or(Refusal::Shape)?;
		let presence = metadata(&args[13], |raw| serde_json::from_str::<Presence>(raw))?;
		let facts = metadata(&args[14], Facts::decode)?;
		let previews = args[15]
			.text()
			.and_then(|raw| crate::open_graph::Selection::decode(line, raw).ok())
			.ok_or(Refusal::Metadata)?;
		if line_id.is_none()
			&& matches!(
				change,
				Some(ChangeKind::Edited | ChangeKind::Refiled | ChangeKind::Withdrawn)
			) {
			return Err(Refusal::Mutation);
		}
		if args.len() > HEADER_FIELDS && (system || matches!(change, Some(ChangeKind::Edited | ChangeKind::Withdrawn)))
		{
			return Err(Refusal::Attachments);
		}
		// Only a fully valid notice may retain its supplied capability guards.
		let attachments = attachment::read_exact(args, HEADER_FIELDS).map_err(|_| Refusal::Attachments)?;
		Ok(Self {
			source: source.into(),
			sequence,
			conversation_id: conversation_id.into(),
			from: from.into(),
			text: line.into(),
			at,
			line_id,
			change,
			editable,
			history,
			system,
			presence,
			facts,
			previews,
			attachments,
		})
	}
}
fn metadata<T>(
	value: &impl crate::room::ArgumentView,
	decode: impl FnOnce(&str) -> Result<T, serde_json::Error>,
) -> Result<Option<T>, Refusal> {
	if value.is_null() {
		return Ok(None);
	}
	let text = value
		.text()
		.filter(|s| s.encode_utf16().take(MAX_FIELD_UNITS + 1).count() <= MAX_FIELD_UNITS)
		.ok_or(Refusal::Metadata)?;
	decode(text).map(Some).map_err(|_| Refusal::Metadata)
}
