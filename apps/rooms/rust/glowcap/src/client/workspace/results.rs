//! Acquisition keeps the command's original source and committed result keys.
//! Its candidate selects those exact occurrences in one workspace transaction.
use super::acquisition::{candidate_arguments, coordinate};
use super::{Caller, Command, Deadline, EffectStatus, Error};
use glowcap::{Argument, Result, loam};
use rooms_application::content::session::{custody, records, workspace::Intent};
use std::rc::Rc;

/// Preserve the receipt's diagnostic after the C callback boundary, which
/// carries only an application refusal code. Move the received reason into
/// the error. No secondary diagnostic string or capability lookup is needed.
pub(super) fn observed(value: Argument) -> core::result::Result<Argument, Error> {
	match value {
		Argument::List(mut values)
			if matches!(values.first().and_then(Argument::as_str), Some("unknown" | "refused")) =>
		{
			if !matches!(values.as_slice(), [Argument::String(_), Argument::String(reason)] if rooms_application::fields::Text::<{ custody::MAX_OBSERVATION_REASON_UNITS }, true>::accepts_utf16(reason.encode_utf16()))
			{
				return Err(loam::refusal("invalid terminal observation diagnostic").into());
			}
			let refused = values[0].as_str() == Some("refused");
			let Some(Argument::String(reason)) = values.pop() else {
				return Err(loam::refusal("invalid terminal observation diagnostic").into());
			};
			Err(if refused {
				Error::RefusedObservation(reason)
			} else {
				Error::Observation(reason)
			})
		}
		value => Ok(value),
	}
}

#[derive(Clone, Copy)]
pub struct ResultImport {
	pub result: custody::Coordinate,
	pub destination: custody::Coordinate,
}

pub(super) async fn receive<D: Deadline>(
	caller: &Caller<D>,
	source: &glowcap::Ref,
	operation: &str,
	canonical: &str,
) -> core::result::Result<EffectStatus, Error> {
	let value = caller
		.call(
			source,
			"effect-reader",
			&[operation.into(), canonical.into()],
			"the original receipt observer did not answer",
		)
		.await?;
	let reader = glowcap::Ref::try_from(&value).map_err(|_| loam::refusal("effect observer capability required"))?;
	EffectStatus::read(
		&caller
			.wait(&reader, "read", &[operation.into(), source.clone().into()])
			.await?,
	)
}

/// Seven fixed arguments plus bounded mapping/release spines. Original operation
/// and canonical intent copy once from Command. Candidate encoding has the same
/// aggregate limit as ordinary acquisition. Capability results stay in Loam.
/// This request contains only their exact typed coordinates.
#[derive(Clone)]
pub struct ResultAcquisition<D> {
	caller: Caller<D>,
	source: glowcap::Ref,
	arguments: Rc<[Argument; 7]>,
	method: &'static str,
}
impl<D: Deadline + Clone> Command<D> {
	pub fn prepare_result_acquisition(
		&self,
		expected: u64,
		imports: &[ResultImport],
		releases: &[custody::Coordinate],
		intent: &Intent,
	) -> Result<ResultAcquisition<D>> {
		self.prepare_result_acquisition_with_source(expected, imports, releases, intent, None)
	}
	/// Save the exact initiating endpoint beside its result fields and worker
	/// intent. The server copies the receipt's saved edge, without restoring a
	/// private root or trusting caller-provided source descriptions.
	pub fn prepare_result_acquisition_with_source(
		&self,
		expected: u64,
		imports: &[ResultImport],
		releases: &[custody::Coordinate],
		intent: &Intent,
		source: Option<custody::FieldKey<custody::SessionAccess>>,
	) -> Result<ResultAcquisition<D>> {
		prepare(
			Witness {
				caller: &self.caller,
				source: &self.source,
				operation: &self.operation,
				canonical: &self.canonical,
			},
			expected,
			imports,
			releases,
			intent,
			source,
		)
	}
}
pub(super) struct Witness<'a, D> {
	pub caller: &'a Caller<D>,
	pub source: &'a glowcap::Ref,
	pub operation: &'a str,
	pub canonical: &'a str,
}
pub(super) fn prepare<D: Deadline + Clone>(
	witness: Witness<'_, D>,
	expected: u64,
	imports: &[ResultImport],
	releases: &[custody::Coordinate],
	intent: &Intent,
	source: Option<custody::FieldKey<custody::SessionAccess>>,
) -> Result<ResultAcquisition<D>> {
	if imports.len() > records::FIELDS_PER_PAGE {
		return Err(loam::refusal("result acquisition exceeds one custody page"));
	}
	let mappings = imports
		.iter()
		.map(|entry| {
			if entry.result.role != entry.destination.role {
				return Err(loam::refusal("result acquisition cannot change its checked role"));
			}
			Ok(Argument::List(vec![
				coordinate(entry.result)?,
				coordinate(entry.destination)?,
			]))
		})
		.collect::<Result<Vec<_>>>()?;
	let [expected, releases, candidate] = candidate_arguments(expected, releases, intent)?;
	let source = source.map_or(Ok(Argument::Void), |key| {
		coordinate(custody::Coordinate {
			role: custody::Role::SessionAccess,
			key: custody::FieldKey::new(key.slot(), key.generation()),
		})
	})?;
	Ok(ResultAcquisition {
		caller: witness.caller.clone(),
		source: witness.source.clone(),
		method: "acquire-result-workspace",
		arguments: Rc::new([
			witness.operation.to_owned().into(),
			witness.canonical.to_owned().into(),
			expected,
			Argument::List(mappings),
			releases,
			candidate,
			source,
		]),
	})
}
impl<D: Deadline + Clone> ResultAcquisition<D> {
	/// Creation adopts only its returned room. Unrelated workspace changes cannot
	/// invalidate an append. The transaction checks the receipt's exact directory
	/// target instead. Keep one bounded room recipe, not the caller's snapshot.
	pub fn created_room(mut self) -> Result<Self> {
		let mut intent = Intent::decode(self.arguments[5].as_str().unwrap_or(""))
			.map_err(|_| loam::refusal("invalid creation candidate"))?;
		let operation = self.arguments[0].as_str().unwrap_or("");
		let position = intent
			.conversations
			.as_slice()
			.iter()
			.position(|row| row.id().text().as_str() == Some(operation))
			.ok_or_else(|| loam::refusal("missing created room selection"))?;
		let room = intent.conversations.as_mut_slice()[position].clone();
		let mut selected = Intent::empty();
		selected
			.conversations
			.try_push(room)
			.map_err(|_| loam::refusal("invalid creation selection"))?;
		let [expected, releases, candidate] = candidate_arguments(0, &[], &selected)?;
		let arguments = Rc::get_mut(&mut self.arguments)
			.ok_or_else(|| loam::refusal("creation must be selected before sharing its request"))?;
		if !arguments[4].as_list().is_some_and(|releases| releases.is_empty()) {
			return Err(loam::refusal("creation cannot release existing custody"));
		}
		arguments[2] = expected;
		arguments[4] = releases;
		arguments[5] = candidate;
		self.method = "acquire-created-room";
		Ok(self)
	}
	pub fn retained_bytes(&self) -> usize {
		size_of::<Self>()
			.saturating_add(size_of::<[Argument; 7]>() + 2 * size_of::<usize>())
			.saturating_add(super::super::retained::arguments(self.arguments.as_slice()))
	}
	pub async fn submit(&self) -> std::result::Result<(), Error> {
		self.validate_room_roles().await?;
		let reply = self
			.caller
			.call(
				&self.source,
				self.method,
				self.arguments.as_slice(),
				"the result acquisition outcome is unknown; retain this request for replay",
			)
			.await?;
		super::acquisition::AcquisitionRequest::check_outcome(reply)
	}
	async fn validate_room_roles(&self) -> std::result::Result<(), Error> {
		let mappings = self.arguments[3]
			.as_list()
			.ok_or_else(|| loam::refusal("invalid result mappings"))?;
		let mut selections = Vec::new();
		for mapping in mappings {
			let Some([result, destination]) = mapping.as_list() else {
				return Err(loam::refusal("invalid result mapping").into());
			};
			let decode = |value: &Argument| {
				custody::Coordinate::decode(value.as_str().unwrap_or(""))
					.map_err(|_| loam::refusal("invalid result coordinate"))
			};
			let destination = decode(destination)?;
			if matches!(destination.role, custody::Role::RoomAccess | custody::Role::RoomControl) {
				selections.push((decode(result)?, destination));
			}
		}
		if selections.is_empty() {
			return Ok(());
		}
		let intent = Intent::decode(
			self.arguments[5]
				.as_str()
				.ok_or_else(|| loam::refusal("invalid result candidate"))?,
		)
		.map_err(|_| loam::refusal("invalid result candidate"))?;
		let needs_validation = intent.conversations.as_slice().iter().any(|row| {
			let rooms_application::content::session::workspace::Conversation::Room(room) = row else {
				return false;
			};
			selections.iter().any(|(_, destination)| {
				let matches = |key: custody::FieldKey<_>| {
					key.slot() == destination.key.slot() && key.generation() == destination.key.generation()
				};
				(destination.role == custody::Role::RoomControl && room.control.is_some_and(matches))
					|| (destination.role == custody::Role::RoomAccess
						&& room.moderator.is_some_and(|key| {
							key.slot() == destination.key.slot() && key.generation() == destination.key.generation()
						}))
			})
		});
		if !needs_validation {
			return Ok(());
		}
		let adopted = self
			.caller
			.call(
				&self.source,
				"effect-adopted",
				&[self.arguments[0].clone()],
				"the original adoption did not answer",
			)
			.await?;
		if adopted == Argument::Boolean(true) {
			return Ok(());
		}
		let reply = self
			.caller
			.call(
				&self.source,
				"effect-result",
				&self.arguments[..2],
				"the original room authority did not answer",
			)
			.await?;
		let Some([_, fields]) = reply.as_list() else {
			return Err(loam::refusal("missing retained room authority").into());
		};
		let fields = fields
			.as_list()
			.ok_or_else(|| loam::refusal("invalid retained room authority"))?;
		let mut imports = Vec::with_capacity(selections.len());
		for (result, destination) in selections {
			for field in fields {
				let Some([coordinate, reference]) = field.as_list() else {
					return Err(loam::refusal("invalid retained result field").into());
				};
				let coordinate = custody::Coordinate::decode(coordinate.as_str().unwrap_or(""))
					.map_err(|_| loam::refusal("invalid retained result coordinate"))?;
				if coordinate == result {
					imports.push(super::Import {
						coordinate: destination,
						reference: glowcap::Ref::try_from(reference)
							.map_err(|_| loam::refusal("missing retained capability"))?,
						uri: None,
					});
				}
			}
		}
		super::Workspace {
			caller: self.caller.clone(),
			reference: self.source.clone(),
		}
		.validate_room_authority_imports(&imports, &intent)
		.await
	}
}
impl<D: Deadline + Clone + 'static> ResultAcquisition<D> {
	pub fn start_submission(&self) -> super::Submission<()> {
		let request = self.clone();
		super::Submission::new(async move { request.submit().await })
	}
}
