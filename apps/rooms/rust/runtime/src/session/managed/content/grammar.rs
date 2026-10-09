//! Bounded command envelopes and canonical receipt material.
use super::*;
pub(super) fn operation(value: &Argument) -> Result<rooms_application::session::state::OperationId> {
	Text::new(text(value)?.into()).ok_or_else(|| refuse("invalid effect operation id"))
}
pub(in crate::session::managed) fn values(args: &[Argument]) -> Vec<Value<'_>> {
	rooms_glowcap::values(args).collect()
}
pub(super) fn command_requirement(args: &[Argument], additional: &[Permission]) -> Result<Requirement> {
	let values = values(args);
	let request = Request::parse(&values).map_err(|error| loam::refusal(error.to_string()))?;
	let required = requirements::command(request.route()).ok_or_else(|| refuse("retired session command"))?;
	let mut permissions: Vec<_> = required.workspace.iter().map(|permission| permission.key()).collect();
	for permission in required
		.conditional
		.iter()
		.flat_map(|conditional| conditional.workspace())
		.chain(additional)
	{
		if !permissions.contains(&permission.key()) {
			permissions.push(permission.key());
		}
	}
	Requirement::new(&permissions, &[])
}
pub(super) fn canonical(args: &[Argument]) -> Result<String> {
	let values = values(args);
	let request = Request::parse(&values).map_err(|error| loam::refusal(error.to_string()))?;
	request.canonical().map_err(|_| refuse("invalid command intent"))
}
pub(super) fn dispatch(args: &[Argument]) -> Result<Dispatch> {
	let declared = values(args);
	let request = Request::parse(&declared).map_err(|error| loam::refusal(error.to_string()))?;
	Dispatch::parse(&request).map_err(|_| refuse("session effect is invalid or not registered"))
}
pub(super) fn original(value: &Argument) -> Result<Vec<Argument>> {
	original_text(text(value)?)
}
pub(in crate::session::managed) fn original_text(value: &str) -> Result<Vec<Argument>> {
	let (id, base, name, rest): (String, u64, String, Vec<String>) =
		serde_json::from_str(value).map_err(|_| refuse("invalid original effect intent"))?;
	let base = i64::try_from(base).map_err(|_| refuse("invalid original command revision"))?;
	let mut args = vec![id.into(), Argument::Integer(base), name.into()];
	args.extend(rest.into_iter().map(Argument::String));
	if canonical(&args)? != value {
		return Err(refuse("effect intent is not canonical"));
	}
	Ok(args)
}
