//! Recording is admitted before event publication. The archive owns capture
//! and persistence; the event carries its receipt without delaying delivery.
use super::*;
use crate::archive_recording::{Recorder as ArchiveRecorder, Recording};
use rooms_application::{
	archive::{recording::Message, ConversationKind},
	text::DocumentText,
};
use std::{
	fmt::Write,
	future::{poll_fn, Future},
	pin::Pin,
	task::Poll,
};

pub(crate) enum Settlement {
	Issue { subject: String, reason: String },
	Clear { subject: String },
}
impl Settlement {
	pub(super) fn parts(self) -> (String, Option<String>) {
		match self {
			Self::Issue { subject, reason } => (subject, Some(reason)),
			Self::Clear { subject } => (subject, None),
		}
	}
}

struct Observation {
	subject: String,
	recording: Recording,
	// Keep the event's original count and byte charge until its admitted
	// persistence outcome has an owner. Slow archives therefore apply the same
	// bounded pressure as slow event consumers.
	_permit: Permit,
}

/// Direct event delivery and archive persistence are independent outcomes.
/// This owner retains every admitted receipt without serializing delivery.
#[derive(Default)]
pub(crate) struct Observations(Vec<Observation>);
impl Observations {
	pub(crate) fn admit(&mut self, event: Event) -> Option<Settlement> {
		let specific = format!("archive:{}", event.context.conversation().text().as_str().unwrap_or(""));
		let subject = if rooms_application::session::snapshot::Field::new(specific.clone().into()).is_some() {
			specific
		} else {
			"archive".into()
		};
		let line = event.line().is_some();
		let Event { recording, _permit, .. } = event;
		match recording {
			Ok(Some(recording)) => {
				self.0.push(Observation {
					subject,
					recording,
					_permit,
				});
				None
			}
			Ok(None) if line => Some(Settlement::Clear { subject }),
			Ok(None) => None,
			Err(reason) => Some(Settlement::Issue { subject, reason }),
		}
	}
	pub(crate) fn is_empty(&self) -> bool {
		self.0.is_empty()
	}
	pub(crate) async fn next(&mut self) -> Settlement {
		let (index, result) = poll_fn(|cx| {
			for (index, observation) in self.0.iter_mut().enumerate() {
				if let Poll::Ready(result) = Pin::new(&mut observation.recording.completion).poll(cx) {
					return Poll::Ready((index, result));
				}
			}
			Poll::Pending
		})
		.await;
		let observation = self.0.remove(index);
		match crate::archive_recording::completion_issue(result) {
			Some(reason) => Settlement::Issue {
				subject: observation.subject,
				reason,
			},
			None => Settlement::Clear {
				subject: observation.subject,
			},
		}
	}
}

pub(super) struct Recorder {
	archive: Rc<dyn ArchiveRecorder>,
	source: DocumentText,
	generation: DocumentText,
}
impl Recorder {
	pub(super) fn event_bytes(&self) -> usize {
		// A receipt retains coordinates; a refusal retains a bounded diagnostic.
		self.source
			.heap_bytes()
			.saturating_add(self.generation.heap_bytes())
			.saturating_add(20)
			.max(rooms_application::failure::MAX_REASON_BYTES)
	}
}
impl<P: Platform> DirectEvents<P> {
	/// Connect the direct producer to its archive recording adapter. Recording
	/// samples committed retention and nickname at event admission, before any
	/// consumer delay. The parent still owns archive selection and erasure.
	pub fn with_recorder(
		platform: P,
		entropy: &mut impl Entropy,
		archive: Rc<dyn ArchiveRecorder>,
		source: DocumentText,
	) -> Result<(Self, Events), String> {
		let (mut owner, events) = Self::new(platform, entropy)?;
		let mut generation = String::with_capacity(32);
		for byte in owner.state.generation {
			write!(&mut generation, "{byte:02x}").expect("String formatting");
		}
		Rc::get_mut(&mut owner.state).expect("unpublished event owner").recorder = Some(Recorder {
			archive,
			source,
			generation: generation.into(),
		});
		Ok((owner, events))
	}
}
impl<P: Platform> State<P> {
	pub(super) fn record(
		&self,
		context: &AcceptedDirect,
		content: &Content<Ref>,
		files: Vec<FileView>,
		at: u64,
		outgoing_from: Option<&str>,
	) -> Result<Option<Recording>, String> {
		let (Some(recorder), Some(line)) = (&self.recorder, content.line()) else {
			return Ok(None);
		};
		context
			.recording_policy(|keep, nick| {
				if !keep {
					return Ok(None);
				}

				recorder.archive.record(
					&recorder.source,
					&Message {
						keep,
						generation: Some(&recorder.generation),
						kind: ConversationKind::Direct,
						directory: context.directory().text(),
						conversation: context.conversation().text(),
						nick: outgoing_from.unwrap_or(nick),
						from: outgoing_from.unwrap_or(
							context
								.peer()
								.text()
								.as_str()
								.ok_or("the direct peer is not valid UTF-8")?,
						),
						text: &line.text,
						system: false,
						line: Some(line.line),
						change: line.kind,
						at,
					},
					crate::archive_recording::Files::Retained(files),
				)
			})
			.map_err(|error| rooms_application::failure::reason_prefix(&error).to_owned())
	}
}
