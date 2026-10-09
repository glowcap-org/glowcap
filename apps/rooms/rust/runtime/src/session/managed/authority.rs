//! The existing charged inbox worker waits for exact authority retirement.
//! No separate task, queue or publication identity inventory owns revocation.
use super::executor::Writer;
use glowcap::{Argument, Ref, Result, loam};
use rooms_application::{content::session::workspace::InboxSelection, room::inbox};
use rooms_glowcap::{
	Value,
	client::{Deadline, workspace::Workspace},
};
use std::rc::Rc;

pub(super) async fn retire<P: Deadline + Clone>(
	writer: &Rc<Writer>,
	workspace: &Workspace<P>,
	selected: &InboxSelection,
	installed: &Ref,
	verb: &str,
	args: &[Argument],
) -> Result<()> {
	if !matches!(selected, InboxSelection::Room { .. })
		|| args.get(2).and_then(Argument::as_str) != Some(inbox::AUTHORITY_CHANGED)
	{
		return Ok(());
	}
	let mut values = [Value(&Argument::Void); 6];
	if args.len() != values.len() {
		return Err(loam::refusal("invalid authority notification"));
	}
	for (value, argument) in values.iter_mut().zip(args) {
		*value = Value(argument);
	}
	let inbox::Notice::Authority { kind, token, .. } =
		inbox::read(verb, &values).map_err(|error| loam::refusal(error.to_string()))?
	else {
		return Err(loam::refusal("authority notification required"));
	};
	let role = match kind {
		rooms_application::room::stewardship::Kind::Room => "room",
		rooms_application::room::stewardship::Kind::Steward => "steward",
		rooms_application::room::stewardship::Kind::Manager => "manager",
	};
	// Only authority notifications pay this bounded ingress copy. The existing
	// callback charge retains the original notice through admission and commit.
	let encoded = serde_json::to_string(selected).map_err(|_| loam::refusal("invalid authority selection"))?;
	let arguments = [
		writer.root()?.into(),
		encoded.into(),
		installed.clone().into(),
		role.into(),
		token.into(),
	];
	// A missed answer cannot prove whether canonical retirement committed.
	// The enclosing inbox select cancels this wait when its owner stops. Keep
	// the original future and charged notice; no timer loop or second send is
	// needed while its exact commitment remains unknown.
	let result = writer
		.host
		.send(workspace.reference(), "retire-room-authority", &arguments)
		.await?;
	if result != Argument::Void {
		return Err(loam::refusal("invalid authority retirement acknowledgment"));
	}
	Ok(())
}
