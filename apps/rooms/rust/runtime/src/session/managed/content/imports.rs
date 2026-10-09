//! Transfer exact committed result occurrences into one validated workspace.
use super::acquisition::{WorkspaceConflict, WorkspacePreparation};
use super::receipts::authenticate;
use super::*;
use custody::{Coordinate, Retained};
mod created;

struct Selection {
	result: Coordinate,
	destination: Coordinate,
}
struct Replacement<'a> {
	expected: u64,
	releases: Vec<Coordinate>,
	intent: &'a str,
	source: Option<Coordinate>,
}
/// Callback-local scalar selections and releases each occupy at most one
/// custody page. Legacy import holds one selection. Canonical command and
/// candidate bytes borrow the retained invocation; parsing copies no authority.
pub(super) struct Request<'a> {
	operation: rooms_application::session::state::OperationId,
	pub intent: &'a Argument,
	selections: Vec<Selection>,
	replacement: Option<Replacement<'a>>,
	created: bool,
}
fn coordinate(value: &Argument) -> Result<Coordinate> {
	Coordinate::decode(text(value)?).map_err(|_| refuse("invalid result coordinate"))
}
impl Selection {
	fn read(result: &Argument, destination: &Argument) -> Result<Self> {
		let result = coordinate(result)?;
		let destination = coordinate(destination)?;
		if result.role != destination.role {
			return Err(refuse("result import cannot change its checked role"));
		}
		Ok(Self { result, destination })
	}
}
impl<'a> Request<'a> {
	pub(super) fn parse(verb: &str, args: &'a [Argument]) -> Result<Self> {
		let (id, intent, selections, replacement) = match (verb, args) {
			("import-result", [id, intent, result, destination]) => {
				(id, intent, vec![Selection::read(result, destination)?], None)
			}
			(
				"acquire-result-workspace" | "acquire-created-room",
				[
					id,
					intent,
					expected,
					Argument::List(mappings),
					Argument::List(releases),
					candidate,
					source,
				],
			) => {
				let source = match source {
					Argument::Void => None,
					value => {
						let selected = coordinate(value)?;
						if selected.role != custody::Role::SessionAccess {
							return Err(refuse("worker source must retain session access"));
						}
						Some(selected)
					}
				};
				if mappings.len() > session::records::FIELDS_PER_PAGE
					|| releases.len() > session::records::FIELDS_PER_PAGE
				{
					return Err(refuse("result acquisition exceeds one custody page"));
				}
				let expected = expected
					.as_i64()
					.and_then(|value| u64::try_from(value).ok())
					.ok_or_else(|| refuse("invalid expected workspace revision"))?;
				let mut selections: Vec<Selection> = Vec::with_capacity(mappings.len());
				for mapping in mappings {
					let Some([result, destination]) = mapping.as_list() else {
						return Err(refuse("invalid result acquisition mapping"));
					};
					let selected = Selection::read(result, destination)?;
					if selections.iter().any(|prior| {
						prior.destination.role == selected.destination.role
							&& prior.destination.key.slot() == selected.destination.key.slot()
					}) {
						return Err(refuse("result acquisition repeats a custody slot"));
					}
					selections.push(selected);
				}
				let releases = releases.iter().map(coordinate).collect::<Result<Vec<_>>>()?;
				if source.is_some_and(|source| {
					releases.contains(&source)
						|| selections.iter().any(|selected| {
							selected.destination.role == source.role
								&& selected.destination.key.slot() == source.key.slot()
						})
				}) {
					return Err(refuse("worker source repeats or releases an acquisition slot"));
				}
				if releases
					.iter()
					.any(|release| selections.iter().any(|selected| selected.destination == *release))
				{
					return Err(refuse("result acquisition cannot release its destination"));
				}
				(
					id,
					intent,
					selections,
					Some(Replacement {
						expected,
						releases,
						intent: text(candidate)?,
						source,
					}),
				)
			}
			_ => return Err(refuse("invalid result acquisition request")),
		};
		Ok(Self {
			operation: operation(id)?,
			intent,
			selections,
			replacement,
			created: verb == "acquire-created-room",
		})
	}
	fn receipt<'r>(&self, record: &'r MetadataRecord) -> Result<&'r custody::EffectReceipt<records::Metadata>> {
		let intent = Text::new(text(self.intent)?.into()).ok_or_else(|| refuse("invalid original intent"))?;
		let receipt = effects::inspect(
			&record.effects,
			&self.operation,
			&location(record, &self.operation)?,
			&intent,
		)
		.map_err(|_| refuse("original source and intent required"))?
		.ok_or_else(|| refuse("unknown effect"))?;
		if !matches!(receipt.outcome, Outcome::Committed { .. }) {
			return Err(refuse("result is not committed"));
		}
		Ok(receipt)
	}
	fn prepare_workspace(&self, input: Invocation<'_>, record: &MetadataRecord) -> Result<WorkspacePreparation> {
		let Some(replacement) = &self.replacement else {
			return Ok(Ok(None));
		};
		if self.receipt(record)?.adopted {
			return Ok(Ok(None));
		}
		if self.created {
			return self.created_workspace(record).map(|intent| Ok(Some(intent)));
		}
		let intent = workspace::Intent::decode(replacement.intent).map_err(|_| refuse("invalid workspace intent"))?;
		for selection in &self.selections {
			if selection.destination.role == custody::Role::DirectAccess {
				let original = original_text(text(self.intent)?)?;
				let [_, _, route, directory, peer, _registration, _opening] = original.as_slice() else {
					return Err(refuse("direct acquisition requires its original introduction"));
				};
				let row = intent
					.conversations
					.as_slice()
					.iter()
					.find_map(|row| match row {
						workspace::Conversation::Direct(row)
							if row.access.is_some_and(|key| {
								key.slot() == selection.destination.key.slot()
									&& key.generation() == selection.destination.key.generation()
							}) =>
						{
							Some(row.as_ref())
						}
						_ => None,
					})
					.ok_or_else(|| refuse("acquired direct route must select its exact custody"))?;
				if text(route)? != "startDirect"
					|| row.directory.text().as_str() != Some(text(directory)?)
					|| row.peer.text().as_str() != Some(text(peer)?)
					|| row.introduction != self.receipt(record)?.introduction
				{
					return Err(refuse("direct contact differs from its original introduction"));
				}
				continue;
			}
			if selection.destination.role == custody::Role::PublicationLease {
				let original = original_text(text(self.intent)?)?;
				let [id, _, route, directory, name, room, _publisher] = original.as_slice() else {
					return Err(refuse("publication acquisition requires its original request"));
				};
				let room: custody::FieldKey<custody::RoomAccess> =
					serde_json::from_str(text(room)?).map_err(|_| refuse("invalid original publication room"))?;
				let row = intent
					.peering
					.as_slice()
					.iter()
					.find(|row| {
						row.lease.slot() == selection.destination.key.slot()
							&& row.lease.generation() == selection.destination.key.generation()
					})
					.ok_or_else(|| refuse("acquired publication must select its exact lease"))?;
				if text(route)? != "publishPeeredRoom"
					|| row.id.text().as_str() != Some(text(id)?)
					|| row.id.text() != self.operation.text()
					|| row.directory.text().as_str() != Some(text(directory)?)
					|| row.name.text().as_str() != Some(text(name)?)
					|| row.room != room
				{
					return Err(refuse("publication selection differs from its original request"));
				}
				continue;
			}
			if selection.destination.role != custody::Role::IrcConnection {
				continue;
			}
			let original = original_text(text(self.intent)?)?;
			let [id, _, route, gateway, kind, verb, connection] = original.as_slice() else {
				return Err(refuse("connection acquisition requires its original gateway request"));
			};
			let row = intent
				.operations
				.as_slice()
				.iter()
				.find(|row| row.handle == selection.destination)
				.ok_or_else(|| refuse("acquired connection must select its exact custody"))?;
			let metadata = row
				.connection
				.as_ref()
				.ok_or_else(|| refuse("connection acquisition requires original request metadata"))?;
			if text(route)? != "operations"
				|| text(kind)? != "ircGateway"
				|| text(verb)? != "connection"
				|| row.kind != rooms_application::session::operations::mutation::Kind::IrcConnection
				|| metadata.operation != self.operation
				|| metadata.operation.text().as_str() != Some(text(id)?)
				|| metadata.gateway != coordinate(gateway)?
				|| metadata.id.text().as_str() != Some(text(connection)?)
			{
				return Err(refuse("connection selection differs from its original gateway request"));
			}
		}
		if replacement.expected != input.content_revision
			&& (intent != record.intent
				|| self
					.selections
					.iter()
					.any(|selection| record.custody.get(selection.destination).is_none())
				|| replacement
					.source
					.is_some_and(|source| record.custody.get(source).is_none())
				|| replacement
					.releases
					.iter()
					.any(|release| record.custody.get(*release).is_some()))
		{
			return Ok(Err(WorkspaceConflict));
		}
		Ok(Ok(Some(intent)))
	}
}
fn selected<'r>(
	receipt: &'r custody::EffectReceipt<records::Metadata>,
	coordinate: Coordinate,
) -> Result<Retained<'r, records::Metadata>> {
	let Outcome::Committed { retained, .. } = &receipt.outcome else {
		unreachable!("validated receipt")
	};
	retained
		.as_slice()
		.iter()
		.find(|field| field.borrowed().coordinate() == coordinate)
		.map(|field| field.borrowed())
		.ok_or_else(|| refuse("result coordinate is absent"))
}
pub(super) fn references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	let request = Request::parse(input.verb, input.args)?;
	let preparation = request.prepare_workspace(input, record)?;
	let receipt = request.receipt(record)?;
	if matches!(preparation, Err(WorkspaceConflict)) || (request.replacement.is_some() && receipt.adopted) {
		return Ok(vec![restore_source(receipt)?]);
	}
	// A bounded declaration spine restores only selected results, occupied
	// destinations and the original source. No result capability is resaved.
	let mut requests = Vec::with_capacity(2 + request.selections.len() * 2);
	requests.push(restore_source(receipt)?);
	if request.created {
		for field in request.created_directory(record)? {
			let location = records::location(&field);
			requests.push(ReferenceRequest::RestorePage {
				page: location
					.page
					.checked_sub(1)
					.ok_or_else(|| refuse("invalid directory page"))?,
				field: location.field,
			});
		}
	}
	if let Some(existing) = request
		.replacement
		.as_ref()
		.and_then(|replacement| replacement.source)
		.and_then(|source| record.custody.get(source))
	{
		let location = records::location(&existing);
		requests.push(ReferenceRequest::RestorePage {
			page: location
				.page
				.checked_sub(1)
				.ok_or_else(|| refuse("invalid source page"))?,
			field: location.field,
		});
	}
	for selection in &request.selections {
		let field = selected(receipt, selection.result)?;
		for location in core::iter::once(records::location(&field)).chain(
			record
				.custody
				.get(selection.destination)
				.map(|field| records::location(&field)),
		) {
			requests.push(ReferenceRequest::RestorePage {
				page: location
					.page
					.checked_sub(1)
					.ok_or_else(|| refuse("invalid result page"))?,
				field: location.field,
			});
		}
	}
	Ok(requests)
}
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	let request = Request::parse(input.verb, input.args)?;
	let metadata = records::metadata(input)?;
	let source = call.source()?;
	authenticate(call, input, &metadata, &request.operation, &source)?;
	if request.replacement.is_some() && request.receipt(&metadata)?.adopted {
		return Ok(Argument::Void);
	}
	if request.created {
		let [original, current] = request.created_directory(&metadata)?;
		if Field::Retained(records::location(&original)).resolve(call, input)?
			!= Field::Retained(records::location(&current)).resolve(call, input)?
		{
			return Err(refuse("creation directory authority was replaced"));
		}
	}
	let replacement = request.prepare_workspace(input, &metadata)?;
	if matches!(replacement, Err(WorkspaceConflict)) {
		return Ok("conflict".into());
	}
	let receipt = request.receipt(&metadata)?;
	let mut record = records::decode(input)?;
	let mut changed = false;
	if let Some(replacement) = &request.replacement {
		for release in &replacement.releases {
			changed |= record.custody.remove(*release).is_some();
		}
	}
	for selection in &request.selections {
		let field = Field::Retained(records::location(&selected(receipt, selection.result)?));
		let actual = field.resolve(call, input)?;
		if let Some(existing) = record.custody.get(selection.destination) {
			if records::reference(&existing).resolve(call, input)? != actual {
				return Err(refuse("custody coordinate already holds different authority"));
			}
		} else {
			// Copy the exact saved edge into the candidate graph. The original
			// receipt keeps its occurrence and the session dependency is preserved.
			record
				.custody
				.insert(records::restored(selection.destination, field))
				.map_err(|_| refuse("duplicate or full custody"))?;
			changed = true;
		}
	}
	if let Some(destination) = request.replacement.as_ref().and_then(|replacement| replacement.source) {
		let field = Field::Retained(receipt.source.reference);
		if let Some(existing) = record.custody.get(destination) {
			if records::reference(&existing).resolve(call, input)? != source {
				return Err(refuse("worker source slot holds different authority"));
			}
		} else {
			record
				.custody
				.insert(records::restored(destination, field))
				.map_err(|_| refuse("duplicate or full source custody"))?;
			changed = true;
		}
	}
	if let Ok(Some(intent)) = replacement {
		record
			.intent
			.replace_configuration_retiring(intent, &mut record.custody)
			.map_err(|_| refuse("change history retention through its dedicated command"))?;
		record
			.intent
			.validate(&record.custody)
			.map_err(|_| refuse("workspace refers to missing custody"))?;
		let receipt = record
			.effects
			.as_mut_slice()
			.iter_mut()
			.find(|receipt| receipt.operation == request.operation)
			.ok_or_else(|| refuse("original effect disappeared"))?;
		receipt.adopted = true;
		changed = true;
	}
	if changed {
		records::replace(call, input, &mut record)?;
	}
	Ok(Argument::Void)
}
