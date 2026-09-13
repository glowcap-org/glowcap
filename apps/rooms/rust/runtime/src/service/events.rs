//! One event vocabulary for attached views. Room and direct conversations
//! produce different runtime events; a view sees one shape, encoded once.
use super::{answer::Answers, error::Error, facet::Rights, notice::Report};
use crate::files::media_files::FileView;
use crate::rooms::ConversationEvent;
use glowcap::{Argument, Session};
use rooms_application::{files::CHUNK_BYTES, session::verbs};

/// Project a direct-conversation event into the view vocabulary. The event
/// is taken by value so its text, sender, files, and previews move across.
pub fn from_direct(event: crate::direct::events::Delivered) -> ConversationEvent {
	use rooms_application::direct::event::Content;
	let conversation = event.context.conversation().text().as_str().unwrap_or("").to_owned();
	let history = event.history.as_ref();
	match event.content {
		Content::Typing { on } => crate::rooms::typing(conversation, &event.from, on, event.at),
		Content::Line(line) => ConversationEvent {
			conversation_id: conversation,
			from: event.from,
			text: line.text,
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
			files: event.files,
			previews: line.previews,
		},
	}
}

const SOURCE_AT: usize = 0;
const SEQUENCE_AT: usize = 1;
/// After source, sequence, conversation id, sender, text, timestamp, line id,
/// and change kind.
const EDITABLE_AT: usize = 8;
const ATTACHMENTS_AT: usize = 16;

/// One event's complete argument vector. Delivery borrows arguments only until
/// the Host has synchronously copied them into its queue, so every recipient
/// can reuse this allocation and the shared strings inside it. Only the
/// per-view header and attachment-proxy fields are replaced between deliveries.
/// Thus Rust builds one argument vector and one copy of each shared field per
/// event, independent of recipient count; each Host still owns its unavoidable
/// queued-message copy.
pub(super) struct Prepared {
	args: Vec<Argument>,
}

impl Prepared {
	pub fn args(&self) -> &[Argument] {
		&self.args
	}

	fn address(&mut self, source: &str, sequence: u64, editable: bool) {
		let Argument::String(current_source) = &mut self.args[SOURCE_AT] else {
			unreachable!("the prepared event source has one fixed wire position")
		};
		current_source.clear();
		current_source.push_str(source);
		self.args[SEQUENCE_AT] = Argument::Integer(sequence as i64);
		self.args[EDITABLE_AT] = Argument::Boolean(editable);
		// A proxy belongs to one recipient's session. Release the template's
		// previous clones before preparing the next set, so a partial failure can
		// never leave a stale reference ready to send.
		for at in (ATTACHMENTS_AT + 4..self.args.len()).step_by(ATTACHMENT_ARGUMENTS) {
			self.args[at] = Argument::Void;
		}
	}
}

/// Encode the shared event body and attachment descriptions once. Proxy slots
/// begin void because their references belong to each recipient's session.
pub(super) fn prepare(event: &ConversationEvent) -> Prepared {
	let optional = |value: &Option<String>| value.clone().map(Argument::String).unwrap_or(Argument::Void);
	let mut args = Vec::with_capacity(ATTACHMENTS_AT + event.files.len() * ATTACHMENT_ARGUMENTS);
	args.extend([
		Argument::String(String::new()),
		Argument::Integer(0),
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
		Argument::Boolean(false),
		optional(&event.history_source),
		optional(&event.history_generation),
		optional(&event.history_id),
		Argument::Boolean(event.system),
		optional(&event.presence),
		optional(&event.facts),
		event.previews.encode().into(),
	]);
	debug_assert_eq!(args.len(), ATTACHMENTS_AT);
	for file in &event.files {
		let description = file.description();
		args.extend([
			"file".into(),
			description.name().into(),
			description.mime().into(),
			Argument::Integer(description.size() as i64),
			Argument::Void,
			Argument::Integer(description.dimensions().0 as i64),
			Argument::Integer(description.dimensions().1 as i64),
		]);
	}
	Prepared { args }
}

/// Arguments one attachment adds after the body.
const ATTACHMENT_ARGUMENTS: usize = 7;

/// The half of an `event` that differs per view: who receives it, and how
/// far along its own stream it is. The body is shared across recipients.
pub(super) struct Recipient<'a> {
	pub session: &'a Session,
	pub source: &'a str,
	pub sequence: u64,
	pub rights: &'a Rights,
}

/// The `event` notification's arguments for one view. Each attachment rides as
/// a proxy spawned on the view's own session; the proxies are returned so the
/// caller can drop them once the notification is queued, because the partner's
/// import keeps the export alive on its own.
pub(super) fn encode(
	to: &Recipient<'_>,
	event: &ConversationEvent,
	prepared: &mut Prepared,
	report: &Report,
	answers: &Answers,
) -> Result<Vec<glowcap::Ref>, Error> {
	prepared.address(to.source, to.sequence, event.editable && to.rights.may_interact());
	let mut proxies = Vec::with_capacity(event.files.len());
	for (index, file) in event.files.iter().enumerate() {
		let proxy = attachment_proxy(to.session, file, report.clone(), answers.clone())?;
		let proxy_at = ATTACHMENTS_AT + index * ATTACHMENT_ARGUMENTS + 4;
		prepared.args[proxy_at] = proxy.clone().into();
		proxies.push(proxy);
	}
	Ok(proxies)
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
		attachment_read(&view, &report, &answers, verb, args).map_err(Error::into_refusal)
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
		return Err(Error::invalid(format!("shared attachment has no method {verb}")));
	}
	let (offset, maximum) = read_bounds(args).ok_or_else(|| Error::invalid(READ_SHAPE))?;
	let view = view.clone();
	answers.later(report.clone(), verbs::READ, async move {
		let bytes = view.read(offset, maximum).await?;
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

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_application::room::message::ChangeKind;

	fn event() -> ConversationEvent {
		ConversationEvent {
			conversation_id: "room-1".into(),
			from: "alice".into(),
			text: "hello".into(),
			at: 42,
			line_id: Some(7),
			change: Some(ChangeKind::Said),
			editable: true,
			system: false,
			presence: None,
			facts: Some("{}".into()),
			history_source: Some("src".into()),
			history_generation: None,
			history_id: Some("id".into()),
			files: Vec::new(),
			previews: Default::default(),
		}
	}

	#[test]
	fn retargeting_preserves_wire_order_and_shared_string_storage() {
		let event = event();
		let mut prepared = prepare(&event);
		let shared_strings = |args: &[Argument]| {
			args[2..]
				.iter()
				.filter_map(|arg| match arg {
					Argument::String(text) => Some(text.as_ptr()),
					_ => None,
				})
				.collect::<Vec<_>>()
		};
		let before = shared_strings(prepared.args());
		prepared.address("watch-3", 9, false);
		let expected = vec![
			Argument::from("watch-3"),
			Argument::Integer(9),
			Argument::from("room-1"),
			Argument::from("alice"),
			Argument::from("hello"),
			Argument::Integer(42),
			Argument::Integer(7),
			Argument::String(ChangeKind::Said.event_change().into()),
			Argument::Boolean(false),
			Argument::from("src"),
			Argument::Void,
			Argument::from("id"),
			Argument::Boolean(false),
			Argument::Void,
			Argument::from("{}"),
			Argument::from(event.previews.encode()),
		];
		assert_eq!(prepared.args(), expected);
		prepared.address("watch-4", 1, true);
		assert_eq!(prepared.args[0], Argument::from("watch-4"));
		assert_eq!(prepared.args[1], Argument::Integer(1));
		assert_eq!(prepared.args[8], Argument::Boolean(true));
		assert_eq!(
			shared_strings(prepared.args()),
			before,
			"retargeting cloned shared event strings"
		);
	}
}
