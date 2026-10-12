//! Boot credentials are transient acquisition input. Loam saves exact custody.
use super::{Import, Session, custody};
use glowcap::{CaptpVersion, Ref, Result, loam, parse_sturdyref};
use rooms_application::{
	content::session::workspace::{self, Intent},
	fields::List,
	server::operations::bundle::Draft,
	session::operations::mutation::Kind,
};
use rooms_glowcap::client::{Deadline, Tasks};
use std::num::NonZeroU64;

/// Exact credential recipes, independent of the selected directory route.
pub struct OperationsBundle<'a> {
	pub draft: &'a Draft,
	pub first: custody::FieldKey<()>,
}

impl<P: Tasks + Deadline + Clone + 'static> Session<P> {
	/// Fetch only the pasted credential set through its actual exporter, then atomically replace the selected bundle. No bearer text
	/// enters workspace intent, and partial acquisition cannot change selection.
	/// The embedding supplies fresh data coordinates for this stable attempt.
	/// Replay keeps them, its expected revision, and its original snapshot.
	/// Boot credentials independently authorize lookup. The supplied session
	/// source must still admit custody and workspace replacement at commit.
	/// Preparation owns at most the boot inventory's six bounded URI strings
	/// and one coordinate spine across fetches. Strings move into Imports. No
	/// copied credential map survives commit. The old intent clone is the bounded
	/// transaction candidate. A release spine holds at most its selected fields.
	pub async fn acquire_operations(
		&self,
		source: &Ref,
		expected: u64,
		intent: &Intent,
		bundle: OperationsBundle<'_>,
	) -> Result<Intent> {
		let OperationsBundle { draft, first } = bundle;
		if !draft.is_empty() && !draft.ready() {
			return Err(loam::refusal("operations credentials are incomplete"));
		}
		i64::try_from(expected).map_err(|_| loam::refusal("invalid workspace revision"))?;
		let mut next = intent.clone();
		let count = draft.entries().count();
		let operator_count = usize::from(draft.entries().any(|(name, _)| name == "operator"));
		let mut prepared = Vec::with_capacity(count);
		let mut operators = Vec::with_capacity(operator_count);
		let mut operations = Vec::with_capacity(count - operator_count);
		for (index, (name, uri)) in draft.entries().enumerate() {
			let slot = first
				.slot()
				.get()
				.checked_add(index as u64)
				.and_then(NonZeroU64::new)
				.ok_or_else(|| loam::refusal("custody coordinate exhausted"))?;
			let key = custody::FieldKey::new(slot, first.generation());
			let coordinate = custody::Coordinate {
				role: if name == "operator" {
					custody::Role::Operator
				} else {
					custody::Role::Operations
				},
				key,
			};
			let kind = match name {
				"operator" => None,
				"listeners" => Some(Kind::Listeners),
				"diagnostics" => Some(Kind::Diagnostics),
				"irc" => Some(Kind::IrcGateway),
				"peering" => Some(Kind::Peering),
				"trace" => Some(Kind::Trace),
				_ => return Err(loam::refusal("unknown operations capability")),
			};
			parse_sturdyref(uri, CaptpVersion::V1_0)?;
			if uri.len() > loam::ReferenceRequest::MAX_URI_BYTES {
				return Err(loam::refusal("operations recipe exceeds its limit"));
			}
			prepared.push((coordinate, uri.to_owned()));
			match kind {
				None => operators.push(custody::FieldKey::new(slot, first.generation())),
				Some(kind) => operations.push(workspace::Operations {
					connection: None,
					kind,
					handle: coordinate,
				}),
			}
		}
		next.operators = List::new(operators).ok_or_else(|| loam::refusal("too many operator selections"))?;
		next.operations = List::new(operations).ok_or_else(|| loam::refusal("too many operations selections"))?;
		let releases: Vec<_> = intent
			.operators
			.as_slice()
			.iter()
			.map(|key| custody::Coordinate {
				role: custody::Role::Operator,
				key: custody::FieldKey::new(key.slot(), key.generation()),
			})
			.chain(intent.operations.as_slice().iter().map(|row| row.handle))
			.filter(|coordinate| !next.coordinates().any(|selected| selected == *coordinate))
			.collect();
		if releases.len() > rooms_application::content::session::records::FIELDS_PER_PAGE {
			return Err(loam::refusal("release bundle exceeds one custody page"));
		}
		// Validate the entire scalar request before any remote lookup. The
		// Host resolves each recipe at its own exporter, independently of display scope.
		let mut imports = Vec::with_capacity(count);
		for (coordinate, uri) in prepared {
			let reference = self
				.state
				.platform
				.within(
					rooms_application::room::authority::REQUEST_TIMEOUT_MS,
					self.state.writer.host.enliven(&uri),
				)
				.await
				.ok_or_else(|| loam::refusal("operations acquisition did not answer"))??;
			imports.push(Import {
				coordinate,
				reference,
				uri: Some(uri),
			});
		}
		self.acquire_workspace(source, expected, imports, &releases, &next)
			.await?;
		Ok(next)
	}
}
