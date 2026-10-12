//! Outgoing recording captures admission inputs, then follows exact line custody.
use super::allocation;
use super::{
	State,
	records::{self, Field},
	results::Settlement,
};
use glowcap::{
	Argument, Ref, Result,
	loam::{self, Call, Invocation, ReferenceRequest},
};
use rooms_application::{
	content::session::{
		custody::{self, Coordinate, FieldKey, Outcome},
		outgoing::{FileSource, Origin, Update},
		uploads, workspace,
	},
	fields::{List, Text},
	open_graph::Selection,
	room::{attachment::Attachment, message::ChangeKind},
};
use rooms_glowcap::client::{Deadline, Tasks};
use std::{num::NonZeroU64, rc::Rc};

pub(super) struct Edit<'a> {
	pub text: &'a str,
	pub change: ChangeKind,
	pub keep: Option<&'a [u32]>,
	pub submitted: &'a [Attachment<Ref>],
}

pub(super) struct Post<'a> {
	pub operation: &'a str,
	pub conversation: &'a str,
	pub text: &'a str,
	pub previews: Selection,
	pub files: &'a [Attachment<Ref>],
}

/// One admitted worker owns the original source, scalar provenance, caption
/// fixed archive identity (64 bytes for an introduced direct) and the actual
/// selected recording writer
/// and at most eight attachment edges through its observed effect and private
/// settlement. Borrowing invocation arguments cannot survive either wait.
/// Re-reading current intent would change sender identity or file selection.
/// The existing eight-worker limit bounds these copies. File bytes remain at
/// their source. Neither capture nor its persisted plan materializes them.
pub(super) struct Capture<P: Tasks> {
	update: Update,
	event: Option<super::activity::PreparedEvent<P>>,
	confirmed: bool,
	text: String,
	change: ChangeKind,
	destination: Option<crate::archive::session::Destination>,
	history: workspace::Id,
	post: bool,
	upload: bool,
}
fn coordinate<K>(role: custody::Role, key: FieldKey<K>) -> Coordinate {
	Coordinate {
		role,
		key: FieldKey::new(key.slot(), key.generation()),
	}
}
fn restore(location: records::Location) -> Result<ReferenceRequest> {
	Ok(ReferenceRequest::RestorePage {
		page: location
			.page
			.checked_sub(1)
			.ok_or_else(|| loam::refusal("invalid outgoing custody page"))?,
		field: location.field,
	})
}
pub(super) fn references(
	record: &workspace::Record<records::Metadata, loam::BoundResource>,
	target: Coordinate,
) -> Result<Vec<ReferenceRequest>> {
	let Some(origin) = record
		.outgoing
		.as_slice()
		.iter()
		.find(|origin| coordinate(custody::Role::Line, origin.line) == target)
	else {
		return Ok(Vec::new());
	};
	std::iter::once(coordinate(custody::Role::SessionAccess, origin.source))
		.chain(
			origin
				.files
				.as_slice()
				.iter()
				.map(|file| coordinate(custody::Role::SourceBlob, file.source)),
		)
		.map(|key| {
			restore(records::location(
				&record
					.custody
					.get(key)
					.ok_or_else(|| loam::refusal("outgoing source custody is absent"))?,
			))
		})
		.collect()
}
impl<P: Tasks + Deadline + Clone + 'static> Capture<P> {
	pub(super) fn post(
		owner: &Rc<State<P>>,
		record: &mut records::Record,
		input: Invocation<'_>,
		source: Ref,
		post: Post<'_>,
	) -> Result<Self> {
		let Post {
			operation,
			conversation,
			text,
			previews,
			files,
		} = post;
		let direct = record
			.intent
			.conversations
			.as_slice()
			.iter()
			.find_map(|row| match row {
				workspace::Conversation::Direct(row) if row.id.text().as_str() == Some(conversation) => Some(row),
				_ => None,
			})
			.ok_or_else(|| loam::refusal("outgoing direct conversation is absent"))?;
		let history = direct.history_id();
		let directory = record
			.intent
			.directories
			.as_slice()
			.iter()
			.find(|row| row.id == direct.directory)
			.ok_or_else(|| loam::refusal("outgoing directory is absent"))?;
		if record.outgoing.as_slice().len() == custody::MAX_FIELDS_PER_ROLE
			|| direct.lines.as_slice().len() == custody::MAX_FIELDS_PER_ROLE
		{
			return Err(loam::refusal("outgoing line custody is full"));
		}
		let existing = record
			.intent
			.conversations
			.as_slice()
			.iter()
			.flat_map(|row| row.lines())
			.map(|row| row.id.get())
			.max()
			.unwrap_or(0);
		if record.custody.next_identity().get() == 0 {
			return Err(loam::refusal("line identities exhausted"));
		}
		let id = owner.next_line.get().max(record.custody.next_identity().get()).max(
			existing
				.checked_add(1)
				.ok_or_else(|| loam::refusal("line identities exhausted"))?,
		);
		let id = rooms_application::session::state::SafeInteger::new(id)
			.filter(|id| rooms_application::room::message::LineId::new(id.get()).is_some())
			.ok_or_else(|| loam::refusal("line identities exhausted"))?;
		let from = directory
			.assigned_nick
			.as_ref()
			.unwrap_or(&directory.nick)
			.text()
			.as_str()
			.filter(|from| rooms_application::room::inbox::valid_nick(from))
			.ok_or_else(|| loam::refusal("outgoing nickname is unavailable"))?;
		let generation = NonZeroU64::new(id.get()).ok_or_else(|| loam::refusal("invalid outgoing line identity"))?;
		let mut allocated = allocation::Allocator::new(record, generation);
		let key = allocated.allocate(custody::Role::Line)?;
		let source_key = allocated.allocate(custody::Role::SessionAccess)?;
		let file_keys = (0..files.len())
			.map(|_| allocated.allocate(custody::Role::SourceBlob))
			.collect::<Result<Vec<_>>>()?;
		let origin = Origin {
			line: key,
			route: direct
				.access
				.ok_or_else(|| loam::refusal("original direct route is absent"))?,
			source: source_key,
			id,
			generation: Text::new(format!("{}:sent", &owner.activity.token(0)?[..82]).into())
				.ok_or_else(|| loam::refusal("outgoing live identity is not admitted"))?,
			directory: direct.directory.clone(),
			conversation: direct.id.clone(),
			from: Text::new(from.into()).ok_or_else(|| loam::refusal("outgoing nickname is unavailable"))?,
			previews,
			files: List::new(
				files
					.iter()
					.enumerate()
					.map(|(index, file)| rooms_application::content::session::outgoing::File {
						description: uploads::Description::from_file(&file.description),
						source: file_keys[index],
					})
					.collect(),
			)
			.ok_or_else(|| loam::refusal("outgoing file selection exceeds its bound"))?,
		};
		owner.next_line.set(id.get() + 1);
		record.custody.set_next_identity(
			rooms_application::fields::SafeInteger::new(id.get() + 1)
				.unwrap_or(rooms_application::fields::SafeInteger::ZERO),
		);
		let event = owner.activity.prepare_outgoing(
			source,
			&origin,
			text,
			ChangeKind::Said,
			files.to_vec(),
			Some(operation),
		)?;
		Ok(Self {
			update: Update {
				origin,
				existing: false,
				files: List::new((0..files.len()).map(FileSource::Submitted).collect())
					.ok_or_else(|| loam::refusal("outgoing file selection exceeds its bound"))?,
			},
			event: Some(event),
			confirmed: false,
			text: text.into(),
			change: ChangeKind::Said,
			destination: super::content::recording::destination(owner, &records::metadata(input)?)?,
			history,
			post: true,
			upload: false,
		})
	}
	pub(super) fn change(
		owner: &Rc<State<P>>,
		record: &mut records::Record,
		call: &mut Call<'_>,
		input: Invocation<'_>,
		target: Coordinate,
		edit: Edit<'_>,
	) -> Result<Option<Self>> {
		let Edit {
			text,
			change,
			keep,
			submitted,
		} = edit;
		let Some(mut origin) = record
			.outgoing
			.as_slice()
			.iter()
			.find(|origin| coordinate(custody::Role::Line, origin.line) == target)
			.cloned()
		else {
			return Ok(None);
		};
		let history = record
			.intent
			.conversations
			.as_slice()
			.iter()
			.find(|row| row.id() == &origin.conversation)
			.ok_or_else(|| loam::refusal("original outgoing conversation is absent"))?
			.history_id();
		if record.effects.as_slice().iter().any(|effect| {
			matches!(effect.outcome, Outcome::Unresolved)
				&& effect
					.outgoing
					.as_ref()
					.is_some_and(|update| update.existing && update.origin.line == origin.line)
		}) {
			return Err(loam::refusal("original outgoing line has a pending change"));
		}
		let generation = NonZeroU64::new(record.custody.next_identity().get())
			.ok_or_else(|| loam::refusal("sender identities exhausted"))?;
		record.custody.set_next_identity(
			rooms_application::fields::SafeInteger::new(generation.get() + 1)
				.unwrap_or(rooms_application::fields::SafeInteger::ZERO),
		);
		let mut allocated = allocation::Allocator::new(record, generation);
		let source = record
			.custody
			.session_access(origin.source)
			.ok_or_else(|| loam::refusal("original outgoing source is absent"))?
			.reference
			.resolve(call, input)?;
		let mut files = Vec::new();
		let mut selected = Vec::new();
		let mut metadata = Vec::new();
		let kept: Vec<usize> = if change == ChangeKind::Withdrawn {
			Vec::new()
		} else {
			keep.map_or_else(
				|| (0..origin.files.as_slice().len()).collect(),
				|keep| keep.iter().map(|index| *index as usize).collect(),
			)
		};
		for at in kept {
			let file = origin
				.files
				.as_slice()
				.get(at)
				.ok_or_else(|| loam::refusal("outgoing kept file is absent"))?;
			let blob = record
				.custody
				.source_blob(file.source)
				.ok_or_else(|| loam::refusal("outgoing file source is absent"))?
				.reference
				.resolve(call, input)?;
			files.push(Attachment {
				description: file.description.file().map_err(|e| loam::refusal(e.to_string()))?,
				blob,
			});
			metadata.push(file.clone());
			selected.push(FileSource::Retained(file.source));
		}
		for (index, file) in submitted.iter().enumerate() {
			files.push(file.clone());
			metadata.push(rooms_application::content::session::outgoing::File {
				description: uploads::Description::from_file(&file.description),
				source: allocated.allocate(custody::Role::SourceBlob)?,
			});
			selected.push(FileSource::Submitted(index));
		}
		origin.files = List::new(metadata).ok_or_else(|| loam::refusal("outgoing file selection exceeds its bound"))?;
		origin.previews = if change == ChangeKind::Withdrawn {
			Selection::default()
		} else {
			origin.previews.retained_for(text)
		};
		let event = owner
			.activity
			.prepare_outgoing(source, &origin, text, change, files, None)?;
		Ok(Some(Self {
			update: Update {
				origin,
				existing: true,
				files: List::new(selected).ok_or_else(|| loam::refusal("outgoing file selection exceeds its bound"))?,
			},
			event: Some(event),
			confirmed: false,
			text: text.into(),
			change,
			destination: super::content::recording::destination(owner, &records::metadata(input)?)?,
			history,
			post: false,
			upload: false,
		}))
	}
	pub(super) fn upload(mut self) -> Self {
		self.upload = true;
		self
	}
	pub(super) fn reservation(&self) -> Update {
		self.update.clone()
	}
	/// Loam admission reserves presentation bytes. Its committed worker creates
	/// the file actors outside the content callback, before any remote dispatch.
	pub(super) fn prepare(&mut self) -> Result<()> {
		let event = self
			.event
			.as_mut()
			.ok_or_else(|| loam::refusal("outgoing event is already committed"))?;
		event.prepare_files()
	}
	pub(super) fn complete(&mut self, owner: &Rc<State<P>>, outcome: &mut Settlement) -> Result<Argument> {
		let Argument::List(parts) = &mut outcome.0 else {
			return Ok(Argument::Void);
		};
		let [data, fields] = parts.as_mut_slice() else {
			return Err(loam::refusal("invalid outgoing settlement"));
		};
		let event = self
			.event
			.as_ref()
			.ok_or_else(|| loam::refusal("outgoing event is already committed"))?;
		let history = owner.recording.borrow().as_ref().and_then(|sink| {
			sink.outgoing(
				event.event.origin.source(),
				super::recording::Outgoing {
					origin: &self.update.origin,
					history: &self.history,
					text: &self.text,
					change: self.change,
				},
				&event.event.files,
				self.destination.clone(),
			)
		});
		event.record(history.clone());
		if self.post && self.upload {
			let mut result: uploads::Outcome = serde_json::from_str(
				data.as_str()
					.ok_or_else(|| loam::refusal("outgoing upload data required"))?,
			)
			.map_err(|_| loam::refusal("invalid outgoing upload result"))?;
			result.id = Some(self.update.origin.id);
			result.history = history.and_then(rooms_application::content::session::results::History::from_coordinates);
			*data = serde_json::to_string(&result)
				.map_err(|_| loam::refusal("invalid outgoing upload result"))?
				.into();
			if fields.as_list().is_some_and(|fields| fields.is_empty()) {
				self.event.take();
				return Ok(Argument::Void);
			}
		} else if self.post {
			let mut result: rooms_application::content::session::results::PostedLine = serde_json::from_str(
				data.as_str()
					.ok_or_else(|| loam::refusal("outgoing result data required"))?,
			)
			.map_err(|_| loam::refusal("invalid outgoing line result"))?;
			result.id = Some(self.update.origin.id);
			result.history = history.and_then(rooms_application::content::session::results::History::from_coordinates);
			*data = serde_json::to_string(&result)
				.map_err(|_| loam::refusal("invalid outgoing line result"))?
				.into();
			if fields.as_list().is_some_and(|fields| fields.is_empty()) {
				self.event.take();
				return Ok(Argument::Void);
			}
		}
		self.confirmed = true;
		serde_json::to_string(&self.update)
			.map(Argument::String)
			.map_err(|_| loam::refusal("invalid outgoing provenance"))
	}
	/// Private settlement has committed line custody before a viewer accepts
	/// the occurrence. Taking the reservation publishes it only once.
	pub(super) fn publish(&mut self) {
		if self.confirmed
			&& let Some(event) = self.event.take()
		{
			event.publish();
		}
	}
}

/// Settlement copies actual saved edges. A coordinate in the private payload
/// cannot import authority or replace the initiating source of an existing line.
pub(super) fn adopt(
	record: &mut records::Record,
	id: &rooms_application::session::state::OperationId,
	value: &Argument,
) -> Result<()> {
	if matches!(value, Argument::Void) {
		return Ok(());
	}
	let update: Update = serde_json::from_str(
		value
			.as_str()
			.ok_or_else(|| loam::refusal("outgoing provenance required"))?,
	)
	.map_err(|_| loam::refusal("invalid outgoing provenance"))?;
	if record
		.effects
		.as_slice()
		.iter()
		.find(|receipt| &receipt.operation == id)
		.and_then(|receipt| receipt.outgoing.as_ref())
		!= Some(&update)
	{
		return Err(loam::refusal("original outgoing reservation required"));
	}
	let mut origin = update.origin;
	if update.existing {
		let Some(previous) = record
			.outgoing
			.as_mut_slice()
			.iter_mut()
			.find(|previous| previous.line == origin.line)
		else {
			// Explicit release wins over a late successful effect. Its receipt
			// still settles, without resurrecting the removed local line.
			return Ok(());
		};
		if previous.id != origin.id
			|| previous.generation != origin.generation
			|| previous.source != origin.source
			|| previous.route != origin.route
			|| previous.directory != origin.directory
			|| previous.conversation != origin.conversation
			|| previous.from != origin.from
		{
			return Err(loam::refusal("outgoing origin differs"));
		}
	} else if record
		.outgoing
		.as_slice()
		.iter()
		.any(|other| other.id == origin.id && other.generation == origin.generation)
	{
		return Ok(());
	}
	if !update.existing && !record.intent.conversations.as_slice().iter().any(|row|matches!(row,workspace::Conversation::Direct(row) if row.id==origin.conversation && row.directory==origin.directory && row.access==Some(origin.route))) {return Ok(());}
	let previous_files: Vec<_> = record
		.outgoing
		.as_slice()
		.iter()
		.find(|previous| previous.line == origin.line)
		.into_iter()
		.flat_map(|previous| previous.files.as_slice())
		.map(|file| coordinate(custody::Role::SourceBlob, file.source))
		.collect();
	let receipt = record
		.effects
		.as_slice()
		.iter()
		.find(|receipt| &receipt.operation == id)
		.ok_or_else(|| loam::refusal("outgoing receipt is absent"))?;
	let Outcome::Committed { retained, .. } = &receipt.outcome else {
		return Ok(());
	};
	let source = receipt.source.reference.clone();
	let submitted: Vec<_> = receipt
		.targets
		.as_slice()
		.iter()
		.filter(|target| target.borrowed().coordinate().role == custody::Role::SourceBlob)
		.map(|target| records::reference(&target.borrowed()).clone())
		.collect();
	let line = retained
		.as_slice()
		.iter()
		.find(|held| held.borrowed().coordinate().role == custody::Role::Line)
		.map(|held| records::reference(&held.borrowed()).clone());
	if !update.existing {
		let Some(line) = line else {
			return Ok(());
		};
		insert(record, custody::Role::Line, origin.line, line)?;
		insert(record, custody::Role::SessionAccess, origin.source, source)?;
	}
	for (file, selected) in origin.files.as_mut_slice().iter_mut().zip(update.files.as_slice()) {
		file.source = match selected {
			FileSource::Retained(key) => *key,
			FileSource::Submitted(index) => {
				insert(
					record,
					custody::Role::SourceBlob,
					file.source,
					submitted
						.get(*index)
						.ok_or_else(|| loam::refusal("submitted outgoing source is absent"))?
						.clone(),
				)?;
				file.source
			}
		};
	}
	if update.files.as_slice().len() != origin.files.as_slice().len() {
		return Err(loam::refusal("outgoing file provenance differs"));
	}
	if update.existing {
		let key = origin.line;
		*record
			.outgoing
			.as_mut_slice()
			.iter_mut()
			.find(|previous| previous.line == key)
			.ok_or_else(|| loam::refusal("original outgoing line is absent"))? = origin;
	} else {
		let direct = record
			.intent
			.conversations
			.as_mut_slice()
			.iter_mut()
			.find_map(|row| match row {
				workspace::Conversation::Direct(row) if row.id == origin.conversation => Some(row),
				_ => None,
			})
			.ok_or_else(|| loam::refusal("original outgoing conversation was removed"))?;
		direct
			.lines
			.try_push(workspace::PostedLine {
				id: origin.id,
				handle: origin.line,
			})
			.map_err(|_| loam::refusal("outgoing displayed line custody is full"))?;
		record
			.outgoing
			.try_push(origin)
			.map_err(|_| loam::refusal("outgoing provenance custody is full"))?;
	}
	rooms_application::content::session::outgoing::release_sources(record, &previous_files);
	Ok(())
}
fn insert<K>(record: &mut records::Record, role: custody::Role, key: FieldKey<K>, reference: Field) -> Result<()> {
	record
		.custody
		.insert(records::restored(coordinate(role, key), reference))
		.map_err(|_| loam::refusal("outgoing custody is full"))?;
	Ok(())
}
