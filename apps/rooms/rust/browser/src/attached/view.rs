//! Plain-data browser projections. Serialize admitted values directly so
//! document strings retain UTF-16; no intermediate CapTP or JSON value tree.
use super::Result;
use rooms_application::session::snapshot::{views::EffectPhase, Field, Snapshot};
use serde::{
	ser::{SerializeSeq, SerializeStruct},
	Serialize, Serializer,
};
use wasm_bindgen::JsValue;

pub(super) fn snapshot(value: &Snapshot) -> Result<JsValue> {
	let encoded = serde_json::to_string(&View(value)).map_err(|e| e.to_string())?;
	js_sys::JSON::parse(&encoded).map_err(|_| "Rooms snapshot projection is invalid JSON".into())
}
struct View<'a>(&'a Snapshot);
impl Serialize for View<'_> {
	fn serialize<S: Serializer>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error> {
		let view = self.0;
		let mut row =
			serializer.serialize_struct("RoomsSessionSnapshot", 14 + usize::from(view.suspended_note.is_some()))?;
		row.serialize_field("revision", &view.revision)?;
		row.serialize_field("checkpoint", view.checkpoint.as_ref())?;
		row.serialize_field("pendingEffects", &view.pending_effects)?;
		row.serialize_field("pendingEffectDetails", &Effects(view.pending_effect_details.as_slice()))?;
		row.serialize_field("issues", &Issues(view.issues.as_slice()))?;
		row.serialize_field("connectedDirectories", &view.connected_directories)?;
		row.serialize_field("memberLocator", &view.member_locator)?;
		row.serialize_field("roomViews", &view.room_views)?;
		row.serialize_field("archiveShares", &view.archive_shares)?;
		row.serialize_field("directoryViews", &view.directory_views)?;
		row.serialize_field("access", &view.access)?;
		row.serialize_field("workspaceAdoption", &view.workspace_adoption)?;
		row.serialize_field("grants", &view.grants)?;
		row.serialize_field("handedRooms", &view.handed_rooms)?;
		if let Some(note) = &view.suspended_note {
			row.serialize_field("suspendedNote", note)?;
		}
		row.end()
	}
}
struct Issues<'a>(&'a [(Field, Field)]);
impl Serialize for Issues<'_> {
	fn serialize<S: Serializer>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error> {
		#[derive(Serialize)]
		struct Issue<'a> {
			subject: &'a Field,
			reason: &'a Field,
		}
		let mut rows = serializer.serialize_seq(Some(self.0.len()))?;
		for (subject, reason) in self.0 {
			rows.serialize_element(&Issue { subject, reason })?;
		}
		rows.end()
	}
}
struct Effects<'a>(&'a [(Field, Field, Field, EffectPhase)]);
impl Serialize for Effects<'_> {
	fn serialize<S: Serializer>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error> {
		#[derive(Serialize)]
		struct Effect<'a> {
			id: &'a Field,
			kind: &'a Field,
			subject: &'a Field,
			phase: EffectPhase,
		}
		let mut rows = serializer.serialize_seq(Some(self.0.len()))?;
		for (id, kind, subject, phase) in self.0 {
			rows.serialize_element(&Effect {
				id,
				kind,
				subject,
				phase: *phase,
			})?;
		}
		rows.end()
	}
}

pub(super) fn set(object: &JsValue, key: &str, value: JsValue) -> Result<()> {
	js_sys::Reflect::set(object, &key.into(), &value)
		.map_err(|_| "Rooms view property could not be written".to_owned())?
		.then_some(())
		.ok_or_else(|| "Rooms view property was refused".into())
}
pub(super) fn json(value: &impl Serialize) -> Result<JsValue> {
	let text = serde_json::to_string(value).map_err(|e| e.to_string())?;
	js_sys::JSON::parse(&text).map_err(|_| "Rooms view metadata could not be projected".into())
}
pub(super) fn document(value: &rooms_application::text::DocumentText) -> JsValue {
	match value.as_str() {
		Some(text) => text.into(),
		None => js_sys::JsString::from_char_code(&value.utf16().collect::<Vec<_>>()).into(),
	}
}
pub(super) fn event<C>(event: &rooms_application::session::event::Event<C>) -> Result<JsValue> {
	let output: JsValue = js_sys::Object::new().into();
	for (key, value) in [
		("source", &event.source),
		("conversationId", &event.conversation_id),
		("from", &event.from),
		("text", &event.text),
	] {
		set(&output, key, value.into())?;
	}
	set(&output, "sequence", (event.sequence as f64).into())?;
	set(&output, "at", (event.at as f64).into())?;
	set(
		&output,
		"lineId",
		event.line_id.map_or(JsValue::NULL, |value| (value as f64).into()),
	)?;
	set(
		&output,
		"change",
		event.change.map_or(JsValue::NULL, |value| value.event_change().into()),
	)?;
	set(&output, "editable", event.editable.into())?;
	set(&output, "system", event.system.into())?;
	let history = if let Some(history) = &event.history {
		let row: JsValue = js_sys::Object::new().into();
		set(&row, "source", document(&history.source))?;
		set(&row, "generation", document(&history.generation))?;
		set(&row, "id", document(&history.id))?;
		row
	} else {
		JsValue::NULL
	};
	set(&output, "history", history)?;
	if let Some(presence) = &event.presence {
		set(&output, "presence", json(presence)?)?;
	}
	if let Some(facts) = &event.facts {
		set(&output, "facts", json(facts)?)?;
	}
	Ok(output)
}
pub(super) fn history_change(change: rooms_application::archive::change::Change) -> Result<JsValue> {
	use rooms_application::archive::{change::Change, ConversationKind};
	match change {
		Change::All => Ok(JsValue::NULL),
		Change::Conversation {
			kind,
			directory,
			conversation,
		} => {
			let row: JsValue = js_sys::Object::new().into();
			set(
				&row,
				"kind",
				match kind {
					ConversationKind::Room => "room",
					ConversationKind::Direct => "direct",
				}
				.into(),
			)?;
			set(&row, "directory", document(&directory))?;
			set(&row, "conversation", document(&conversation))?;
			Ok(row)
		}
	}
}
