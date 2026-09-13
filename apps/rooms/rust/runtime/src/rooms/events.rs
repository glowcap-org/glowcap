//! Typing presence uses the session observer JSON contract, not a room line.
use glowcap::Ref;
use rooms_application::room::{inbox::Message, message::ChangeKind};

pub struct ConversationEvent {
	pub conversation_id: String,
	pub from: String,
	pub text: String,
	pub at: u64,
	pub line_id: Option<u64>,
	pub change: Option<ChangeKind>,
	pub editable: bool,
	pub system: bool,
	pub presence: Option<String>,
	pub facts: Option<String>,
	pub history_source: Option<String>,
	pub history_generation: Option<String>,
	pub history_id: Option<String>,
	pub files: Vec<crate::files::media_files::FileView>,
	pub previews: rooms_application::open_graph::Selection,
}

pub fn from_message(
	conversation_id: String,
	message: &Message<String, Ref>,
	editable: bool,
	at: u64,
) -> ConversationEvent {
	// The room's own announcements are system lines whatever they say; a
	// member's line is never one, even when it carries presence.
	let system = message.from == rooms_application::room::inbox::ROOM;
	ConversationEvent {
		conversation_id,
		from: message.from.clone(),
		text: message.text.clone(),
		at,
		line_id: message.marker.map(|marker| marker.id.get()),
		change: message.marker.map(|marker| marker.kind),
		editable,
		system,
		presence: message
			.presence
			.as_ref()
			.and_then(|value| serde_json::to_string(value).ok()),
		facts: message
			.facts
			.as_ref()
			.and_then(|value| serde_json::to_string(value).ok()),
		history_source: None,
		history_generation: None,
		history_id: None,
		files: Vec::new(),
		previews: message.previews.clone(),
	}
}

pub fn typing(conversation_id: String, peer: &str, on: bool, at: u64) -> ConversationEvent {
	ConversationEvent {
		conversation_id,
		from: peer.into(),
		text: String::new(),
		at,
		line_id: None,
		change: None,
		editable: false,
		system: true,
		presence: Some(format!(
			r#"{{"kind":"typing","name":{},"on":{}}}"#,
			serde_json::to_string(peer).unwrap_or_else(|_| "\"\"".into()),
			on
		)),
		facts: None,
		history_source: None,
		history_generation: None,
		history_id: None,
		files: Vec::new(),
		previews: Default::default(),
	}
}

impl ConversationEvent {
	/// Project trusted runtime data without exporting file proxies. Each view
	/// owns its source and sequence; files retain their existing media custody.
	pub fn project(
		&self,
		source: &str,
		sequence: u64,
	) -> Result<rooms_application::session::event::Event<crate::files::media_files::FileView>, crate::Error> {
		use crate::Error;
		use rooms_application::{archive::Coordinates, room::attachment::Attachment, session::event::Event};
		let history = match (&self.history_source, &self.history_generation, &self.history_id) {
			(None, None, None) => None,
			(Some(source), Some(generation), Some(id)) => Some(
				Coordinates::new(source.as_str().into(), generation.as_str().into(), id.as_str().into())
					.map_err(Error::invalid_by)?,
			),
			_ => return Err(Error::invalid("Rooms event has incomplete archive coordinates")),
		};
		Ok(Event {
			source: source.into(),
			sequence,
			conversation_id: self.conversation_id.clone(),
			from: self.from.clone(),
			text: self.text.clone(),
			at: self.at,
			line_id: self.line_id,
			change: self.change,
			editable: self.editable,
			history,
			system: self.system,
			presence: self
				.presence
				.as_deref()
				.map(serde_json::from_str)
				.transpose()
				.map_err(Error::invalid_by)?,
			facts: self
				.facts
				.as_deref()
				.map(rooms_application::session::event::Facts::decode)
				.transpose()
				.map_err(Error::invalid_by)?,
			previews: self.previews.clone(),
			attachments: self
				.files
				.iter()
				.map(|file| Attachment {
					description: file.description().clone(),
					blob: file.clone(),
				})
				.collect(),
		})
	}
}
