//! Archive admission for one live room line. Capture starts from the echoed
//! attachments; the event carries coordinates after the archive accepts them,
//! and a refused admission is reported rather than hidden behind the line.
use super::{events::ConversationEvent, worker::Recorder, LiveRoom, Platform};
use crate::{archive_recording::Recording, session_commands::SessionCommands};
use glowcap::Ref;
use rooms_application::{
	archive::{recording::Message as Archived, ConversationKind},
	room::{inbox::Message, message::ChangeKind},
	text::DocumentText,
};
use std::{
	future::{poll_fn, Future},
	pin::Pin,
	task::Poll,
};

/// Admit one room line to the archive. The answer is the admitted recording,
/// whose completion the caller watches; a refused admission is the error.
pub(super) fn record_room<P: Platform>(
	recorder: &Recorder,
	commands: &SessionCommands,
	live: &LiveRoom<P>,
	message: &Message<String, Ref>,
	event: &mut ConversationEvent,
	files: crate::archive_recording::Files,
	observations: &mut Observations,
) -> Result<(), String> {
	let keep = commands
		.view()
		.read(|state| state.checkpoint().map(|checkpoint| checkpoint.keeps_history()))
		.map_err(|e| e.to_string())?
		.map_err(|e| e.to_string())?;
	if !keep {
		return Ok(());
	}
	let Some(line) = message.marker.map(|marker| marker.id) else {
		return Ok(());
	};
	if observations.0.len() >= MAX_RECORDINGS {
		return Err("room archive observations are at their capacity".into());
	}
	let directory = DocumentText::from(live.directory.as_str());
	let conversation = DocumentText::from(event.conversation_id.as_str());
	let recorded = recorder.archive.record(
		&recorder.source,
		&Archived {
			keep,
			generation: Some(&recorder.generation),
			kind: ConversationKind::Room,
			directory: &directory,
			conversation: &conversation,
			nick: &live.nick,
			from: &message.from,
			text: &message.text,
			system: event.system,
			line: Some(line),
			change: message.marker.map(|marker| marker.kind).unwrap_or(ChangeKind::Said),
			at: event.at,
		},
		files,
	)?;
	if let Some(recording) = recorded {
		event.history_source = recording.coordinates.source.as_str().map(str::to_owned);
		event.history_generation = recording.coordinates.generation.as_str().map(str::to_owned);
		event.history_id = recording.coordinates.id.as_str().map(str::to_owned);
		observations.0.push(recording);
	}
	Ok(())
}

/// Receipt observation belongs to this membership's pump. Dropping the pump
/// releases every observation; the archive still owns admitted recording work.
/// Completion cannot write into a newer membership's issue state.
#[derive(Default)]
pub(super) struct Observations(Vec<Recording>);
const MAX_RECORDINGS: usize = 128;
impl Observations {
	pub async fn next(&mut self) -> Option<String> {
		let (index, result) = poll_fn(|cx| {
			for (index, recording) in self.0.iter_mut().enumerate() {
				if let Poll::Ready(result) = Pin::new(&mut recording.completion).poll(cx) {
					return Poll::Ready((index, result));
				}
			}
			Poll::Pending
		})
		.await;
		drop(self.0.remove(index));
		crate::archive_recording::completion_issue(result)
	}
}
