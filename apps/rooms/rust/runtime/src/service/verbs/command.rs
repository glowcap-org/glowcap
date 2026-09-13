//! `command`: the durable session command envelope, routed by what it changes.
//! A checkpoint command commits on its own; an effect runs against a live room
//! or direct partner and ledgers its outcome; a result command returns text.
use super::{checkpoint::operation_id, effects, results};
use crate::service::Platform;
use crate::service::error::Error;
use crate::service::facet::Facet;
use crate::service::facet::Rights;
use crate::service::revision::Revision;
use glowcap::Argument;
use rooms_application::{
	session::{
		checkpoint::commands::{BridgeSubmission, Command},
		command::{Request, Route},
	},
	text::DocumentText,
};
use rooms_glowcap::Value;

pub fn dispatch<P: Platform>(facet: &Facet<P>, rights: &Rights, args: &[Argument]) -> Result<Argument, Error> {
	let views: Vec<_> = args.iter().map(Value).collect();
	let request = Request::read(rights.access, &views).map_err(Error::command)?;
	prepare(facet, &request)?.wire(facet, rooms_application::session::verbs::COMMAND)
}

pub(in crate::service) fn prepare<P: Platform>(
	facet: &Facet<P>,
	request: &Request<'_, impl rooms_application::room::ArgumentView>,
) -> Result<Revision, Error> {
	match request.route() {
		Route::Checkpoint(command) => {
			if let Some(answer) = super::invitations::handed(facet, command, request)? {
				return Ok(answer);
			}
			let mut arguments: Vec<DocumentText> = request.args().map(DocumentText::from).collect();
			let bridge = if command == Command::SubmitRoomBridgeForm {
				let submission = BridgeSubmission::inspect(&arguments).map_err(Error::invalid_by)?;
				let directory = facet.0.commands.view().read(|state| {
					let checkpoint = state.checkpoint()?;
					checkpoint
						.rooms()
						.find(|room| room.id.text() == submission.conversation())
						.map(|room| room.directory.text().clone())
						.ok_or_else(|| Error::stale("submitRoomBridgeForm names no room in this session"))
				})??;
				Some((directory, submission.scope().clone(), submission.secrets().clone()))
			} else {
				None
			};
			let id = operation_id(request.id())?;
			if let Some((directory, scope, secrets)) = bridge {
				let revision = (!secrets.is_empty()).then(|| id.text().clone());
				if let Some(revision) = &revision {
					arguments.push(revision.clone());
				}
				let bridge = crate::session::commands::BridgePreparation::new(
					directory,
					scope,
					secrets,
					revision,
					facet.0.bridge_secrets.clone(),
				);
				let admission = facet
					.0
					.commands
					.prepare_bridge_command(id, request.base(), arguments, bridge)?;
				return Ok(Revision::admitted(admission));
			}
			let admission = facet.0.commands.prepare_command(id, request.base(), command, arguments);
			if matches!(
				command,
				Command::ReplaceOperationsCapabilities | Command::ReplaceOperationsBundle
			) {
				let admission = admission?;
				let owner = facet.clone();
				Ok(Revision::new(async move {
					let revision = admission.send()?.wait().await?;
					// The reply follows the fetches this replacement started, so
					// the snapshot a caller reads next already shows their outcome.
					owner.settle_authority().await;
					Ok(revision)
				}))
			} else {
				Ok(Revision::admitted(admission?))
			}
		}
		Route::Effect(effect) => effects::apply(facet, effect, request),
		Route::Result(command) => results::apply(facet, command, request),
	}
}

/// The durable material a ledgered effect is remembered by: its name and
/// arguments as one JSON array.
pub fn material<A: AsRef<str>>(name: &str, args: &[A]) -> Result<DocumentText, Error> {
	let mut values = Vec::with_capacity(args.len() + 1);
	values.push(name);
	values.extend(args.iter().map(|a| a.as_ref()));
	serde_json::to_string(&values)
		.map(DocumentText::from)
		.map_err(Error::invalid_by)
}
