//! Receipt fields retain the original mediation source, targets and result.
use super::super::custody::{self, Coordinate, EffectReceipt, FieldKey, Outcome, References, Retained, RetainedField};
use super::{EFFECT, Error, Page, RestoredPage, pages};
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
	adopted: bool,
	outgoing: Option<Cow<'a, super::super::outgoing::Update>>,
	introduction: Option<Cow<'a, super::super::workspace::Introduction>>,
	canonical_intent: Cow<'a, Text<262144, true>>,
	resource_generation: NonZeroU64,
	source: FieldKey<custody::SessionAccess>,
	targets: List<Coordinate, { custody::MAX_TARGET_FIELDS }>,
	outcome: State,
	result: Option<Cow<'a, Text<32768>>>,
	#[serde(default, skip_serializing_if = "Option::is_none")]
	reason: Option<Cow<'a, Text<{ custody::MAX_OBSERVATION_REASON_UNITS }, true>>>,
	retained: List<Coordinate, { custody::MAX_RESULT_FIELDS }>,
}
#[derive(Serialize, Deserialize)]
enum State {
	Unresolved,
	Unknown,
	KnownAbsent,
	Committed,
}

pub fn encode_effect<R: References>(receipt: &EffectReceipt<R>) -> Result<Vec<Page<'_, R>>, Error> {
	let mut fields = Vec::new();
	fields.push(Retained::SessionAccess(&receipt.source));
	fields.extend(receipt.targets.0.iter().map(RetainedField::borrowed));
	let (outcome, result, retained) = match &receipt.outcome {
		Outcome::Unresolved => (State::Unresolved, None, Vec::new()),
		Outcome::Unknown { .. } => (State::Unknown, None, Vec::new()),
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
		adopted: receipt.adopted,
		outgoing: receipt.outgoing.as_ref().map(Cow::Borrowed),
		introduction: receipt.introduction.as_ref().map(Cow::Borrowed),
		canonical_intent: Cow::Borrowed(&receipt.canonical_intent),
		resource_generation: receipt.resource_generation,
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
		reason: match &receipt.outcome {
			Outcome::Unknown { reason } => Some(Cow::Borrowed(reason)),
			_ => None,
		},
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
	if input.iter().skip(1).any(|page| !page.fields.is_empty()) {
		return Err(Error::Fields);
	}
	let payloads: Vec<_> = input.iter().map(|page| page.payload.as_slice()).collect();
	let body = pages::decode(EFFECT.id, &payloads)?;
	let data: Data<'static> = serde_json::from_slice(&body)?;
	let mut fields = input.into_iter().next().ok_or(Error::Format)?.fields.into_iter();
	assemble(data, fields.len(), |_, _| fields.next().ok_or(Error::Fields))
}
pub(super) fn restore<R: References>(
	payloads: &[&[u8]],
	field_count: usize,
	restore: impl FnMut(Coordinate, usize) -> Result<RetainedField<R>, Error>,
) -> Result<EffectReceipt<R>, Error> {
	let body = pages::decode(EFFECT.id, payloads)?;
	let data: Data<'_> = serde_json::from_slice(&body)?;
	assemble(data, field_count, restore)
}
fn coordinates<'a>(data: &'a Data<'_>) -> impl Iterator<Item = Coordinate> + 'a {
	core::iter::once(Coordinate {
		role: custody::Role::SessionAccess,
		key: FieldKey::new(data.source.slot(), data.source.generation()),
	})
	.chain(data.targets.0.iter().copied())
	.chain(data.retained.0.iter().copied())
}
fn assemble<R: References>(
	data: Data<'_>,
	field_count: usize,
	mut restore: impl FnMut(Coordinate, usize) -> Result<RetainedField<R>, Error>,
) -> Result<EffectReceipt<R>, Error> {
	if field_count != 1 + data.targets.0.len() + data.retained.0.len() {
		return Err(Error::Fields);
	}
	match (&data.outcome, &data.result, &data.reason) {
		(State::Committed, Some(_), None) => {}
		(State::Unknown, None, Some(_)) if data.retained.0.is_empty() => {}
		(State::Unresolved | State::KnownAbsent, None, None) if data.retained.0.is_empty() => {}
		_ => return Err(Error::Format),
	}
	if data.adopted && !matches!(data.outcome, State::Committed) {
		return Err(Error::Format);
	}
	let mut fields = coordinates(&data).enumerate().map(|(index, coordinate)| {
		let field = restore(coordinate, index)?;
		if field.borrowed().coordinate() != coordinate {
			return Err(Error::Fields);
		}
		Ok(field)
	});
	let source = match fields.next().transpose()? {
		Some(RetainedField::SessionAccess(field)) => field,
		_ => return Err(Error::Fields),
	};
	let targets =
		List::new(fields.by_ref().take(data.targets.0.len()).collect::<Result<_, _>>()?).ok_or(Error::Capacity)?;
	let retained = List::new(fields.by_ref().collect::<Result<_, _>>()?).ok_or(Error::Capacity)?;
	drop(fields);
	let outcome = match (data.outcome, data.result, data.reason) {
		(State::Unknown, None, Some(reason)) if retained.0.is_empty() => Outcome::Unknown {
			reason: reason.into_owned(),
		},
		(State::Committed, Some(result), None) => Outcome::Committed {
			result: result.into_owned(),
			retained,
		},
		(State::Unresolved, None, None) if retained.0.is_empty() => Outcome::Unresolved,
		(State::KnownAbsent, None, None) if retained.0.is_empty() => Outcome::KnownAbsent,
		_ => return Err(Error::Format),
	};
	Ok(EffectReceipt {
		operation: data.operation.into_owned(),
		adopted: data.adopted,
		outgoing: data.outgoing.map(Cow::into_owned),
		introduction: data.introduction.map(Cow::into_owned),
		canonical_intent: data.canonical_intent.into_owned(),
		resource_generation: data.resource_generation,
		source,
		targets,
		outcome,
	})
}
