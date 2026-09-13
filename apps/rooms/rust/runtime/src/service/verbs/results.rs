//! Result-bearing commands: managed rooms and returned room authority. The
//! result text is committed with the operation so a resume after a crash
//! returns what was already obtained instead of asking the directory twice.
use super::{checkpoint::operation_id, command::material};
use crate::directories::runtime::DirectoryRuntime;
use crate::rooms::RoomRuntime;
use crate::rooms::operations::Operations;
use crate::service::Platform;
use crate::service::error::Error;
use crate::service::facet::Facet;
use crate::service::facet::Rights;
use crate::service::revision::Revision;
use crate::session::commands::Admission;
use crate::session::commands::SessionCommands;
use crate::session::state::ResultStatus;
use glowcap::Argument;
use rooms_application::{
	directory::creation::RecoveryKey,
	session::{
		checkpoint::{
			commands::results::{Command, Kind, Plan},
			reconciliation::Id,
		},
		command::Request,
		state::{OperationId, Outcome, ResultText},
		verbs,
	},
	text::DocumentText,
};
use rooms_glowcap::routes::CheckpointRoutes;
use std::{cell::RefCell, rc::Rc};

pub fn apply<P: Platform>(
	facet: &Facet<P>,
	command: Command,
	request: &Request<'_, impl rooms_application::room::ArgumentView>,
) -> Result<Revision, Error> {
	let id = operation_id(request.id())?;
	let args: Vec<DocumentText> = request.args().map(DocumentText::from).collect();
	let names: Vec<&str> = args.iter().map(|a| a.as_str().unwrap_or("")).collect();
	let material = material(request.name(), &names)?;
	let plan = Rc::new(plan(facet, command, &id, &args)?);
	let admission = facet
		.0
		.commands
		.prepare_result(id.clone(), request.base(), material.clone(), plan.clone())?;
	let execution = Execution::new(facet);
	Ok(Revision::new(async move {
		let revision = run(admission, execution, id, material, plan).await?;
		Ok(revision)
	}))
}

/// `resolveEffect` and `resumeEffect`: the administrator settles or resumes
/// an effect whose outcome the session could not observe on its own.
pub fn external<P: Platform>(
	facet: &Facet<P>,
	rights: &Rights,
	verb: &str,
	args: &[Argument],
) -> Result<Argument, Error> {
	if !rights.is_admin() {
		return Err(Error::refused(if verb == verbs::RESOLVE_EFFECT {
			"this Rooms session facet cannot resolve external effects"
		} else {
			"this Rooms session facet cannot resume external effects"
		}));
	}
	if verb == verbs::RESOLVE_EFFECT {
		let (id, outcome) = match args {
			[Argument::String(id), Argument::String(outcome)] => (id.as_str(), outcome.as_str()),
			_ => return Err(Error::invalid(RESOLVE_SHAPE)),
		};
		let outcome = match outcome {
			"committed" => Outcome::Committed,
			"abandoned" => Outcome::Abandoned,
			_ => return Err(Error::invalid(RESOLVE_SHAPE)),
		};
		let id = operation_id(id)?;
		return super::checkpoint::answer_revision(facet, verbs::RESOLVE_EFFECT, facet.0.commands.resolve(id, outcome));
	}
	let id = match args {
		[Argument::String(id)] => operation_id(id)?,
		_ => return Err(Error::invalid("resumeEffect takes one operation id")),
	};
	resume(facet, id)?.wire(facet, verbs::RESUME_EFFECT)
}

const RESOLVE_SHAPE: &str = "resolveEffect takes an operation id and committed or abandoned";

fn plan<P: Platform>(
	facet: &Facet<P>,
	command: Command,
	id: &OperationId,
	args: &[DocumentText],
) -> Result<Plan, Error> {
	facet.0.commands.view().read(|state| {
		let known = state.operation_known(id)?;
		command
			.prepare(state.checkpoint()?, args, &CheckpointRoutes, known)
			.map_err(Error::invalid_by)
	})?
}

pub(in crate::service) fn resume<P: Platform>(facet: &Facet<P>, id: OperationId) -> Result<Revision, Error> {
	struct Pending {
		kind: String,
		intent: String,
		returned: bool,
	}
	let pending = facet.0.commands.view().read(|state| {
		let pending = state.pending_result(&id)?;
		let text = |field: &DocumentText| {
			field
				.as_str()
				.map(str::to_owned)
				.ok_or_else(|| Error::invalid("the result effect has no durable intent"))
		};
		Ok::<_, Error>(Pending {
			kind: text(pending.kind.text())?,
			intent: text(pending.intent.text())?,
			returned: pending.result.is_some(),
		})
	})??;
	if pending.returned {
		return Ok(Revision::admitted(facet.0.commands.recover_result(id)?));
	}
	let kind = Kind::parse(&pending.kind).ok_or_else(|| Error::invalid("the result effect has no durable intent"))?;
	let plan = Plan::decode(kind, &DocumentText::from(pending.intent), &CheckpointRoutes).map_err(Error::invalid_by)?;
	let plan = Rc::new(facet.0.commands.view().read(|state| {
		plan.resume(state.checkpoint()?, &CheckpointRoutes)
			.map_err(Error::invalid_by)
	})??);
	let execution = Execution::new(facet);
	Ok(Revision::new(async move {
		let result = execution.realize_owned(&plan, &id).await?;
		let committed = commit(execution.commands.clone(), id, None, result).await;
		execution.finish(committed).await
	}))
}

async fn run<P: Platform>(
	admission: Admission<ResultStatus>,
	execution: Execution<P>,
	id: OperationId,
	material: DocumentText,
	plan: Rc<Plan>,
) -> Result<u64, Error> {
	let prepared = admission.send()?.wait().await?;
	let result = match prepared {
		ResultStatus::Committed { revision, .. } => return Ok(revision),
		ResultStatus::Returned(text) => text.as_ref().text().as_str().unwrap_or("").to_owned(),
		ResultStatus::Prepared => execution.realize_owned(&plan, &id).await?,
	};
	{
		let committed = commit(execution.commands.clone(), id, Some(material), result).await;
		execution.finish(committed).await
	}
}

async fn commit(
	commands: SessionCommands,
	id: OperationId,
	material: Option<DocumentText>,
	result: String,
) -> Result<u64, Error> {
	let result = ResultText::new(result.into()).ok_or_else(|| Error::invalid("result text exceeds its ceiling"))?;
	let revision = commands.commit_result(id, material, result)?.send()?.wait().await?;
	Ok(revision)
}

/// The authority operation stopped between its ledger marker and its result,
/// so what the directory did is unknown here; the marker makes a resume safe.
fn incomplete(error: Error) -> Error {
	Error::uncertain(format!(
		"Rooms authority operation did not complete; its recovery operation can be resumed safely: {error}"
	))
}

/// Obtain the plan's result from the live directory or room.
struct Execution<P: Platform> {
	entry: RefCell<Option<crate::directories::runtime::entry::Entry<P>>>,
	room_entry: RefCell<Option<String>>,
	commands: SessionCommands,
	directories: DirectoryRuntime<P>,
	rooms: RoomRuntime<P>,
	operations: Operations<P>,
}
impl<P: Platform> Execution<P> {
	fn new(facet: &Facet<P>) -> Self {
		Self {
			entry: RefCell::new(None),
			room_entry: RefCell::new(None),
			commands: facet.0.commands.clone(),
			directories: facet.0.directories.clone(),
			rooms: facet.0.rooms.clone(),
			operations: facet.0.operations.clone(),
		}
	}
	async fn finish(&self, result: Result<u64, Error>) -> Result<u64, Error> {
		let room = self.room_entry.borrow_mut().take();
		let mut retirement = Ok(());
		if let Some(id) = room {
			if result.is_err() {
				retirement = self.rooms.retire_entry(&id).await;
			} else {
				self.rooms.commit_entry(&id);
			}
		}
		let entry = self.entry.borrow_mut().take();
		let cleanup = match entry {
			Some(entry) => entry.finish(result.is_ok()).await,
			None => Ok(()),
		};
		let cleanup = Error::fold(retirement, cleanup);
		match result {
			Ok(value) => {
				cleanup?;
				Ok(value)
			}
			Err(error) => Err(error.retain_result(cleanup)),
		}
	}
	async fn realize_owned(&self, plan: &Plan, id: &OperationId) -> Result<String, Error> {
		match self.realize(plan).await {
			Ok(result) => Ok(result),
			Err(error) if plan.kind() == Kind::RoomEntry => {
				// Entry acquires no published authority. Its provisional membership
				// and connection have explicit compensating retirement below;
				// refusal must not strand a result marker behind a bad link.
				let cleanup = async {
					self.commands
						.resolve(id.clone(), Outcome::Abandoned)?
						.send()?
						.wait()
						.await?;
					Ok(())
				}
				.await;
				Err(self.finish(Err(error.retain_result(cleanup))).await.unwrap_err())
			}
			Err(error) => Err(incomplete(error)),
		}
	}
	async fn realize(&self, plan: &Plan) -> Result<String, Error> {
		let directories = &self.directories;
		let rooms = &self.rooms;
		let json = |value: serde_json::Value| serde_json::to_string(&value).map_err(Error::invalid_by);
		match plan.kind() {
			Kind::RoomEntry => {
				let (id, locator, nick) = plan
					.entry_directory()
					.ok_or_else(|| Error::invalid("invalid room entry"))?;
				let entry = directories.entry(id, locator, nick).await?;
				let directory = entry.directory.clone();
				*self.entry.borrow_mut() = Some(entry);
				let link = plan
					.entry_link()
					.ok_or_else(|| Error::invalid("room entry has no link"))?;
				let reference = directory.client().enliven(link).await.map_err(Error::peer)?;
				let name = directory.client().room_called(&reference).await.unwrap_or_default();
				if !self.entry.borrow().as_ref().is_some_and(|entry| entry.current()) {
					return Err(Error::stale(
						"the room directory connection changed during link resolution",
					));
				}
				let existing = rooms.holding(directory.client().session(), &reference);
				let name = if name.is_empty() {
					plan.label().as_str().unwrap_or("private room")
				} else {
					&name
				};
				let (returned, selected) = self.commands.view().read(|state| {
					let checkpoint = state.checkpoint().map_err(Error::from)?;
					let returned = plan
						.entry_returned(checkpoint, existing.as_deref(), name)
						.map_err(Error::invalid_by)?;
					// Use the same reducer to choose the saved identity on reentry.
					// Staging a fresh id while commit selects a retained id would
					// orphan the prepared membership and lose its buffered messages.
					let selected = if existing.is_none() {
						Some(
							plan.apply(checkpoint, &returned.clone().into(), &CheckpointRoutes)
								.map_err(Error::invalid_by)?,
						)
					} else {
						None
					};
					Ok::<_, Error>((returned, selected))
				})??;
				if let Some(selected) = selected {
					let room = selected
						.rooms()
						.find(|room| Some(room.id.text()) == selected.active())
						.ok_or_else(|| Error::invalid("room entry did not select a conversation"))?;
					let id = room
						.id
						.text()
						.as_str()
						.ok_or_else(|| Error::invalid("invalid room identity"))?
						.to_owned();
					rooms
						.stage_entry(directory, reference, nick.as_str().unwrap_or(""), room)
						.await?;
					*self.room_entry.borrow_mut() = Some(id);
				}
				self.entry
					.borrow_mut()
					.as_mut()
					.expect("entry retained above")
					.stage()?;
				Ok(returned)
			}
			Kind::ManagedRoom => {
				let directory_id = Id::new(plan.directory().clone())
					.ok_or_else(|| Error::invalid("managed-room directory exceeds its field"))?;
				let (directory, _) = directories
					.connected(&directory_id)
					.ok_or_else(|| Error::stale("that directory is not connected in this Rooms session"))?;
				let key = RecoveryKey::parse(
					plan.recovery_key()
						.and_then(|key| key.as_str().map(str::to_owned))
						.ok_or_else(|| Error::invalid("managed-room result plan is incomplete"))?,
				)
				.map_err(Error::invalid_by)?;
				let policy = plan
					.policy()
					.ok_or_else(|| Error::invalid("managed-room result plan is incomplete"))?;
				let label = plan
					.label()
					.as_str()
					.ok_or_else(|| Error::invalid("managed-room result plan has no label"))?;
				let managed = directory.open_managed(label, policy, &key).await.map_err(Error::peer)?;
				json(serde_json::json!({
					"roomLink": managed.room_link,
					"managerLink": managed.manager_link,
				}))
			}
			Kind::RoomLink => {
				let room = rooms.live(conversation(plan, "room-link")?)?;
				let link = room.stewardship().link().await.map_err(Error::peer)?;
				json(serde_json::json!({ "roomLink": link }))
			}
			Kind::RoomManager => {
				let (scope, room) = rooms.source(conversation(plan, "room-manager")?)?;
				let link = match plan.manager().and_then(|link| link.as_str()) {
					Some(link) => link.to_owned(),
					None => {
						let identity = room
							.client()
							.room_manager_identity(room.reference())
							.await
							.map_err(Error::peer)?;
						let issued = self
							.operations
							.call(
								&self.commands,
								directories,
								"operator",
								&scope,
								rooms_application::server::operations::operator::verbs::GIVE_MANAGER,
								&[identity.into()],
							)
							.await?;
						issued
							.as_str()
							.filter(|link| !link.is_empty())
							.ok_or_else(|| Error::invalid("the operator did not return room management"))?
							.to_owned()
					}
				};
				room.stewardship().take_manager(&link).await.map_err(Error::peer)?;
				let room_link = room.stewardship().link().await.map_err(Error::peer)?;
				let links = room.stewardship().links();
				let incomplete = || Error::invalid("the room retained incomplete manager authority");
				json(serde_json::json!({
					"roomLink": room_link,
					"managerLink": links.manager.ok_or_else(incomplete)?,
				}))
			}
			Kind::RoomSteward => {
				let room = rooms.live(conversation(plan, "room-moderator")?)?;
				if let Some(link) = plan.steward().and_then(|link| link.as_str()) {
					room.stewardship().take(link).await.map_err(Error::peer)?;
				} else if !room.stewardship().claim().await.map_err(Error::peer)? {
					return Err(Error::refused("this room did not offer its moderator capability"));
				}
				let links = room.stewardship().links();
				let incomplete = || Error::invalid("the room retained incomplete moderator authority");
				json(serde_json::json!({
					"roomLink": links.room.ok_or_else(incomplete)?,
					"stewardLink": links.steward.ok_or_else(incomplete)?,
				}))
			}
		}
	}
}
fn conversation<'a>(plan: &'a Plan, kind: &str) -> Result<&'a str, Error> {
	plan.conversation()
		.as_str()
		.ok_or_else(|| Error::invalid(format!("{kind} result plan is incomplete")))
}
