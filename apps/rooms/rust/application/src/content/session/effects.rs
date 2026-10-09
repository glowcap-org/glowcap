//! Owner-local receipt transitions. Shared access authorizes invocation; these
//! operations bind it to the original held source and immutable effect intent.
use super::custody::{EffectReceipt, EffectReceipts, Outcome, References};
use crate::{fields::Text, session::state::OperationId};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
	Unknown,
	Source,
	Intent,
	Capacity,
	Settled,
	Unresolved,
}

/// The witness covers receipts made through this exact source. Coordinates,
/// equal policies, operation IDs and a recovery grant cannot substitute for it.
/// Current ResolvePending admission is an additional shared-hosting check.
pub fn recover<'a, R: References>(
	receipts: &'a EffectReceipts<R>,
	operation: &OperationId,
	source: &R::SessionAccess,
) -> Result<&'a EffectReceipt<R>, Refusal>
where
	R::SessionAccess: PartialEq,
{
	let receipt = receipts
		.as_slice()
		.iter()
		.find(|receipt| &receipt.operation == operation)
		.ok_or(Refusal::Unknown)?;
	if &receipt.source.reference != source {
		return Err(Refusal::Source);
	}
	Ok(receipt)
}

/// Inspect before resolving targets. A retry uses the original held targets,
/// even when workspace intent or custody has since changed. Missing volatile
/// execution state never makes an unresolved durable receipt safe to resend.
pub fn inspect<'a, R: References>(
	receipts: &'a EffectReceipts<R>,
	operation: &OperationId,
	source: &R::SessionAccess,
	intent: &Text<262144, true>,
) -> Result<Option<&'a EffectReceipt<R>>, Refusal>
where
	R::SessionAccess: PartialEq,
{
	let receipt = match recover(receipts, operation, source) {
		Ok(receipt) => receipt,
		Err(Refusal::Unknown) => return Ok(None),
		Err(error) => return Err(error),
	};
	if &receipt.canonical_intent != intent {
		return Err(Refusal::Intent);
	}
	Ok(Some(receipt))
}

/// Install a new unresolved receipt in the candidate graph. Only terminal
/// receipts may leave the bounded replay window. Staging/commit belongs to
/// Loam; this transition cannot activate an external effect.
pub fn reserve<R: References>(
	receipts: &mut EffectReceipts<R>,
	receipt: EffectReceipt<R>,
	is_pinned: impl Fn(&OperationId) -> bool,
) -> Result<(), Refusal>
where
	R::SessionAccess: PartialEq,
{
	if !matches!(receipt.outcome, Outcome::Unresolved) {
		return Err(Refusal::Settled);
	}
	if inspect(
		receipts,
		&receipt.operation,
		&receipt.source.reference,
		&receipt.canonical_intent,
	)?
	.is_some()
	{
		return Err(Refusal::Unresolved);
	}
	if receipts.0.len() == super::custody::MAX_EFFECTS {
		let retired = receipts
			.0
			.iter()
			.position(|receipt| match &receipt.outcome {
				Outcome::Unresolved => false,
				Outcome::Committed { retained, .. } if !retained.is_empty() && !receipt.adopted => false,
				_ => !is_pinned(&receipt.operation),
			})
			.ok_or(Refusal::Capacity)?;
		receipts.0.remove(retired);
	}
	receipts.try_push(receipt).map_err(|_| Refusal::Capacity)
}

/// The owner gives up on one receipt: the explicit form of leaving the replay
/// window. Its outcome stays unknown for good, an unadopted result is forfeited,
/// and its reservations are freed. A receipt whose executor remains retained
/// cannot be released, because that executor could resume and settle a receipt nobody
/// holds. Like an evicted receipt, the operation ID must never be submitted
/// again; release itself never dispatches anything.
pub fn release<R: References>(
	receipts: &mut EffectReceipts<R>,
	operation: &OperationId,
	source: &R::SessionAccess,
	intent: &Text<262144, true>,
	executor_retained: bool,
) -> Result<(), Refusal>
where
	R::SessionAccess: PartialEq,
{
	inspect(receipts, operation, source, intent)?.ok_or(Refusal::Unknown)?;
	if executor_retained {
		return Err(Refusal::Unresolved);
	}
	receipts.0.retain(|receipt| &receipt.operation != operation);
	Ok(())
}

/// Private settlement changes only the identified original receipt. A terminal
/// result cannot be overwritten by a late worker or competing recovery call.
/// Revocation may block disclosure while this internal settlement still commits.
/// An identical retained outcome is a no-op, including recovery after an
/// indeterminate physical result write. This never admits another target act.
pub fn settle<R: References>(
	receipts: &mut EffectReceipts<R>,
	operation: &OperationId,
	source: &R::SessionAccess,
	intent: &Text<262144, true>,
	outcome: Outcome<R>,
) -> Result<bool, Refusal>
where
	R::SessionAccess: PartialEq,
	Outcome<R>: PartialEq,
{
	inspect(receipts, operation, source, intent)?.ok_or(Refusal::Unknown)?;
	if matches!(outcome, Outcome::Unresolved) {
		return Err(Refusal::Unresolved);
	}
	let receipt = receipts
		.0
		.iter_mut()
		.find(|receipt| &receipt.operation == operation)
		.expect("inspected receipt");
	if !matches!(receipt.outcome, Outcome::Unresolved) {
		return if receipt.outcome == outcome {
			Ok(false)
		} else {
			Err(Refusal::Settled)
		};
	}
	receipt.outcome = outcome;
	Ok(true)
}
