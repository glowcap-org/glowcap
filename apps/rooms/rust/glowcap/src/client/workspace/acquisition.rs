//! One retained acquisition owns its exact source, candidate and capability
//! occurrences through refusal, cancellation and replay on either front.
use super::{Caller, Deadline, Error, Workspace};
use glowcap::{Argument, Ref, Result, loam};
use rooms_application::content::session::{custody, records, workspace::Intent};

/// A checked role and its actual held capability. The optional URI is an exact
/// persistence recipe. Live roles cannot acquire a durable recipe.
pub struct Import {
	pub coordinate: custody::Coordinate,
	pub reference: Ref,
	pub uri: Option<String>,
}
impl Import {
	pub fn into_arguments(self) -> Result<[Argument; 3]> {
		if self
			.uri
			.as_ref()
			.is_some_and(|uri| uri.len() > loam::ReferenceRequest::MAX_URI_BYTES)
			|| (self.coordinate.role.live() && self.uri.is_some())
		{
			return Err(loam::refusal("invalid custody recipe"));
		}
		Ok([
			coordinate(self.coordinate)?,
			self.reference.into(),
			self.uri.map_or(Argument::Void, Argument::String),
		])
	}
}

pub fn import_arguments(imports: Vec<Import>) -> Result<Argument> {
	if imports.len() > records::FIELDS_PER_PAGE {
		return Err(loam::refusal("import bundle exceeds one custody page"));
	}
	imports
		.into_iter()
		.map(|import| import.into_arguments().map(|fields| Argument::List(Vec::from(fields))))
		.collect::<Result<Vec<_>>>()
		.map(Argument::List)
}

/// Wire material shared with the trusted embedding's serialized writer. It
/// moves imported capabilities and URI strings into their final spines. The
/// bounded candidate serializes once and survives every submission. No newer
/// snapshot can replace either its intent or its expected revision.
pub struct AcquisitionRequest {
	arguments: [Argument; 4],
}
impl AcquisitionRequest {
	pub fn new(expected: u64, imports: Vec<Import>, releases: &[custody::Coordinate], intent: &Intent) -> Result<Self> {
		let imports = import_arguments(imports)?;
		let [expected, releases, intent] = candidate_arguments(expected, releases, intent)?;
		Ok(Self {
			arguments: [expected, imports, releases, intent],
		})
	}
	pub fn arguments(&self) -> &[Argument] {
		&self.arguments
	}
	/// Shared by direct consumers and the embedding's serialized writer.
	pub fn check_outcome(reply: Argument) -> std::result::Result<(), Error> {
		match reply {
			Argument::Void => Ok(()),
			Argument::String(status) if status == "conflict" => Err(Error::WorkspaceConflict),
			_ => Err(loam::refusal("invalid workspace acquisition outcome").into()),
		}
	}
}
pub(super) fn candidate_arguments(
	expected: u64,
	releases: &[custody::Coordinate],
	intent: &Intent,
) -> Result<[Argument; 3]> {
	if releases.len() > records::FIELDS_PER_PAGE {
		return Err(loam::refusal("release bundle exceeds one custody page"));
	}
	let expected = i64::try_from(expected).map_err(|_| loam::refusal("invalid workspace revision"))?;
	let releases = releases.iter().copied().map(coordinate).collect::<Result<Vec<_>>>()?;
	let mut encoded = BoundedIntent(Vec::new());
	serde_json::to_writer(&mut encoded, intent).map_err(|_| loam::refusal("workspace intent exceeds its profile"))?;
	let intent = String::from_utf8(encoded.0).map_err(|_| loam::refusal("invalid workspace intent"))?;
	Ok([expected.into(), Argument::List(releases), intent.into()])
}
struct BoundedIntent(Vec<u8>);
impl std::io::Write for BoundedIntent {
	fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
		if bytes.len() > custody::MAX_AUTHORITY_BYTES - self.0.len() {
			return Err(std::io::Error::other("workspace intent capacity"));
		}
		self.0.extend_from_slice(bytes);
		Ok(bytes.len())
	}
	fn flush(&mut self) -> std::io::Result<()> {
		Ok(())
	}
}
pub(super) fn coordinate(value: custody::Coordinate) -> Result<Argument> {
	serde_json::to_string(&value)
		.map(Argument::String)
		.map_err(|_| loam::refusal("invalid custody coordinate"))
}

pub struct Acquisition<D> {
	caller: Caller<D>,
	source: Ref,
	request: Vec<Argument>,
	method: &'static str,
}
impl<D: Deadline + Clone> Workspace<D> {
	/// Private retirement uses the same bounded candidate and grant checks.
	/// The witness grants scheduling access, never workspace permissions.
	pub fn prepare_owner_acquisition(&self, owner: &Ref, expected: u64, intent: &Intent) -> Result<Acquisition<D>> {
		let [base, imports, releases, intent] = AcquisitionRequest::new(expected, Vec::new(), &[], intent)?.arguments;
		Ok(Acquisition {
			caller: self.caller.clone(),
			source: self.reference.clone(),
			request: Vec::from([
				owner.clone().into(),
				rooms_application::content::session::continuing::Method::AcquireWorkspace
					.wire()
					.into(),
				base,
				imports,
				releases,
				intent,
			]),
			method: "continue-workspace",
		})
	}
	pub fn prepare_acquisition(
		&self,
		expected: u64,
		imports: Vec<Import>,
		releases: &[custody::Coordinate],
		intent: &Intent,
	) -> Result<Acquisition<D>> {
		Ok(Acquisition {
			caller: self.caller.clone(),
			source: self.reference.clone(),
			request: Vec::from(AcquisitionRequest::new(expected, imports, releases, intent)?.arguments),
			method: "acquire-workspace",
		})
	}
}
impl<D: Deadline> Acquisition<D> {
	pub(super) async fn snapshot_source(&self) -> std::result::Result<super::Snapshot, Error>
	where
		D: Clone,
	{
		super::Workspace {
			caller: self.caller.clone(),
			reference: self.source.clone(),
		}
		.snapshot()
		.await
	}
	/// A proved selection conflict can keep its exact source and import bundle
	/// while replacing only the rejected revision and composed workspace intent.
	/// The bounded import spines and URI strings copy once because both immutable
	/// candidates coexist until the replacement is admitted by the handle budget.
	/// Capability clones share custody. No endpoint is fetched or substituted.
	pub(super) fn recompose(&self, expected: u64, intent: &Intent) -> Result<Self>
	where
		D: Clone,
	{
		let [expected, releases, intent] = candidate_arguments(expected, &[], intent)?;
		Ok(Self {
			caller: self.caller.clone(),
			source: self.source.clone(),
			request: vec![expected, self.request[1].clone(), releases, intent],
			method: self.method,
		})
	}
	pub(super) fn mutation(caller: Caller<D>, source: Ref, request: Vec<Argument>) -> Self {
		Self {
			caller,
			source,
			request,
			method: "mutate",
		}
	}
	pub fn retained_bytes(&self) -> usize {
		size_of::<Self>().saturating_add(super::super::retained::arguments(&self.request))
	}
	pub fn source(&self) -> &Ref {
		&self.source
	}
	pub async fn submit(&self) -> std::result::Result<(), Error> {
		let reply = self
			.caller
			.call(
				&self.source,
				self.method,
				&self.request,
				"the workspace acquisition outcome is unknown; retain this request for replay",
			)
			.await?;
		AcquisitionRequest::check_outcome(reply)
	}
}
impl<D: Deadline + 'static> Acquisition<D> {
	/// Retain the actual admission receiver when an embedding lends a bounded
	/// wait to a socket or viewer. Interruption cannot replace this transaction.
	pub fn start_submission(&self) -> super::Submission<()> {
		let pending = self.caller.wait(&self.source, self.method, &self.request);
		super::Submission::new(async move { AcquisitionRequest::check_outcome(pending.await?) })
	}
}
