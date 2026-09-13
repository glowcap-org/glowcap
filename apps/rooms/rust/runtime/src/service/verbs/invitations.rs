//! Live offers and saved invitations share the public command envelope.
use super::checkpoint::operation_id;
use crate::service::Platform;
use crate::service::error::Error;
use crate::service::facet::Facet;
use crate::service::revision::Revision;
use rooms_application::session::{
	checkpoint::{commands::Command, reconciliation::Id},
	command::Request,
};

/// A consumed live offer falls back to the ordinary checkpoint path, whose
/// ledger recognizes an exact completed retry before looking for an invitation.
pub fn handed<P: Platform>(
	facet: &Facet<P>,
	command: Command,
	request: &Request<'_, impl rooms_application::room::ArgumentView>,
) -> Result<Option<Revision>, Error> {
	let arity = match command {
		Command::AcceptInvitation => 2,
		Command::DismissInvitation => 1,
		_ => return Ok(None),
	};
	let mut arguments = request.args();
	if arguments.len() != arity {
		return Err(Error::invalid(
			"invitation command received the wrong number of arguments",
		));
	}
	let id = Id::new(arguments.next().expect("checked invitation arity").into())
		.ok_or_else(|| Error::invalid("invalid invitation id"))?;
	if !facet.0.handed.contains(&id) {
		return Ok(None);
	}
	let operation = operation_id(request.id())?;
	if command == Command::DismissInvitation {
		facet.0.handed.decline(&id);
		let revision = facet.0.commands.view().read(|state| state.revision())??;
		return Ok(Some(Revision::ready(revision)));
	}
	let conversation = Id::new(arguments.next().expect("checked acceptance arity").into())
		.ok_or_else(|| Error::invalid("invalid conversation id"))?;
	let handed = facet.0.handed.clone();
	let base = request.base();
	Ok(Some(Revision::new(async move {
		let acceptance = handed.accept(operation, base, id, conversation)?;
		let revision = acceptance.wait().await?;
		Ok(revision)
	})))
}
