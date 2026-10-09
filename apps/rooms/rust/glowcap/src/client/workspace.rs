//! Typed use of one exact managed session. Controls remain separate custody.
use super::Caller;
use super::{Client, Deadline, Error};
use glowcap::{Argument, Ref, loam};
use rooms_application::{
	content::session::{
		custody, requirements,
		workspace::{self, Intent},
	},
	session::command::Request,
};
mod acquisition;
mod activity;
mod authority;
pub use activity::ActivityReader;
mod bridge;
mod directories;
mod discovery;
mod inspection;
pub use inspection::OperationsReader;
mod operations;
mod presence;
pub use operations::{OperationsAcquisition, OperationsSelection};
mod recovery;
mod rooms;
pub use recovery::{EffectEntry, RecoveredEffect};
mod signaling;
pub use acquisition::{Acquisition, AcquisitionRequest, Import, import_arguments};
pub use directories::{DirectoryAcquisition, DirectoryImport};
pub use discovery::DirectoryReader;
pub use presence::Typing;
pub use rooms::PublicRoomImport;
mod results;
mod submission;
mod uploads;
pub use results::{ResultAcquisition, ResultImport};
pub use submission::Submission;

#[derive(Clone)]
pub struct Workspace<D> {
	caller: Caller<D>,
	reference: Ref,
}
pub struct Snapshot {
	pub revision: u64,
	pub intent: Intent,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EffectStatus {
	/// Terminal admission refusal. No effect receipt or upstream call exists.
	Conflict,
	Pending,
	Committed,
	Unsent,
	Unknown,
}
impl EffectStatus {
	fn read(value: &Argument) -> Result<Self, Error> {
		match value.as_str() {
			Some("conflict") => Ok(Self::Conflict),
			Some("pending") => Ok(Self::Pending),
			Some("committed") => Ok(Self::Committed),
			Some("unsent") => Ok(Self::Unsent),
			Some("unknown") => Ok(Self::Unknown),
			_ => Err(loam::refusal("invalid session effect status").into()),
		}
	}
}
/// The complete original request and exact source survive UI replacement,
/// interruption and retry. Reading a newer snapshot cannot retarget it.
pub struct Command<D> {
	caller: Caller<D>,
	source: Ref,
	method: &'static str,
	operation: String,
	canonical: String,
	arguments: Vec<Argument>,
	_sources: Option<super::sources::LentSources<D>>,
}
impl<D: Deadline> Workspace<D> {
	pub fn new(client: Client<D>, reference: Ref) -> Self {
		Self {
			caller: Caller::Remote(client),
			reference,
		}
	}
	pub fn local(host: glowcap::Host, platform: D, reference: Ref) -> Self {
		Self {
			caller: Caller::Local { host, platform },
			reference,
		}
	}
	pub fn reference(&self) -> &Ref {
		&self.reference
	}
	/// Check this exact held use without registering an observation or reading
	/// workspace content. Shared wakes convey no authority to this source.
	pub async fn describe_access(&self) -> Result<super::access::UseState, Error> {
		let reply = self.call("describe-access", &[]).await?;
		loam::UseDescription::read(&reply)?;
		Ok(super::access::UseState(reply))
	}
	pub async fn mutation_sequence(&self) -> Result<u32, Error> {
		self.call("mutation-sequence", &[])
			.await?
			.as_i64()
			.and_then(|value| u32::try_from(value).ok())
			.filter(|value| *value > 0)
			.ok_or_else(|| loam::refusal("invalid session mutation sequence").into())
	}
	pub async fn snapshot(&self) -> Result<Snapshot, Error> {
		let reply = self.call("snapshot", &[]).await?;
		let Some([revision, intent]) = reply.as_list() else {
			return Err(loam::refusal("invalid managed workspace snapshot").into());
		};
		let revision = revision
			.as_i64()
			.and_then(|value| u64::try_from(value).ok())
			.ok_or_else(|| loam::refusal("invalid workspace revision"))?;
		let intent = intent
			.as_str()
			.ok_or_else(|| loam::refusal("invalid workspace intent"))?;
		let intent = Intent::decode(intent).map_err(|_| loam::refusal("invalid workspace intent"))?;
		Ok(Snapshot { revision, intent })
	}
	pub async fn export_configuration(&self) -> Result<(Snapshot, Vec<custody::Coordinate>), Error> {
		let reply = self.call("export-configuration", &[]).await?;
		let Some([revision, intent, coordinates]) = reply.as_list() else {
			return Err(loam::refusal("invalid configuration export").into());
		};
		let revision = revision
			.as_i64()
			.and_then(|v| u64::try_from(v).ok())
			.ok_or_else(|| loam::refusal("invalid export revision"))?;
		let intent = Intent::decode(intent.as_str().ok_or_else(|| loam::refusal("invalid export intent"))?)
			.map_err(|_| loam::refusal("invalid export intent"))?;
		let coordinates = coordinates
			.as_list()
			.filter(|rows| rows.len() <= rooms_application::content::session::records::FIELDS_PER_PAGE)
			.ok_or_else(|| loam::refusal("invalid export coordinates"))?;
		let coordinates = coordinates
			.iter()
			.map(|row| {
				custody::Coordinate::decode(row.as_str().ok_or_else(|| loam::refusal("invalid export coordinate"))?)
					.map_err(|_| loam::refusal("invalid export coordinate").into())
			})
			.collect::<Result<Vec<_>, Error>>()?;
		Ok((Snapshot { revision, intent }, coordinates))
	}
	/// ReadArchive admits this exact saved archive independently of workspace
	/// observation and session history. File disclosure also needs ReadFile.
	pub async fn archive_reader(&self, coordinate: custody::Coordinate, files: bool) -> Result<Ref, Error> {
		self.reader("archive-reader", &[coordinate_text(coordinate)?.into(), files.into()])
			.await
	}
	pub async fn history_reader(&self, seat: custody::Coordinate) -> Result<Ref, Error> {
		self.reader("history-reader", &[coordinate_text(seat)?.into()]).await
	}
	/// Read through the session facade over the exact held seat. Upstream
	/// conversation/generation constraints are preserved on every invocation.
	pub async fn history(
		&self,
		seat: custody::Coordinate,
	) -> Result<Vec<rooms_application::room::history::Line>, Error> {
		let reader = self.history_reader(seat).await?;
		let reply = self
			.caller
			.call(
				&reader,
				rooms_application::room::history::VERB,
				&[],
				"the history reader did not answer",
			)
			.await?;
		let rows = reply.as_list().ok_or_else(|| loam::refusal("invalid room history"))?;
		if rows.len() > rooms_application::room::history::MAX_LINES {
			return Err(rooms_application::room::history::Error::TooManyLines.into());
		}
		let mut history = rooms_application::room::history::History::default();
		for row in rows {
			let Some(values) = row.as_list() else { continue };
			history.push_with_previews(
				values.first().and_then(Argument::as_str),
				values.get(1).and_then(Argument::as_str),
				values.get(2).and_then(Argument::as_f64),
				values.get(3).and_then(Argument::as_str),
			)?;
		}
		Ok(history.into_lines())
	}
	pub async fn file_reader(&self, blob: &Ref) -> Result<Ref, Error> {
		self.reader("file-reader", &[blob.clone().into()]).await
	}
	async fn reader(&self, method: &'static str, args: &[Argument]) -> Result<Ref, Error> {
		Ref::try_from(&self.call(method, args).await?)
			.map_err(|_| loam::refusal("managed reader returned no capability").into())
	}
	async fn call(&self, method: &'static str, args: &[Argument]) -> Result<Argument, Error> {
		self.caller
			.call(&self.reference, method, args, "the managed workspace did not answer")
			.await
	}
}
impl<D: Deadline + Clone> Workspace<D> {
	/// Device and selected archive readers have independent permission gates.
	/// Both retain their original target across subsequent selection changes.
	pub async fn device_history(&self, files: bool) -> Result<super::archive::Archive<D>, Error> {
		self.history_source("device", files).await
	}
	pub async fn selected_archive(&self, files: bool) -> Result<super::archive::Archive<D>, Error> {
		self.history_source("selected", files).await
	}
	async fn history_source(&self, source: &'static str, files: bool) -> Result<super::archive::Archive<D>, Error> {
		let reference = self
			.reader("workspace-history-reader", &[source.into(), Argument::Boolean(files)])
			.await?;
		Ok(super::archive::Archive::through(self.caller.clone(), reference))
	}
	/// Check one installed callback selection and its exact initiating source.
	/// This returns no workspace payload or upstream capability.
	pub async fn check_inbox(&self, selected: &workspace::InboxSelection, inbox: &Ref) -> Result<(), Error> {
		self.inbox_recording(selected, inbox).await.map(|_| ())
	}
	/// Recording intent comes from the same canonical invocation that admits
	/// this exact callback. Consumers use it only during synchronous delivery.
	pub async fn inbox_recording(&self, selected: &workspace::InboxSelection, inbox: &Ref) -> Result<bool, Error> {
		let selected = serde_json::to_string(selected)
			.map_err(|_| Error::Unsent(Box::new(loam::refusal("invalid inbox selection"))))?;
		let reply = self
			.caller
			.call(
				&self.reference,
				"check-inbox",
				&[selected.into(), inbox.clone().into()],
				"the inbox admission did not answer",
			)
			.await?;
		match reply {
			Argument::Boolean(keep) => Ok(keep),
			_ => Err(loam::refusal("invalid callback recording intent").into()),
		}
	}
	pub async fn observe(
		&self,
		request: &super::access::ObservationRequest,
	) -> Result<super::access::Observation<D>, Error> {
		super::access::Observation::register_through(self.caller.clone(), &self.reference, request).await
	}
	pub async fn prepare_command(
		&self,
		operation: &str,
		base: u64,
		name: &str,
		arguments: &[String],
	) -> Result<Command<D>, Error> {
		let request =
			Request::from_parts(operation, base, name, arguments).map_err(|error| loam::refusal(error.to_string()))?;
		if requirements::command(request.route()).is_none() {
			return Err(loam::refusal("retired session command").into());
		}
		let canonical = request
			.canonical()
			.map_err(|_| loam::refusal("invalid canonical session command"))?;
		// Grammar admission borrows the strings. One reserved spine then
		// owns the complete request through replay, including after UI replacement.
		// The strings copy once into that owner; submit borrows it without cloning.
		let mut args = Vec::with_capacity(arguments.len() + 3);
		args.extend([operation.into(), (base as i64).into(), name.into()]);
		args.extend(arguments.iter().cloned().map(Argument::String));
		let source = self.reference.clone();
		Ok(Command {
			caller: self.caller.clone(),
			source,
			method: "command",
			operation: operation.into(),
			canonical,
			arguments: args,
			_sources: None,
		})
	}
}
impl<D: Deadline> Command<D> {
	pub async fn adopted(&self) -> Result<bool, Error> {
		let reply = self
			.caller
			.call(
				&self.source,
				"effect-adopted",
				&[self.operation.as_str().into()],
				"the original adoption did not answer",
			)
			.await?;
		match reply {
			Argument::Boolean(value) => Ok(value),
			_ => Err(loam::refusal("invalid adoption status").into()),
		}
	}
	pub fn retained_bytes(&self) -> usize {
		size_of::<Self>()
			.saturating_add(self.operation.capacity())
			.saturating_add(self.canonical.capacity())
			.saturating_add(super::retained::vector(&self.arguments))
			.saturating_add(
				self._sources
					.as_ref()
					.map_or(0, super::sources::LentSources::retained_bytes),
			)
	}
	pub fn operation(&self) -> &str {
		&self.operation
	}
	pub fn source(&self) -> &Ref {
		&self.source
	}
	pub fn canonical(&self) -> &str {
		&self.canonical
	}
	pub async fn submit(&self) -> Result<EffectStatus, Error> {
		if let Some(sources) = &self._sources {
			// Once delivery may start, the receiver's exact actor roots own the
			// source pins. Abandoning this observer cannot expire admitted work.
			sources.delivery_started();
		}
		let reply = self
			.caller
			.call(
				&self.source,
				self.method,
				&self.arguments,
				"the session command outcome is unknown",
			)
			.await?;
		EffectStatus::read(&reply)
	}
	pub async fn status(&self) -> Result<EffectStatus, Error> {
		let reply = self
			.caller
			.call(
				&self.source,
				"effect-status",
				&[self.operation.clone().into(), self.source.clone().into()],
				"the session receipt did not answer",
			)
			.await?;
		EffectStatus::read(&reply)
	}
	/// Wait on the original receipt and its live worker without dispatching.
	pub async fn receive(&self) -> Result<EffectStatus, Error> {
		results::receive(&self.caller, &self.source, &self.operation, &self.canonical).await
	}
	/// Committed data is encoded JSON text, optionally paired with exact
	/// returned custody. An unsettled receipt returns its status instead;
	/// a terminal failed observation returns its retained diagnostic error.
	pub async fn result(&self) -> Result<Argument, Error> {
		self.caller
			.call(
				&self.source,
				"effect-result",
				&[self.operation.clone().into(), self.canonical.clone().into()],
				"the original session result did not answer",
			)
			.await
			.and_then(results::observed)
	}
}
fn coordinate_text(coordinate: custody::Coordinate) -> Result<String, Error> {
	serde_json::to_string(&coordinate).map_err(|_| loam::refusal("invalid custody coordinate").into())
}
