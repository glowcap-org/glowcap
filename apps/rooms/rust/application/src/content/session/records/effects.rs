//! Receipt fields retain the original mediation source, targets and result.
use super::super::custody::{self, Coordinate, EffectReceipt, FieldKey, Outcome, References, Retained, RetainedField};
use super::{EFFECT, Error, Page, RestoredPage, check_fields, pages};
use crate::{
	fields::{List, Text},
	session::state::OperationId,
};
use alloc::{borrow::Cow, vec::Vec};
use core::num::NonZeroU64;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Data<'a> {
	version: super::super::workspace::Version,
	operation: Cow<'a, OperationId>,
	canonical_intent: Cow<'a, Text<262144, true>>,
	attachment_generation: NonZeroU64,
	source: FieldKey<custody::SessionAccess>,
	targets: List<Coordinate, { custody::MAX_TARGET_FIELDS }>,
	outcome: State,
	result: Option<Cow<'a, Text<32768>>>,
	retained: List<Coordinate, { custody::MAX_RESULT_FIELDS }>,
}
#[derive(Serialize, Deserialize)]
enum State {
	Unresolved,
	KnownAbsent,
	Committed,
}

pub fn encode_effect<R: References>(receipt: &EffectReceipt<R>) -> Result<Vec<Page<'_, R>>, Error> {
	let mut fields = Vec::new();
	fields.push(Retained::SessionAccess(&receipt.source));
	fields.extend(receipt.targets.0.iter().map(RetainedField::borrowed));
	let (outcome, result, retained) = match &receipt.outcome {
		Outcome::Unresolved => (State::Unresolved, None, Vec::new()),
		Outcome::KnownAbsent => (State::KnownAbsent, None, Vec::new()),
		Outcome::Committed { result, retained } => {
			fields.extend(retained.0.iter().map(RetainedField::borrowed));
			(
				State::Committed,
				Some(Cow::Borrowed(result)),
				retained.0.iter().map(|field| field.borrowed().coordinate()).collect(),
			)
		}
	};
	let data = Data {
		version: super::super::workspace::Version::V1,
		operation: Cow::Borrowed(&receipt.operation),
		canonical_intent: Cow::Borrowed(&receipt.canonical_intent),
		attachment_generation: receipt.attachment_generation,
		source: receipt.source.key,
		targets: List::new(
			receipt
				.targets
				.0
				.iter()
				.map(|field| field.borrowed().coordinate())
				.collect(),
		)
		.ok_or(Error::Capacity)?,
		outcome,
		result,
		retained: List::new(retained).ok_or(Error::Capacity)?,
	};
	let mut output: Vec<_> = pages::encode(EFFECT.id, &serde_json::to_vec(&data)?)?
		.into_iter()
		.map(|payload| Page {
			payload,
			fields: Vec::new(),
		})
		.collect();
	output[0].fields = fields;
	Ok(output)
}
pub fn decode_effect<R: References>(input: Vec<RestoredPage<R>>) -> Result<EffectReceipt<R>, Error> {
	let payloads: Vec<_> = input.iter().map(|page| page.payload.as_slice()).collect();
	let body = pages::decode(EFFECT.id, &payloads)?;
	let data: Data<'_> = serde_json::from_slice(&body)?;
	if input.iter().skip(1).any(|page| !page.fields.is_empty()) {
		return Err(Error::Fields);
	}
	let coordinates: Vec<_> = core::iter::once(Coordinate {
		role: custody::Role::SessionAccess,
		key: FieldKey::new(data.source.slot(), data.source.generation()),
	})
	.chain(data.targets.0.iter().copied())
	.chain(data.retained.0.iter().copied())
	.collect();
	let mut input = input.into_iter();
	let fields = input.next().ok_or(Error::Format)?.fields;
	check_fields(&coordinates, &fields)?;
	let mut fields = fields.into_iter();
	let source = match fields.next() {
		Some(RetainedField::SessionAccess(field)) => field,
		_ => return Err(Error::Fields),
	};
	let targets = List::new(fields.by_ref().take(data.targets.0.len()).collect()).ok_or(Error::Capacity)?;
	let retained = List::new(fields.collect()).ok_or(Error::Capacity)?;
	let outcome = match (data.outcome, data.result) {
		(State::Committed, Some(result)) => Outcome::Committed {
			result: result.into_owned(),
			retained,
		},
		(State::Unresolved, None) if retained.0.is_empty() => Outcome::Unresolved,
		(State::KnownAbsent, None) if retained.0.is_empty() => Outcome::KnownAbsent,
		_ => return Err(Error::Format),
	};
	Ok(EffectReceipt {
		operation: data.operation.into_owned(),
		canonical_intent: data.canonical_intent.into_owned(),
		attachment_generation: data.attachment_generation,
		source,
		targets,
		outcome,
	})
}
