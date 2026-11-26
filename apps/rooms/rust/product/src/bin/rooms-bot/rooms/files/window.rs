//! The stand-in's receipt window, run by the session's own rules. The
//! stand-in keeps its receipts as plain rows (`receipts`), and each question
//! about the window (which receipts keep a place, which one a new receipt
//! evicts, what a release answers) builds the session's receipts from those
//! rows and asks `rooms_application::content::session::effects`, so the
//! stand-in cannot answer differently from the session. The agent's actions
//! and direct-message opens (`held-actions`, `held-opens`) share the window
//! as unresolved receipts.
use super::{
	super::{RoomsError, RoomsErrorKind},
	receipts::{Receipt, Status},
};
use rooms_application::{
	content::session::{
		custody::{self, Disposition, EffectReceipt, EffectReceipts, Held, Outcome, RetainedField},
		effects::{self, Refusal, Released},
	},
	failure::FailureCode,
	fields::{List, Text},
};

/// Every role holds a unit, because the stand-in has one access and no
/// capability to retain.
struct Plain;

macro_rules! roles {
	($($role:ident),*) => {
		impl custody::References for Plain { $(type $role = ();)* }
	};
}
roles!(
	SessionAccess,
	SessionControl,
	RoomAccess,
	DirectoryAccess,
	DirectAccess,
	DirectInbox,
	ArchiveAccess,
	Operator,
	Operations,
	IrcConnection,
	Offer,
	AcceptedAccess,
	RoomControl,
	ArchiveControl,
	CreationReceipt,
	PublicationLease,
	RoomSeat,
	RoomSubject,
	RoomInbox,
	RoomFiles,
	Line,
	DirectoryName,
	DirectoryInbox,
	SourceBlob
);

fn unfit(what: &str) -> RoomsError {
	RoomsError::new(
		RoomsErrorKind::Unreachable,
		format!("the stand-in's {what} is outside the session's bounds"),
	)
}

fn key<K>() -> custody::FieldKey<K> {
	custody::FieldKey::new(std::num::NonZeroU64::MIN, std::num::NonZeroU64::MIN)
}

fn held<K, C>(reference: C) -> Held<K, C> {
	Held { key: key(), reference }
}

/// The session's receipt for an operation, in the given state.
fn effect(
	operation: &str,
	intent: &str,
	disposition: Disposition,
	outcome: Outcome<Plain>,
) -> Result<EffectReceipt<Plain>, RoomsError> {
	Ok(EffectReceipt {
		operation: Text::new(operation.into()).ok_or_else(|| unfit("operation"))?,
		disposition,
		outgoing: None,
		introduction: None,
		canonical_intent: Text::new(intent.into()).ok_or_else(|| unfit("intent"))?,
		resource_generation: std::num::NonZeroU64::MIN,
		source: held(()),
		targets: List::default(),
		outcome,
	})
}

/// A result the receipt holds for its source to adopt, or none once released.
fn committed(retains: bool) -> Result<Outcome<Plain>, RoomsError> {
	let fields = if retains {
		vec![RetainedField::Line(held(()))]
	} else {
		Vec::new()
	};
	Ok(Outcome::Committed {
		result: Text::default(),
		retained: List::new(fields).ok_or_else(|| unfit("result"))?,
	})
}

/// The session's receipt for one of the stand-in's line receipts.
fn line(receipt: &Receipt) -> Result<EffectReceipt<Plain>, RoomsError> {
	let (disposition, outcome) = match (receipt.status, receipt.kept, receipt.released) {
		(Status::Pending, ..) | (Status::Unknown, _, false) => (Disposition::Held, Outcome::Unresolved),
		(Status::Unknown, _, true) => (
			Disposition::Released,
			Outcome::Unknown {
				reason: Text::new(effects::RELEASED_UNKNOWN.into()).ok_or_else(|| unfit("reason"))?,
			},
		),
		(Status::Committed, true, _) => (Disposition::Adopted, committed(true)?),
		(Status::Committed, false, true) => (Disposition::Released, committed(false)?),
		(Status::Committed, false, false) => (Disposition::Held, committed(true)?),
		(Status::Unsent, ..) => (Disposition::Held, Outcome::KnownAbsent),
	};
	let intent = format!("{} {} {}", receipt.base, receipt.conversation, receipt.text);
	effect(&receipt.operation, &intent, disposition, outcome)
}

/// An action's or open's receipt, which the source has neither adopted nor
/// released.
fn unresolved(operation: &str) -> Result<EffectReceipt<Plain>, RoomsError> {
	effect(operation, operation, Disposition::Held, Outcome::Unresolved)
}

/// The session's refusal of a receipt when no receipt may leave the window.
fn full(_: Refusal) -> RoomsError {
	RoomsError {
		refused_before_dispatch: true,
		..RoomsError::new(
			RoomsErrorKind::Unreachable,
			FailureCode::ReceiptsFull.line("the stand-in holds no free receipt place"),
		)
	}
}

/// The receipts of `lines` that keep a place, which are the ones the
/// session's list of held receipts names.
pub fn keeping(lines: &[Receipt]) -> Result<Vec<String>, RoomsError> {
	let mut keeping = Vec::new();
	for receipt in lines {
		if effects::keeps_place(&line(receipt)?) {
			keeping.push(receipt.operation.clone());
		}
	}
	Ok(keeping)
}

/// Hold `receipt` among `lines`, with the operations in `others` (actions
/// and opens) sharing the window. The session's own reservation evicts the
/// oldest receipt that may go, or refuses a new one before dispatch when none
/// may. `lines` keeps the receipts the window still holds.
pub fn reserve(lines: &mut Vec<Receipt>, others: &[String], receipt: Receipt) -> Result<(), RoomsError> {
	let mut window = EffectReceipts::<Plain>::default();
	for held in lines.iter() {
		window.try_push(line(held)?).map_err(|_| unfit("window"))?;
	}
	for operation in others {
		effects::reserve(&mut window, unresolved(operation)?, |_| false).map_err(full)?;
	}
	// The session reserves a receipt unresolved, and it settles afterwards.
	let mut reserved = line(&receipt)?;
	reserved.disposition = Disposition::Held;
	reserved.outcome = Outcome::Unresolved;
	effects::reserve(&mut window, reserved, |_| false).map_err(full)?;
	lines.retain(|held| {
		Text::new(held.operation.as_str().into())
			.is_some_and(|operation| window.as_slice().iter().any(|kept| kept.operation == operation))
	});
	lines.push(receipt);
	Ok(())
}

/// What the session answers when the source releases the receipt at `index`,
/// which the caller applies.
pub fn release(lines: &[Receipt], index: usize) -> Result<Released, RoomsError> {
	let mut window = EffectReceipts::<Plain>::default();
	for held in lines {
		window.try_push(line(held)?).map_err(|_| unfit("window"))?;
	}
	let held = &lines[index];
	let receipt = line(held)?;
	effects::release(
		&mut window,
		&receipt.operation,
		&(),
		&receipt.canonical_intent,
		held.status == Status::Pending,
	)
	.map_err(|refusal| {
		RoomsError::new(
			RoomsErrorKind::Refused,
			format!("the session refuses the release: {refusal:?}"),
		)
	})
}
