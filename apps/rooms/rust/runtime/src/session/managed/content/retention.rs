//! Private retention observation and atomic erasure acknowledgment.
use super::{records, refuse};
use glowcap::{Argument, Ref, Result, loam};
pub(super) fn invoke(call: &mut loam::Call<'_>, input: loam::Invocation<'_>, root: &Ref) -> Result<Argument> {
	if call.source()? != *root {
		return Err(refuse("private session root required"));
	}
	if input.verb == "settle-history-erasure" {
		return settle_erasure(call, input);
	}
	if !matches!(input.args, [Argument::Reference(_)]) {
		return Err(refuse("private retention observation required"));
	}
	let record = records::metadata(input)?;
	Ok(Argument::List(vec![
		Argument::Boolean(record.intent.keep_history),
		record.intent.history_erasure.map_or(Argument::Void, |operation| {
			operation.text().as_str().expect("operation text").into()
		}),
	]))
}
/// Only the private recording owner acknowledges durable erasure. The marker
/// and unresolved receipt change together, so startup can repeat erasure after
/// a lost storage reply without accidentally enabling a fresh recording.
fn settle_erasure(call: &mut loam::Call<'_>, input: loam::Invocation<'_>) -> Result<glowcap::Argument> {
	use rooms_application::{
		content::session::{custody::Outcome, effects},
		fields::{List, Text},
	};
	let [glowcap::Argument::Reference(_), glowcap::Argument::String(id)] = input.args else {
		return Err(loam::refusal("history erasure takes its operation identity"));
	};
	let mut record = super::records::decode(input)?;
	let receipt = record
		.effects
		.as_slice()
		.iter()
		.find(|receipt| receipt.operation.text().as_str() == Some(id))
		.ok_or_else(|| loam::refusal("unknown history erasure"))?;
	if record.intent.history_erasure.is_none() && matches!(receipt.outcome, Outcome::Committed { .. }) {
		return Ok(glowcap::Argument::Void);
	}
	if record.intent.keep_history || record.intent.history_erasure.as_ref() != Some(&receipt.operation) {
		return Err(loam::refusal("history erasure selection changed"));
	}
	let operation = receipt.operation.clone();
	let source = receipt.source.reference.clone();
	let intent = receipt.canonical_intent.clone();
	effects::settle(
		&mut record.effects,
		&operation,
		&source,
		&intent,
		Outcome::Committed {
			result: Text::new("null".into()).expect("local acknowledgment"),
			retained: List::default(),
		},
	)
	.map_err(|_| loam::refusal("history erasure settlement differs"))?;
	record.intent.history_erasure = None;
	super::records::replace(call, input, &mut record)?;
	Ok(glowcap::Argument::Void)
}
