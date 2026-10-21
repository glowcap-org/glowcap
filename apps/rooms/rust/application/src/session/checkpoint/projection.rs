//! Checkpoint projection derives the bounded browser-visible session view.
use super::{Refusal, fields::*, model::*};
use crate::grants::Access;
use alloc::string::String;
use serde::{Serialize, Serializer, ser::SerializeSeq};

impl super::Checkpoint {}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct View<'a> {
	version: u8,
	directories: &'a List<Directory, 32>,
	conversations: Conversations<'a>,
	invitations: &'a [Invitation],
	active: &'a Nullable<Field>,
	standing: &'a Field,
	ignored: &'a List<Field, 512>,
	keep_history: bool,
	join: &'a Join,
	dm_mode: DmMode,
	capabilities: Capabilities,
	peering: &'a [Peering],
}
struct Conversations<'a>(&'a [Conversation]);
impl Serialize for Conversations<'_> {
	fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
		let mut seq = s.serialize_seq(Some(self.0.len()))?;
		for c in self.0 {
			match c {
				Conversation::Direct(_) => seq.serialize_element(c)?,
				Conversation::Room(r) => seq.serialize_element(&RoomView {
					kind: "room",
					id: &r.id,
					directory: &r.directory,
					name: &r.name,
					held: r.held,
					reconnect: &r.reconnect,
					publication_id: &r.publication_id,
					standing: &r.standing,
					draft: &r.draft,
				})?,
			}
		}
		seq.end()
	}
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RoomView<'a> {
	kind: &'static str,
	id: &'a Id,
	directory: &'a Id,
	name: &'a Text<32, true>,
	held: bool,
	#[serde(skip_serializing_if = "Option::is_none")]
	reconnect: &'a Option<Reconnect>,
	#[serde(skip_serializing_if = "Option::is_none")]
	publication_id: &'a Option<Field>,
	standing: &'a Nullable<Field>,
	draft: &'a Field,
}

pub(super) fn encode(s: &State, access: Access) -> Result<String, Refusal> {
	let encoded = match access {
		Access::Admin => serde_json::to_string(s),
		Access::None => serde_json::to_string(&State::empty()),
		Access::Observe | Access::Interact => serde_json::to_string(&redacted(s)),
	};
	encoded.map_err(|_| Refusal::Schema)
}

/// Export and observing facets share one borrowed authority-free projection.
pub(super) fn redacted(s: &State) -> impl Serialize + '_ {
	View {
		version: s.version,
		directories: &s.directories,
		conversations: Conversations(&s.conversations.0),
		invitations: &[],
		active: &s.active,
		standing: &s.standing,
		ignored: &s.ignored,
		keep_history: s.keep_history,
		join: &s.join,
		dm_mode: s.dm_mode,
		capabilities: Capabilities {
			operations: List(alloc::vec::Vec::new()),
			archive_peer: Nullable::Null,
		},
		peering: &[],
	}
}
