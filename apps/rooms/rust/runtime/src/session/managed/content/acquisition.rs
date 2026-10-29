//! Single and bundle imports share exact custody comparison and one graph commit.
use super::*;

/// The inner refusal proves absence of a commit. The outer operational Result
/// reports malformed input or unavailable content. Intent stays owned inline.
pub(super) type WorkspacePreparation = std::result::Result<Option<workspace::Intent>, WorkspaceConflict>;
pub(super) struct WorkspaceConflict;

struct Entry<'a> {
	coordinate: custody::Coordinate,
	reference: &'a Ref,
	uri: Option<&'a str>,
}
impl<'a> Entry<'a> {
	/// Handed room and archive authority has no recipe. Its live facet retains
	/// the original session source, so a later holder cannot bypass that source.
	fn dependent_source<'s>(&self, source: Option<&'s Ref>) -> Option<&'s Ref> {
		source.filter(|_| {
			matches!(
				self.coordinate.role,
				custody::Role::RoomAccess | custody::Role::ArchiveAccess
			) && self.uri.is_none()
		})
	}
	fn read(args: &'a [Argument]) -> Result<Self> {
		let [coordinate, Argument::Reference(reference), uri] = args else {
			return Err(refuse(
				"an import takes coordinate, held capability and optional sturdy URI",
			));
		};
		let coordinate =
			custody::Coordinate::decode(text(coordinate)?).map_err(|_| refuse("invalid custody coordinate"))?;
		let uri = match uri {
			Argument::Void => None,
			Argument::String(uri) if uri.len() <= ReferenceRequest::MAX_URI_BYTES => Some(uri.as_str()),
			_ => return Err(refuse("invalid or oversized sturdy URI")),
		};
		if coordinate.role.live() && uri.is_some() {
			return Err(refuse("live custody takes no sturdy URI"));
		}
		Ok(Self {
			coordinate,
			reference,
			uri,
		})
	}
	fn save(&self) -> ReferenceRequest {
		if self.coordinate.role.live() {
			ReferenceRequest::SaveLive(self.reference.clone())
		} else {
			ReferenceRequest::Save {
				reference: self.reference.clone(),
				uri: self.uri.map(str::to_owned),
			}
		}
	}
}

enum Request<'a> {
	Single(Entry<'a>),
	Bundle(Vec<Entry<'a>>),
	Workspace {
		expected: u64,
		entries: Vec<Entry<'a>>,
		releases: Vec<custody::Coordinate>,
		intent: &'a str,
	},
}
impl<'a> Request<'a> {
	/// A bulk ingress admits one codec page's field population. Its temporary
	/// spine borrows capability and URI occurrences from Call input, and dies at
	/// callback return. Shared preparation owns every retain across storage waits.
	/// No runtime authority map or copied URI inventory survives the callback.
	fn read(input: Invocation<'a>) -> Result<Self> {
		if input.verb == "import" {
			return Entry::read(input.args).map(Self::Single);
		}
		let (entries, replacement) = match (input.verb, input.args) {
			("import-bundle", [Argument::List(entries)]) => (entries, None),
			(
				"acquire-workspace",
				[
					Argument::Integer(expected),
					Argument::List(entries),
					Argument::List(releases),
					intent,
				],
			) => {
				let expected = u64::try_from(*expected).map_err(|_| refuse("invalid expected workspace revision"))?;
				let intent = text(intent)?;
				if releases.len() > session::records::FIELDS_PER_PAGE {
					return Err(refuse("release bundle exceeds one custody page"));
				}
				let releases = releases
					.iter()
					.map(|value| {
						custody::Coordinate::decode(text(value)?).map_err(|_| refuse("invalid release coordinate"))
					})
					.collect::<Result<Vec<_>>>()?;
				(entries, Some((expected, releases, intent)))
			}
			_ => return Err(refuse("invalid custody acquisition request")),
		};
		if entries.len() > session::records::FIELDS_PER_PAGE {
			return Err(refuse("import bundle exceeds one custody page"));
		}
		let mut parsed: Vec<Entry<'a>> = Vec::with_capacity(entries.len());
		for entry in entries {
			let Argument::List(fields) = entry else {
				return Err(refuse("invalid import bundle entry"));
			};
			let entry = Entry::read(fields)?;
			if parsed.iter().any(|prior| {
				prior.coordinate.role == entry.coordinate.role
					&& prior.coordinate.key.slot() == entry.coordinate.key.slot()
			}) {
				return Err(refuse("import bundle repeats a custody slot"));
			}
			parsed.push(entry);
		}
		Ok(match replacement {
			None => Self::Bundle(parsed),
			Some((expected, releases, intent)) => {
				if releases
					.iter()
					.any(|release| parsed.iter().any(|entry| entry.coordinate == *release))
				{
					return Err(refuse("an acquisition cannot release an imported field"));
				}
				Self::Workspace {
					expected,
					entries: parsed,
					releases,
					intent,
				}
			}
		})
	}
	fn entries(&self) -> &[Entry<'a>] {
		match self {
			Self::Single(entry) => std::slice::from_ref(entry),
			Self::Bundle(entries) | Self::Workspace { entries, .. } => entries,
		}
	}
	/// Keep serialized intent borrowed in the ingress union. Only workspace
	/// admission decodes a candidate. Single imports decode no workspace.
	/// Neither path adds heap indirection. Preparation and invocation call this
	/// before requesting saves or changing custody.
	fn prepare_workspace<R: custody::References, C>(
		&self,
		input: Invocation<'_>,
		record: &workspace::Record<R, C>,
	) -> Result<WorkspacePreparation> {
		if let Self::Workspace {
			expected,
			intent,
			releases,
			..
		} = self
		{
			let intent = workspace::Intent::decode(intent).map_err(|_| refuse("invalid workspace intent"))?;
			// A request prepared before the last intent change is stale. Only an
			// exact replay of it recovers: it cannot install new fields or
			// replace the intervening intent.
			if !record.fence.admits(*expected, input.content_revision)
				&& (intent != record.intent
					|| self
						.entries()
						.iter()
						.any(|entry| record.custody.get(entry.coordinate).is_none())
					|| releases
						.iter()
						.any(|coordinate| record.custody.get(*coordinate).is_some()))
			{
				return Ok(Err(WorkspaceConflict));
			}
			return Ok(Ok(Some(intent)));
		}
		Ok(Ok(None))
	}
}

pub(super) fn references(input: Invocation<'_>, record: &MetadataRecord) -> Result<Vec<ReferenceRequest>> {
	references_from(input, record, None)
}
pub(super) fn references_from(
	input: Invocation<'_>,
	record: &MetadataRecord,
	source: Option<&Ref>,
) -> Result<Vec<ReferenceRequest>> {
	let request = Request::read(input)?;
	if matches!(request.prepare_workspace(input, record)?, Err(WorkspaceConflict)) {
		return Ok(Vec::new());
	}
	let mut references = Vec::with_capacity(request.entries().len() * 2);
	for entry in request.entries() {
		if let Some(held) = record.custody.get(entry.coordinate) {
			let location = records::location(&held);
			references.push(ReferenceRequest::RestorePage {
				page: location
					.page
					.checked_sub(1)
					.ok_or_else(|| refuse("invalid custody page"))?,
				field: location.field,
			});
		}
		references.push(match entry.dependent_source(source) {
			Some(source) => ReferenceRequest::SaveLiveDependent {
				source: source.clone(),
				target: entry.reference.clone(),
			},
			None => entry.save(),
		});
	}
	Ok(references)
}

pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
	invoke_from(call, input, None)
}
pub(super) fn invoke_from(call: &mut Call<'_>, input: Invocation<'_>, source: Option<&Ref>) -> Result<Argument> {
	let request = Request::read(input)?;
	let mut record = records::decode(input)?;
	let replacement = request.prepare_workspace(input, &record)?;
	if matches!(replacement, Err(WorkspaceConflict)) {
		return Ok("conflict".into());
	}
	let mut changed = false;
	if let Request::Workspace { releases, .. } = &request {
		for coordinate in releases {
			changed |= record.custody.remove(*coordinate).is_some();
		}
	}
	for entry in request.entries() {
		let source = entry.dependent_source(source);
		if let Some(existing) = record.custody.get(entry.coordinate) {
			let existing = records::reference(&existing).resolve(call, input)?;
			let matches = match source {
				Some(source) => call.matches_live_dependent(&existing, source, entry.reference)?,
				None => existing == *entry.reference,
			};
			if !matches {
				return Err(refuse("custody coordinate already holds different authority"));
			}
		} else {
			let reference = match source {
				Some(source) => call.prepared_live_dependent(source, entry.reference)?,
				None => entry.reference.clone(),
			};
			record
				.custody
				.insert(records::restored(entry.coordinate, Field::Held(reference)))
				.map_err(|_| refuse("duplicate or full custody"))?;
			changed = true;
		}
	}
	if let Ok(Some(intent)) = replacement {
		changed |= record.intent != intent;
		record
			.intent
			.replace_configuration_retiring(intent, &mut record.custody)
			.map_err(|_| refuse("change history retention through its dedicated command"))?;
		record
			.intent
			.validate(&record.custody)
			.map_err(|_| refuse("workspace refers to missing custody"))?;
	}
	if changed {
		records::replace(call, input, &mut record)?;
	}
	Ok(Argument::Void)
}
