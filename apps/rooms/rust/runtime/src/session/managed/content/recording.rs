//! Recording admission fixes a scalar selection without restoring its writer.
use super::{MetadataRecord, records, refuse};
use crate::archive::session::Destination;
use glowcap::{
	Argument, Ref, Result,
	loam::{Call, Invocation},
};
use rooms_glowcap::client::{Deadline, Tasks};
use std::rc::Rc;

pub(super) fn authorize(input: Invocation<'_>, root: &Ref) -> Result<()> {
	super::super::retained::authorize(input, root)
}
pub(super) fn callback(input: Invocation<'_>) -> Result<Invocation<'_>> {
	if input.args.len() != 3 {
		return Err(refuse("private recording takes owner, selection and callback"));
	}
	Ok(Invocation {
		args: &input.args[1..],
		..input
	})
}
/// Read canonical intent once at admission. Only private workers retain the
/// exact target coordinate. Restoration cannot hold up the admitted message.
pub(in crate::session::managed) fn destination<P: Tasks + Deadline + Clone + 'static>(
	owner: &Rc<super::super::State<P>>,
	record: &MetadataRecord,
) -> Result<Option<Destination>> {
	if !record.intent.keep_history || record.intent.history_erasure.is_some() {
		return Ok(None);
	}
	match record.intent.archive {
		None => Ok(Some(Destination::Device)),
		Some(key) => Ok(Some(super::super::recording::destination::selected(
			owner.writer.clone(),
			owner.platform.clone(),
			key,
		))),
	}
}
pub(super) fn invoke(call: &mut Call<'_>, input: Invocation<'_>, root: &Ref) -> Result<Argument> {
	authorize(input, root)?;
	super::inbox::invoke(call, callback(input)?)?;
	let record = records::metadata(input)?;
	if !record.intent.keep_history || record.intent.history_erasure.is_some() {
		return Ok(Argument::Boolean(false));
	}
	record.intent.archive.map_or(Ok(Argument::Void), |key| {
		serde_json::to_string(&key)
			.map(Argument::String)
			.map_err(|_| refuse("invalid recording target"))
	})
}
