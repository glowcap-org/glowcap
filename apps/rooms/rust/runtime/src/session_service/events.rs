//! One event vocabulary for attached views. Room and direct conversations
//! produce different runtime events; a view sees one shape, encoded once.
use super::{answer::Answers, error::Error, facet::Rights, notice::Report};
use crate::media_files::FileView;
use crate::rooms::ConversationEvent;
use glowcap::{Argument, Session};
use rooms_application::{files::CHUNK_BYTES, session::verbs};

/// Project a direct-conversation event into the view vocabulary.
pub fn from_direct(event: &crate::direct_events::Event) -> ConversationEvent {
	use rooms_application::direct::event::Content;
	let conversation = event.context.conversation().text().as_str().unwrap_or("").to_owned();
	let history = event
		.recording
		.as_ref()
		.ok()
		.and_then(|recording| recording.as_ref())
		.map(|recording| &recording.coordinates);
	match &event.content {
		Content::Typing { on } => crate::rooms::typing(conversation, &event.from, *on, event.at),
		Content::Line(line) => ConversationEvent {
			conversation_id: conversation,
			from: event.from.clone(),
			text: line.text.clone(),
			at: event.at,
			line_id: Some(line.line.get()),
			change: Some(line.kind),
			editable: event.editable,
			system: false,
			presence: None,
			facts: None,
			history_source: history.and_then(|c| c.source.as_str().map(str::to_owned)),
			history_generation: history.and_then(|c| c.generation.as_str().map(str::to_owned)),
			history_id: history.and_then(|c| c.id.as_str().map(str::to_owned)),
			files: event.files.clone(),
		},
	}
}

/// The `event` notification's arguments for one view. Each attachment rides as
/// a proxy spawned on the view's own session; the proxies are returned so the
/// caller can drop them once the notification is queued, because the partner's
/// import keeps the export alive on its own.
pub(super) fn encode(
	session: &Session,
	source: &str,
	sequence: u64,
	rights: &Rights,
	event: &ConversationEvent,
	report: &Report,
	answers: &Answers,
) -> Result<(Vec<Argument>, Vec<glowcap::Ref>), Error> {
	let editable = event.editable && rights.may_interact();
	let optional = |value: &Option<String>| value.clone().map(Argument::String).unwrap_or(Argument::Void);
	let mut args = vec![
		source.into(),
		Argument::Integer(sequence as i64),
		event.conversation_id.clone().into(),
		event.from.clone().into(),
		event.text.clone().into(),
		Argument::Integer(event.at as i64),
		event
			.line_id
			.map(|id| Argument::Integer(id as i64))
			.unwrap_or(Argument::Void),
		event
			.change
			.map(|kind| Argument::String(kind.event_change().into()))
			.unwrap_or(Argument::Void),
		Argument::Boolean(editable),
		optional(&event.history_source),
		optional(&event.history_generation),
		optional(&event.history_id),
		Argument::Boolean(event.system),
		optional(&event.presence),
		optional(&event.facts),
	];
	let mut proxies = Vec::with_capacity(event.files.len());
	for file in &event.files {
		let proxy = attachment_proxy(session, file, report.clone(), answers.clone())?;
		let description = file.description();
		args.extend([
			"file".into(),
			description.name().into(),
			description.mime().into(),
			Argument::Integer(description.size() as i64),
			proxy.clone().into(),
			Argument::Integer(description.dimensions().0 as i64),
			Argument::Integer(description.dimensions().1 as i64),
		]);
		proxies.push(proxy);
	}
	Ok((args, proxies))
}

/// A bounded `read` over one shared attachment, answered from the media owner.
fn attachment_proxy(
	session: &Session,
	file: &FileView,
	report: Report,
	answers: Answers,
) -> Result<glowcap::Ref, Error> {
	let view = file.clone();
	Ok(session.spawn_owned(move |verb, args| {
		attachment_read(&view, &report, &answers, verb, args).map_err(|error| error.to_string())
	})?)
}

fn attachment_read(
	view: &FileView,
	report: &Report,
	answers: &Answers,
	verb: &str,
	args: &[Argument],
) -> Result<Argument, Error> {
	if verb != verbs::READ {
		return Err(Error::refused(format!("shared attachment has no method {verb}")));
	}
	let (offset, maximum) = read_bounds(args).ok_or_else(|| Error::refused(READ_SHAPE))?;
	let view = view.clone();
	answers.later(report.clone(), verbs::READ, async move {
		let bytes = view.read(offset, maximum).await.map_err(Error::runtime)?;
		Ok(Argument::Bytes(bytes))
	})
}

const READ_SHAPE: &str = "shared attachment read takes a bounded offset and length";

/// `read(offset, length)` with the length bounded by one blob chunk.
pub fn read_bounds(args: &[Argument]) -> Option<(u64, usize)> {
	match args {
		[Argument::Integer(offset), Argument::Integer(maximum)]
			if *offset >= 0 && *maximum > 0 && *maximum <= CHUNK_BYTES as i64 =>
		{
			Some((*offset as u64, *maximum as usize))
		}
		_ => None,
	}
}
