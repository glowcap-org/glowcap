//! Shared admission owns policy; this callback owns workspace and receipt data.
mod acquisition;
mod activity;
mod archive_connection;
mod authority;
pub(super) mod commands;
mod connection;
mod grammar;
mod host_registrations;
mod references;
use grammar::{canonical, command_requirement, dispatch, operation, original};
pub(super) use grammar::{original_text, values};
use receipts::{authenticate, effect_requirement, location, restore_source, status};
pub(super) mod receipt_observation;
pub(super) mod receipts;
mod registration;
pub(super) use registration::registration;
mod discovery;
mod imports;
mod inbox;
mod introduction;
mod outgoing_line;
mod presence;
pub(super) mod reads;
pub(super) mod recording;
mod retention;
mod signaling;
use super::{
	State, bridge,
	records::{self, Field, References},
	results, uploads,
};
pub(super) use commands::{receipt, reserve};
use glowcap::{
	Argument, Ref, Result,
	loam::{
		self, Call, Content, Graph, Invocation, Method, PageSchema, ReferenceRequest, Registration, Requirement, Retry,
	},
};
use rooms_application::{
	content::{
		permissions::Permission,
		session::{
			self,
			custody::{self, Outcome},
			dispatch::Dispatch,
			effects, local, requirements, workspace,
		},
	},
	fields::{List, Text},
	session::command::Request,
};
use rooms_glowcap::{
	Value,
	client::{Deadline, Tasks},
};
use std::rc::Weak;

struct SessionContent<P: Tasks + Deadline + Clone + 'static>(Weak<State<P>>);
pub(super) fn refuse(message: &str) -> glowcap::Error {
	loam::refusal(message)
}
pub(super) fn text(value: &Argument) -> Result<&str> {
	value.as_str().ok_or_else(|| refuse("session text argument required"))
}
pub(super) type MetadataRecord = workspace::Record<records::Metadata, loam::BoundResource>;
impl<P: Tasks + Deadline + Clone + 'static> SessionContent<P> {
	fn owner(&self, verb: &str) -> Result<std::rc::Rc<State<P>>> {
		let owner = self.0.upgrade().ok_or_else(|| refuse("session owner is closed"))?;
		if owner.closing.get()
			&& !matches!(
				verb,
				"settle-effect"
					| "settle-history-erasure"
					| "retention-intent"
					| "observe-archive-connection"
					| "bridge-witnesses"
					| "accept-direct-introduction"
					| "adopt-direct-route"
			) {
			return Err(refuse("session is closing"));
		}
		Ok(owner)
	}
}
impl<P: Tasks + Deadline + Clone + 'static> Content for SessionContent<P> {
	fn dependent_requirement(&self, input: Invocation<'_>) -> Result<Requirement> {
		let _owner = self.owner(input.verb)?;
		use rooms_application::protocol_data as protocol;
		match input.verb {
			rooms_application::directory::registration::VOUCHER => {
				Requirement::new(&[Permission::InteractWorkspace.key()], &[])
			}
			"addLease" | "removeLease" | "closeConnection" => Requirement::new(
				&[Permission::InteractWorkspace.key(), Permission::UseOperations.key()],
				&[],
			),
			rooms_application::room::membership::SUBSCRIBE => {
				Requirement::new(&[Permission::InteractWorkspace.key()], &[])
			}
			protocol::EDIT
			| protocol::POST
			| rooms_application::open_graph::ROOM_POST_VERB
			| rooms_application::room::receipt::POST
			| protocol::POST_FILES
			| rooms_application::open_graph::ROOM_POST_FILES_VERB
			| rooms_application::room::receipt::POST_FILES
			| protocol::ATTACH
			| rooms_application::room::receipt::ATTACH
			| protocol::REFILE
			| protocol::WRITE
			| protocol::DISCARD
			| rooms_application::direct::DM
			| rooms_application::direct::READY
			| rooms_application::direct::HAND_ROOM
			| rooms_application::direct::OFFER_ROOM
			| rooms_application::direct::HAND_ARCHIVE
			| rooms_application::direct::OFFER_ARCHIVE
			| protocol::WITHDRAW
			| protocol::TYPING
			| rooms_application::signaling::OFFER_INBOX
			| rooms_application::signaling::OFFER
			| rooms_application::signaling::ANSWER
			| rooms_application::signaling::CANDIDATE
			| rooms_application::signaling::DONE
			| rooms_application::signaling::CHECK
			| protocol::AWAY
			| protocol::LEAVE
			| protocol::REVOKE
			| rooms_application::bridge::SUBMIT
			| protocol::PUBLICATION_READY
			| protocol::SET_TOPIC => Requirement::new(&[Permission::InteractWorkspace.key()], &[]),
			protocol::READ => Requirement::new(&[Permission::ReadFile.key()], &[]),
			protocol::PUBLICATION_DESCRIBE => Requirement::new(&[Permission::UseOperations.key()], &[]),
			protocol::HISTORY => Requirement::new(&[Permission::History.key()], &[]),
			protocol::NOTIFY | rooms_application::bridge::ASK => {
				Requirement::new(&[Permission::ObserveWorkspace.key()], &[])
			}
			_ => Err(refuse("unknown dependent session method")),
		}
	}
	fn requirement(&self, input: Invocation<'_>) -> Result<Requirement> {
		// Forwarding bypasses invoke; application lifetime belongs to admission
		// too, including the fresh source check after every upstream wait.
		let owner = self.owner(input.verb)?;
		if matches!(
			input.verb,
			"restore-custody" | "settle-history-erasure" | "retention-intent"
		) {
			super::retained::authorize(input, &owner.writer.root()?)?;
		}
		use Permission::*;
		match input.verb {
			"retire-room-authority" => authority::requirement(input, &owner.writer.root()?),
			"observe-direct-connection" => connection::requirement(input, &owner.writer.root()?),
			"observe-archive-connection" => archive_connection::requirement(input, &owner.writer.root()?),
			"record-inbox" => {
				recording::authorize(input, &owner.writer.root()?)?;
				inbox::selection(recording::callback(input)?)?;
				Requirement::new(&[ObserveWorkspace.key()], &[])
			}
			"workspace-history-reader" => {
				let (device, files) = reads::history_source(input.args)?;
				let keys = [if device { History.key() } else { ReadArchive.key() }, ReadFile.key()];
				Requirement::new(&keys[..if files { 2 } else { 1 }], &[])
			}
			"activity-reader" | "activity-file" | "activity-recipe" | "retain-incoming" | "acquire-activity" => {
				activity::requirement(input)
			}
			"typing-sender" => presence::requirement(input),
			"signaling-route" => signaling::requirement(input),
			"signaling-selected" => signaling::selected_requirement(input),
			"directory-reader" => discovery::requirement(input),
			"resynchronize-discovery" => {
				if !input.args.is_empty() {
					return Err(refuse("discovery resynchronization takes no arguments"));
				}
				Requirement::new(&[ObserveWorkspace.key()], &[])
			}
			"check-discovery" | "discovery-selected" => discovery::admission_requirement(input),
			"archive-reader"
			| "history-reader"
			| "bridge-form-reader"
			| "file-reader"
			| "custody-recipe"
			| "export-configuration"
			| "archive-issuer-reader"
			| "operations-reader"
			| "trace-snapshot"
			| "room-identity-reader"
			| "room-publication-identity" => reads::requirement(input),
			"sendFiles" | "refileLine" => {
				uploads::Request::read(input.verb, input.args)?;
				Requirement::new(&[InteractWorkspace.key()], &[])
			}
			"submit-bridge" => {
				bridge::request(input.args)?;
				Requirement::new(&[InteractWorkspace.key()], &[])
			}
			"bridge-reapplication" => Requirement::new(&[InteractWorkspace.key()], &[]),
			"forget-bridge" => Requirement::new(&[InteractWorkspace.key(), ManageCustody.key()], &[]),
			"command" => command_requirement(input.args, &[]),
			"effect-result" => {
				let [_, intent] = input.args else {
					return Err(refuse("effect-result takes id and original intent"));
				};
				effect_requirement(intent, &[])
			}
			"effect-intent" | "effect-adopted" | "resume-effect" | "release-effect" | "effect-inventory" => {
				receipts::requirement(input)
			}
			"import-result" | "acquire-result-workspace" | "acquire-created-room" => {
				let request = imports::Request::parse(input.verb, input.args)?;
				let additional: &[Permission] = if input.verb != "import-result" {
					&[ManageCustody, ReplaceWorkspace]
				} else {
					&[ManageCustody]
				};
				effect_requirement(request.intent, additional)
			}
			"effect-status" => Requirement::new(&[ResolvePending.key()], &[]),
			"effect-reader" => {
				let [_, intent] = input.args else {
					return Err(refuse("effect-reader takes operation id and original intent"));
				};
				effect_requirement(intent, &[ResolvePending])
			}
			"snapshot" | "resource-key" | "bridge-witnesses" => Requirement::new(&[ObserveWorkspace.key()], &[]),
			"check-inbox" => {
				inbox::selection(input)?;
				Requirement::new(&[ObserveWorkspace.key()], &[])
			}
			"check-outgoing-line" => {
				outgoing_line::selection(input)?;
				Requirement::new(&[ObserveWorkspace.key()], &[])
			}
			"accept-direct-introduction" | "adopt-direct-route" => Requirement::new(&[InteractWorkspace.key()], &[]),
			"restore-custody" | "settle-history-erasure" | "retention-intent" => {
				Requirement::new(&[ManageCustody.key()], &[])
			}
			"replaceWorkspace" => Requirement::new(&[ReplaceWorkspace.key()], &[]),
			"release" => Requirement::new(&[ManageCustody.key(), ReplaceWorkspace.key()], &[]),
			"acquire-workspace" => Requirement::new(&[ManageCustody.key(), ReplaceWorkspace.key()], &[]),
			"import" | "import-bundle" | "initialize" | "retire-host-registrations" | "settle-effect" => {
				Requirement::new(&[ManageCustody.key()], &[])
			}
			_ => Err(refuse("unknown session method")),
		}
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<ReferenceRequest>> {
		self.reference_requests(input)
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		let owner = self.owner(input.verb)?;
		if input.verb == "retire-host-registrations" {
			return host_registrations::invoke(call, input, &owner.writer.root()?);
		}
		if input.verb == "effect-reader" {
			return receipt_observation::reader(&owner, call, input);
		}
		if input.verb == "record-inbox" {
			return recording::invoke(call, input, &owner.writer.root()?);
		}
		if input.verb == "retire-room-authority" {
			return authority::invoke(call, input, &owner.writer.root()?);
		}
		if matches!(input.verb, "retention-intent" | "settle-history-erasure") {
			return retention::invoke(call, input, &owner.writer.root()?);
		}
		if input.verb == "workspace-history-reader" {
			let recording = owner.recording.borrow();
			return reads::selected_history(call, input, recording.as_ref().map(|sink| sink.reader()));
		}
		if input.verb == "observe-archive-connection" {
			return archive_connection::invoke(&owner, call, input);
		}
		if input.verb == "observe-direct-connection" {
			return connection::invoke(&owner, call, input);
		}
		if matches!(
			input.verb,
			"activity-reader" | "activity-file" | "activity-recipe" | "retain-incoming"
		) {
			return activity::invoke(&owner, call, input);
		}
		if input.verb == "acquire-activity" {
			return activity::acquire(&owner, call, input);
		}
		if input.verb == "typing-sender" {
			return presence::invoke(call, input);
		}
		if input.verb == "signaling-route" {
			return signaling::invoke(call, input);
		}
		if input.verb == "signaling-selected" {
			return signaling::selected(input);
		}
		if input.verb == "directory-reader" {
			return discovery::invoke(call, input);
		}
		if input.verb == "resynchronize-discovery" {
			owner.discovery_refresh.request()?;
			return Ok(Argument::Void);
		}
		if input.verb == "check-discovery" {
			return discovery::admit(call, input);
		}
		if input.verb == "discovery-selected" {
			return discovery::selected(input);
		}
		if input.verb == "check-inbox" {
			return inbox::invoke(call, input);
		}
		if input.verb == "check-outgoing-line" {
			return outgoing_line::invoke(call, input);
		}
		if matches!(input.verb, "accept-direct-introduction" | "adopt-direct-route") {
			return introduction::invoke(call, input);
		}
		if input.verb == "restore-custody" {
			return super::retained::invoke(call, input, &owner.writer.root()?);
		}
		if input.verb == "initialize" {
			if call.source()? != owner.writer.root()? {
				return Err(refuse("private session root required"));
			}
			if !input.args.is_empty() {
				return Err(refuse("initialize takes no arguments"));
			}
			if input.graph.is_some_and(|pages| !pages.is_empty()) {
				// Startup validates the committed codec without restoring custody
				// or replacing content. Restart cannot erase workspace or receipts.
				records::metadata(input)?;
				return Ok(Argument::Void);
			}
			if input.graph.is_none() {
				return Err(refuse("session graph is not prepared"));
			}
			let mut record = workspace::Record {
				binding: custody::ResourceBinding {
					resource: input.bound_resource,
				},
				intent: session::records::decode_workspace(&[input.payload])
					.map_err(|_| refuse("invalid initial workspace"))?,
				custody: custody::Custody::<References>::default(),
				outgoing: List::default(),
				bridges: Default::default(),
				effects: List::new(Vec::new()).expect("empty effects"),
			};
			records::replace(call, input, &mut record)?;
			return Ok(Argument::Void);
		}
		if matches!(
			input.verb,
			"effect-status"
				| "effect-result"
				| "settle-effect"
				| "effect-intent"
				| "effect-adopted"
				| "resume-effect"
				| "release-effect"
				| "effect-inventory"
		) {
			return self.receipt(call, input, &owner);
		}
		if matches!(
			input.verb,
			"import-result" | "acquire-result-workspace" | "acquire-created-room"
		) {
			return imports::invoke(call, input);
		}
		if matches!(input.verb, "sendFiles" | "refileLine") {
			return uploads::admit(&owner, call, input);
		}
		if input.verb == "submit-bridge" {
			return bridge::admit(&owner, call, input);
		}
		if input.verb == "bridge-reapplication" {
			return bridge::reapplication(call, input);
		}
		if input.verb == "forget-bridge" {
			return bridge::forget(&owner, call, input);
		}
		if matches!(input.verb, "import" | "import-bundle" | "acquire-workspace") {
			return acquisition::invoke(call, input);
		}
		if matches!(
			input.verb,
			"archive-reader"
				| "history-reader"
				| "bridge-form-reader"
				| "file-reader"
				| "custody-recipe"
				| "export-configuration"
				| "archive-issuer-reader"
				| "operations-reader"
				| "trace-snapshot"
				| "room-identity-reader"
				| "room-publication-identity"
		) {
			if input.verb == "trace-snapshot" {
				return reads::trace_snapshot(input, owner.trace.borrow().as_deref());
			}
			return reads::invoke(call, input);
		}
		if input.verb == "bridge-witnesses" {
			if !input.args.is_empty() || call.source()? != owner.writer.root()? {
				return Err(refuse("private session root required for bridge witnesses"));
			}
			let record = records::metadata(input)?;
			return super::bridge::credential_snapshot(&input.bound_resource.id.owner, record.bridges.as_slice());
		}
		if input.verb == "resource-key" {
			if !input.args.is_empty() {
				return Err(refuse("resource-key takes no arguments"));
			}
			// One fixed 33-byte projection outlives this invocation. Worker
			// startup compares two such replies and retains neither. The key
			// conveys no authority and keeps the private root out of the request.
			return Ok(Argument::Bytes(input.bound_resource.object.to_vec()));
		}
		if input.verb == "snapshot" {
			if !input.args.is_empty() {
				return Err(refuse("snapshot takes no arguments"));
			}
			let record = records::metadata(input)?;
			let revision = i64::try_from(input.content_revision).map_err(|_| refuse("workspace revision exhausted"))?;
			let intent = serde_json::to_string(&record.intent).map_err(|_| refuse("invalid workspace"))?;
			return Ok(Argument::List(vec![
				Argument::Integer(revision),
				Argument::String(intent),
			]));
		}
		if input.verb == "command" {
			let record = records::metadata(input)?;
			let id = operation(&input.args[0])?;
			if record.effects.as_slice().iter().any(|receipt| receipt.operation == id) {
				let source = call.source()?;
				authenticate(call, input, &record, &id, &source)?;
				let intent = Text::new(canonical(input.args)?.into())
					.ok_or_else(|| refuse("effect intent exceeds receipt capacity"))?;
				let receipt = effects::inspect(&record.effects, &id, &location(&record, &id)?, &intent)
					.map_err(|_| refuse("effect witness or intent differs"))?
					.expect("selected receipt");
				return Ok(status(
					receipt,
					owner.receipt_running(text(&input.args[0])?, record.intent.history_erasure.as_ref()),
				));
			}
		}
		let mut record = records::decode(input)?;
		match input.verb {
			"replaceWorkspace" => {
				let [intent] = input.args else {
					return Err(refuse("replaceWorkspace takes intent"));
				};
				record
					.intent
					.replace_configuration(
						workspace::Intent::decode(text(intent)?).map_err(|_| refuse("invalid workspace intent"))?,
					)
					.map_err(|_| refuse("change history retention through its dedicated command"))?;
				record
					.intent
					.validate(&record.custody)
					.map_err(|_| refuse("workspace refers to missing custody"))?;
				records::replace(call, input, &mut record)?;
				Ok(Argument::Void)
			}
			"release" => {
				let [coordinate, intent] = input.args else {
					return Err(refuse(
						"release takes an exact custody coordinate and replacement intent",
					));
				};
				let coordinate =
					custody::Coordinate::decode(text(coordinate)?).map_err(|_| refuse("invalid custody coordinate"))?;
				record
					.custody
					.remove(coordinate)
					.ok_or_else(|| refuse("custody field is absent"))?;
				record
					.intent
					.replace_configuration(
						workspace::Intent::decode(text(intent)?).map_err(|_| refuse("invalid workspace intent"))?,
					)
					.map_err(|_| refuse("change history retention through its dedicated command"))?;
				records::replace(call, input, &mut record)?;
				Ok(Argument::Void)
			}
			"command" => commands::admit(&owner, call, input, record),

			_ => Err(refuse("unknown session method")),
		}
	}
}
