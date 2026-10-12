//! Private supervision rechecks the original grant without consuming public
//! query debt. The root witness is mandatory. Permissions and selection still
//! pass through the ordinary snapshot and acquisition requirements.
use super::*;

pub(super) fn input<'a, P: Tasks + Deadline + Clone + 'static>(
	content: &SessionContent<P>,
	input: Invocation<'a>,
) -> Result<Invocation<'a>> {
	if input.verb != "continue-workspace" {
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
