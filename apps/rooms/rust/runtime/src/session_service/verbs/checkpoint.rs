//! Whole-checkpoint requests: `adoptWorkspace`, `replaceCheckpoint`, and the
//! `--checkpoint` import a fresh peer adopts before it listens.
use crate::session_commands::Admission;
use crate::session_commands::AdmissionError;
use crate::session_service::error::Error;
use crate::session_service::facet::Facet;
use crate::session_service::facet::Rights;
use crate::session_service::Platform;
use glowcap::Argument;
use rooms_application::{
	room::ArgumentView,
	session::{
		checkpoint::{Checkpoint, Refusal},
		state::{OperationId, SafeInteger},
		verbs,
	},
};
use rooms_glowcap::{routes::CheckpointRoutes, Value};

pub fn request<P: Platform>(
	facet: &Facet<P>,
	rights: &Rights,
	verb: &str,
	args: &[Argument],
) -> Result<Argument, Error> {
	let adopt = verb == verbs::ADOPT_WORKSPACE;
	if !rights.is_admin() {
		return Err(Error::refused(if adopt {
			"this Rooms session facet cannot adopt a workspace"
		} else {
			"this Rooms session facet cannot replace checkpoints"
		}));
	}
	let (id, base, checkpoint) = parse(args, verb)?;
	let (verb, admission) = if adopt {
		(
			verbs::ADOPT_WORKSPACE,
			facet.0.commands.prepare_adoption(id, base, checkpoint),
		)
	} else {
		(
			verbs::REPLACE_CHECKPOINT,
			facet.0.commands.prepare_replace(id, base, checkpoint),
		)
	};
	answer_revision(facet, verb, admission)
}

/// Answer with the revision a session transaction commits.
pub fn answer_revision<P: Platform>(
	facet: &Facet<P>,
	verb: &'static str,
	admission: Result<Admission<u64>, AdmissionError>,
) -> Result<Argument, Error> {
	let admission = admission?;
	facet.answer(verb, async move {
		let revision = admission.send()?.wait().await.map_err(Error::runtime)?;
		Ok(Argument::Integer(revision as i64))
	})
}

fn parse(args: &[Argument], verb: &str) -> Result<(OperationId, u64, Checkpoint), Error> {
	let shape = || Error::refused(format!("{verb} takes an operation id, base revision, and checkpoint"));
	let [id, base, checkpoint] = args else {
		return Err(shape());
	};
	let id = operation_id(id.as_str().ok_or_else(shape)?)?;
	let base = ArgumentView::integer(&Value(base))
		.and_then(|n| u64::try_from(n).ok())
		.and_then(SafeInteger::<false>::new)
		.ok_or_else(shape)?
		.get();
	let checkpoint =
		Checkpoint::decode(checkpoint.as_str().ok_or_else(shape)?, &CheckpointRoutes).map_err(refused_checkpoint)?;
	Ok((id, base, checkpoint))
}

pub fn operation_id(text: &str) -> Result<OperationId, Error> {
	OperationId::new(text.into()).ok_or_else(|| Error::refused("invalid session operation id"))
}

fn refused_checkpoint(refusal: Refusal) -> Error {
	Error::refused(refusal.to_string())
}

/// Decode the existing workspace export or bare session document without I/O.
pub fn import_document(raw: &str) -> Result<Checkpoint, Refusal> {
	if raw
		.encode_utf16()
		.take(rooms_application::session::checkpoint::MAX_CHECKPOINT_UNITS + 1)
		.count()
		> rooms_application::session::checkpoint::MAX_CHECKPOINT_UNITS
	{
		return Err(Refusal::Schema);
	}
	Checkpoint::decode(raw, &CheckpointRoutes).or_else(|_| {
		let value: serde_json::Value = serde_json::from_str(raw).map_err(|_| Refusal::Schema)?;
		let session = value.get("session").ok_or(Refusal::Schema)?;
		let text = serde_json::to_string(session).map_err(|_| Refusal::Schema)?;
		Checkpoint::decode(&text, &CheckpointRoutes)
	})
}
