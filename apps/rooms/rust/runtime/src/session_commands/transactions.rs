use super::*;
use crate::session_state::{Error, OrdinaryStatus, RecordedStatus, ResultStatus};
use rooms_application::{
	documents::WriteFailure,
	session::{
		checkpoint::{commands::results::Plan, Checkpoint},
		state::{Inspected, Inspection, Outcome, ResultText},
	},
};
type Answer<T> = oneshot::Sender<Result<T, String>>;
pub(super) enum Transaction {
	InspectCommand {
		id: OperationId,
		base: u64,
		material: DocumentText,
		answer: Answer<Option<u64>>,
	},
	ReceiveRoomLink {
		id: OperationId,
		invitation: Box<rooms_application::session::checkpoint::invitations::RoomLink>,
		answer: Answer<u64>,
	},
	AcceptHanded {
		id: OperationId,
		base: u64,
		invitation: DocumentText,
		args: [DocumentText; 2],
		answer: Answer<u64>,
	},
	Command {
		id: OperationId,
		base: u64,
		command: Command,
		args: Vec<DocumentText>,
		answer: Answer<u64>,
	},
	BridgeCommand {
		id: OperationId,
		base: u64,
		args: Vec<DocumentText>,
		directory: DocumentText,
		scope: DocumentText,
		secrets: Answers,
		revision: Option<DocumentText>,
		custody: BridgeSecrets,
		answer: Answer<u64>,
	},
	Adopt {
		id: OperationId,
		base: u64,
		checkpoint: Box<Checkpoint>,
		answer: Answer<u64>,
	},
	Replace {
		id: OperationId,
		base: u64,
		checkpoint: Box<Checkpoint>,
		answer: Answer<u64>,
	},
	Inspect {
		id: OperationId,
		base: u64,
		material: DocumentText,
		answer: Answer<Inspection>,
	},
	Prepare {
		id: OperationId,
		base: u64,
		material: DocumentText,
		answer: Answer<OrdinaryStatus>,
	},
	PrepareInspected {
		inspection: Inspected,
		material: DocumentText,
		answer: Answer<OrdinaryStatus>,
	},
	Commit {
		id: OperationId,
		material: DocumentText,
		answer: Answer<u64>,
	},
	Resolve {
		id: OperationId,
		outcome: Outcome,
		answer: Answer<u64>,
	},
	ReserveResult {
		id: OperationId,
		base: u64,
		material: DocumentText,
		plan: Rc<Plan>,
		answer: Answer<ResultStatus>,
	},
	CommitResult {
		id: OperationId,
		material: Option<DocumentText>,
		result: ResultText,
		answer: Answer<u64>,
	},
	RecoverResult {
		id: OperationId,
		answer: Answer<u64>,
	},
}
impl Transaction {
	pub(super) async fn execute<S: Documents, G: Entropy>(
		self,
		state: &mut DurableSession<S, G>,
		events: &mut impl SessionEvents,
		view: &SessionView,
	) {
		if let Err(error) = events.settled(view).await {
			self.refuse(rooms_application::failure::reason_prefix(&error));
			return;
		}
		match self {
			Self::InspectCommand {
				id,
				base,
				material,
				answer,
			} => {
				let result: Result<_, Error<S::Error>> = view
					.read(|state| state.inspect_command(&id, base, &material))
					.map_err(Error::from)
					.and_then(|result| result.map_err(Error::from));
				settle(answer, result);
			}
			Self::ReceiveRoomLink { id, invitation, answer } => {
				let result = async {
					let (base, present) = view.read(|state| {
						Ok::<_, rooms_application::session::state::Error>((
							state.revision()?,
							invitation.present(state.checkpoint()?),
						))
					})??;
					if present {
						return Ok((base, None));
					}
					let material = invitation
						.material()
						.map_err(rooms_application::session::state::Error::Command)?;
					state
						.mutate(
							id,
							base,
							&material,
							Command::ReceiveRoomLinkInvitation.impact(),
							|current| {
								rooms_application::session::checkpoint::commands::receive_room_link(
									current,
									&invitation,
									&rooms_glowcap::routes::CheckpointRoutes,
								)
								.map_err(rooms_application::session::state::Error::Command)
							},
						)
						.await
				}
				.await;
				settle(answer, publish(result, events, view).await);
			}
			Self::Command {
				id,
				base,
				command,
				args,
				answer,
			} => {
				let admission = {
					let facts = events.facts();
					state.prepare_command(id, base, command, &args, &facts)
				};
				let result = commit_candidate(state, admission, events).await;
				settle(answer, publish(result, events, view).await);
			}
			Self::BridgeCommand {
				id,
				base,
				args,
				directory,
				scope,
				secrets,
				revision,
				custody,
				answer,
			} => {
				let request = BridgeTransaction {
					id,
					base,
					args,
					directory,
					scope,
					secrets,
					revision,
					custody,
				};
				let result = Box::pin(execute_bridge(request, state, events, view)).await;
				settle(answer, result);
			}
			Self::AcceptHanded {
				id,
				base,
				invitation,
				args,
				answer,
			} => {
				let result = async {
					let material = Command::AcceptInvitation
						.material(&args)
						.map_err(rooms_application::session::state::Error::Command)?;
					state
						.mutate(id, base, &material, Command::AcceptInvitation.impact(), |current| {
							rooms_application::session::checkpoint::commands::accept_handed(
								current,
								&invitation,
								&args,
								&rooms_glowcap::routes::CheckpointRoutes,
							)
							.map_err(rooms_application::session::state::Error::Command)
						})
						.await
				}
				.await;
				settle(answer, publish(result, events, view).await);
			}
			Self::Adopt {
				id,
				base,
				checkpoint,
				answer,
			} => {
				let result = async {
					let material = checkpoint
						.adoption_material()
						.map_err(|_| rooms_application::session::state::Error::Checkpoint)?;
					let admission = state.prepare_adopt(id, base, &material, *checkpoint);
					commit_candidate(state, admission, events).await
				}
				.await;
				settle(answer, publish(result, events, view).await);
			}
			Self::Replace {
				id,
				base,
				checkpoint,
				answer,
			} => {
				let result = async {
					let material = serde_json::to_string(&*checkpoint)
						.map(DocumentText::from)
						.map_err(|_| rooms_application::session::state::Error::Checkpoint)?;
					let admission = state.prepare_replace(id, base, &material, *checkpoint);
					commit_candidate(state, admission, events).await
				}
				.await;
				settle(answer, publish(result, events, view).await);
			}
			Self::Inspect {
				id,
				base,
				material,
				answer,
			} => settle(answer, state.inspect_ordinary(id, base, &material)),
			Self::Prepare {
				id,
				base,
				material,
				answer,
			} => {
				let result = state.prepare_ordinary(id, base, &material).await;
				settle(answer, publish(result, events, view).await);
			}
			Self::PrepareInspected {
				inspection,
				material,
				answer,
			} => {
				let result = state.prepare_inspected(inspection, &material).await;
				settle(answer, publish(result, events, view).await);
			}
			Self::Commit { id, material, answer } => {
				let result = state.commit_ordinary(&id, &material).await.map(revision);
				settle(answer, publish(result, events, view).await);
			}
			Self::Resolve { id, outcome, answer } => {
				let result = state.resolve(&id, outcome).await.map(revision);
				settle(answer, publish(result, events, view).await);
			}
			Self::ReserveResult {
				id,
				base,
				material,
				plan,
				answer,
			} => {
				let result = state.prepare_plan(id, base, &material, &plan).await;
				settle(answer, publish(result, events, view).await);
			}
			Self::CommitResult {
				id,
				material,
				result,
				answer,
			} => {
				let recorded = state.record_result(&id, material.as_ref(), result).await;
				let result = match publish(recorded, events, view).await {
					Ok(RecordedStatus::Committed(revision)) => Ok(revision),
					Ok(RecordedStatus::Stored) => recover(state, &id, events, view).await,
					Err(error) => Err(error),
				};
				settle(answer, result);
			}
			Self::RecoverResult { id, answer } => settle(answer, recover(state, &id, events, view).await),
		}
	}
	pub(super) fn refuse(self, reason: &str) {
		match self {
			Self::InspectCommand { answer, .. } => {
				let _ = answer.send(Err(reason.into()));
			}
			Self::ReceiveRoomLink { answer, .. }
			| Self::Command { answer, .. }
			| Self::BridgeCommand { answer, .. }
			| Self::AcceptHanded { answer, .. }
			| Self::Adopt { answer, .. }
			| Self::Replace { answer, .. }
			| Self::Commit { answer, .. }
			| Self::Resolve { answer, .. }
			| Self::CommitResult { answer, .. }
			| Self::RecoverResult { answer, .. } => {
				let _ = answer.send(Err(reason.into()));
			}
			Self::Inspect { answer, .. } => {
				let _ = answer.send(Err(reason.into()));
			}
			Self::Prepare { answer, .. } | Self::PrepareInspected { answer, .. } => {
				let _ = answer.send(Err(reason.into()));
			}
			Self::ReserveResult { answer, .. } => {
				let _ = answer.send(Err(reason.into()));
			}
		}
	}
}
struct BridgeTransaction {
	id: OperationId,
	base: u64,
	args: Vec<DocumentText>,
	directory: DocumentText,
	scope: DocumentText,
	secrets: Answers,
	revision: Option<DocumentText>,
	custody: BridgeSecrets,
}
async fn execute_bridge<S: Documents, G: Entropy>(
	request: BridgeTransaction,
	state: &mut DurableSession<S, G>,
	events: &mut impl SessionEvents,
	view: &SessionView,
) -> Result<u64, Error<S::Error>> {
	// A prior committed bridge command may have published while clearing its
	// custody journal failed. Resolve that journal against the durable checkpoint
	// before admitting either a retry or a newer command for the same scope.
	let witnesses = {
		let current = state.state()?;
		crate::bridge_secrets::checkpoint_witnesses(current.checkpoint()?)
	};
	request.custody.recover(&witnesses).await.map_err(Error::Effects)?;
	let admission = {
		let facts = events.facts();
		state.prepare_command(
			request.id,
			request.base,
			Command::SubmitRoomBridgeForm,
			&request.args,
			&facts,
		)
	};
	match admission {
		Ok(rooms_application::session::state::Admission::Repeated(revision)) => {
			publish(Ok((revision, None)), events, view).await
		}
		Ok(admission @ rooms_application::session::state::Admission::Write(_)) => {
			match request
				.custody
				.stage(
					request.directory.clone(),
					request.scope.clone(),
					request.secrets,
					request.revision,
				)
				.await
			{
				Ok(token) => match commit_candidate(state, Ok(admission), events).await {
					Ok(committed) => {
						let published = publish(Ok(committed), events, view).await?;
						request
							.custody
							.settle(&request.directory, &request.scope, token)
							.await
							.map_err(Error::Effects)?;
						Ok(published)
					}
					Err(error @ Error::Write(WriteFailure::Indeterminate(_))) => Err(error),
					Err(error) => match request.custody.discard(&request.directory, &request.scope, token).await {
						Ok(()) => Err(error),
						Err(custody_error) => Err(Error::Effects(format!(
							"{error}; bridge secret rollback failed: {custody_error}"
						))),
					},
				},
				Err(error) => Err(Error::Effects(error)),
			}
		}
		Err(error) => Err(error),
	}
}
async fn commit_candidate<S: Documents, G: Entropy>(
	state: &mut DurableSession<S, G>,
	admission: Result<rooms_application::session::state::Admission, Error<S::Error>>,
	events: &mut impl SessionEvents,
) -> Result<(u64, Option<Change>), Error<S::Error>> {
	let admission = admission?;
	let barrier = if let rooms_application::session::state::Admission::Write(write) = &admission {
		if let Some(checkpoint) = write.checkpoint() {
			Some(events.preparing(checkpoint).await.map_err(Error::Effects)?)
		} else {
			None
		}
	} else {
		None
	};
	let result = state.admitted(admission).await;
	drop(barrier);
	result
}
fn revision(change: Change) -> (u64, Option<Change>) {
	(change.revision, Some(change))
}
fn settle<T, E: std::fmt::Display>(answer: Answer<T>, result: Result<T, Error<E>>) {
	let _ = answer.send(result.map_err(|e| e.to_string()));
}
async fn publish<T, E>(
	result: Result<(T, Option<Change>), Error<E>>,
	events: &mut impl SessionEvents,
	view: &SessionView,
) -> Result<T, Error<E>> {
	let (value, change) = result?;
	if let Some(change) = change {
		events.changed(change, view);
	}
	events
		.settled(view)
		.await
		.map_err(|error| Error::Effects(rooms_application::failure::reason_prefix(&error).to_owned()))?;
	Ok(value)
}
async fn recover<S: Documents, G: Entropy>(
	state: &mut DurableSession<S, G>,
	id: &OperationId,
	events: &mut impl SessionEvents,
	view: &SessionView,
) -> Result<u64, Error<S::Error>> {
	loop {
		let result = state.finish_result(id).await?;
		let finished = result.1.is_none();
		let revision = publish(Ok(result), events, view).await?;
		if finished {
			return Ok(revision);
		}
	}
}
