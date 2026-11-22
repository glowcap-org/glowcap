//! Private supervision rechecks the original grant without consuming public
//! query debt. The root witness is mandatory, and a paused, revoked or
//! retired grant still refuses. Reads keep their ordinary requirements. A
//! workspace acquisition is the session's own custody write for a row that
//! grant was admitted to start, so it needs the grant's participation right
//! rather than custody management.
use super::*;

/// Whether the call arrived on the private continuation channel. Only
/// [`input`] decides whether that channel admits it.
pub(super) fn private(input: Invocation<'_>) -> bool {
	input.verb == "continue-workspace"
}

/// The session installs a row's callback and retires a lost route under the
/// grant that started the row. Every command that starts a supervised row
/// requires `InteractWorkspace`, so that right, and not `ManageCustody` or
/// `ReplaceWorkspace`, admits the session's follow-up write. The candidate is
/// built by the session from its own snapshot, never by the grant's holder.
pub(super) fn acquisition_requirement() -> Result<Requirement> {
	Requirement::new(&[Permission::InteractWorkspace.key()], &[])
}

pub(super) fn input<'a, P: Tasks + Deadline + Clone + 'static>(
	content: &SessionContent<P>,
	input: Invocation<'a>,
) -> Result<Invocation<'a>> {
	if !private(input) {
		return Ok(input);
	}
	super::super::retained::authorize(input, &content.owner(input.verb)?.writer.root()?)?;
	let method = match input.args.get(1) {
		Some(Argument::Integer(tag)) => rooms_application::content::session::continuing::Method::read(*tag),
		_ => None,
	}
	.ok_or_else(|| refuse("invalid private continuation method"))?;
	Ok(Invocation {
		verb: method.verb(),
		args: &input.args[2..],
		..input
	})
}
