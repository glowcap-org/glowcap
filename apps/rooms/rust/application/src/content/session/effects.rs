//! Owner-local receipt transitions. Shared access authorizes invocation. These
//! operations bind it to the original held source and immutable effect intent.
use super::custody::{Disposition, EffectReceipt, EffectReceipts, Outcome, References};
use crate::{fields::Text, session::state::OperationId};

/// Whose receipt an operation is, as the session answers the access asking.
/// The session answers with [`Holder::wire`] and the asking client reads it
/// back with [`Holder::from_wire`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Holder {
	/// The asking access sent the operation, and its receipt is still in the session's replay window.
	Mine,
	/// Another access sent it, which the asking one cannot look at.
	Another,
	/// The session holds no receipt of it: it was never sent, or its receipt
	/// left the bounded replay window. A released receipt answers for its
	/// sender until then.
	Nobody,
}

impl Holder {
	/// The word the `effect-holder` verb answers.
	pub const fn wire(self) -> &'static str {
		match self {
			Self::Mine => "mine",
			Self::Another => "another",
			Self::Nobody => "nobody",
		}
	}

	/// The holder an `effect-holder` answer names, or none for any other word.
	pub fn from_wire(word: &str) -> Option<Self> {
		[Self::Mine, Self::Another, Self::Nobody]
			.into_iter()
			.find(|holder| holder.wire() == word)
	}
}

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

/// Whether `receipt` committed a result its source has not adopted or
/// released. Only that source can adopt or release it, so the replay window
/// never evicts it.
pub fn awaits_adoption<R: References>(receipt: &EffectReceipt<R>) -> bool {
	receipt.disposition == Disposition::Held
		&& matches!(&receipt.outcome, Outcome::Committed { retained, .. } if !retained.is_empty())
}

/// Whether `receipt` keeps its place in the replay window, which [`reserve`]
/// never evicts: an unresolved receipt, whether or not an executor runs it,
/// or a result awaiting adoption. These are the receipts `held-effects`
/// lists for their source.
pub fn keeps_place<R: References>(receipt: &EffectReceipt<R>) -> bool {
	matches!(receipt.outcome, Outcome::Unresolved) || awaits_adoption(receipt)
}

/// Whether `receipt` holds its place in the replay window until its source
/// adopts or releases it: one that [`keeps_place`] and has no running
/// executor that could still settle it. These are the receipts a revoked
/// source's sweep releases.
pub fn holds_place<R: References>(receipt: &EffectReceipt<R>, running: bool) -> bool {
	keeps_place(receipt) && !(running && matches!(receipt.outcome, Outcome::Unresolved))
}

/// Install a new unresolved receipt in the candidate graph. Only terminal
/// receipts may leave the bounded replay window, and this eviction is the one
/// way any receipt leaves it, released ones included. A request sent again
/// after its receipt left runs again, and only an `Unknown` outcome leaves its
/// sender unable to tell whether the first one ran. So eviction takes the
/// oldest receipt with a known outcome, and the oldest `Unknown` one only when
/// no known one can leave. Staging/commit belongs to Loam. This transition
/// cannot activate an external effect.
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
		let leaves = |receipt: &EffectReceipt<R>| !keeps_place(receipt) && !is_pinned(&receipt.operation);
		let known = |receipt: &EffectReceipt<R>| !matches!(receipt.outcome, Outcome::Unknown { .. });
		let retired = receipts
			.0
			.iter()
			.position(|receipt| leaves(receipt) && known(receipt))
			.or_else(|| receipts.0.iter().position(leaves))
			.ok_or(Refusal::Capacity)?;
		receipts.0.remove(retired);
	}
	receipts.try_push(receipt).map_err(|_| Refusal::Capacity)
}

/// What a release did, as the session answers the access asking. The session
/// answers with [`Release::wire`] and the asking client reads it back with
/// [`Release::from_wire`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Release {
	/// The receipt is released, now or by an earlier release, or the session
	/// no longer holds it.
	Released,
	/// The receipt's executor is running, so the session changed nothing.
	/// Every run of an executor ends by itself within [`RUNNING_BOUND_MS`] of
	/// starting: it settles the receipt, pauses, or stops and leaves the
	/// receipt unresolved. A release asked again after that is answered
	/// released. The run of an upload filling its files after the post is the
	/// exception: it settles when its fill ends, however long that takes. A request whose commit is still pending answers running too,
	/// when the source's paused job waits on it and no receipt is held yet: it
	/// may still install, and the release asked again after the commit settles
	/// either retires the job or finds the receipt.
	Running,
	/// Its source adopted the receipt's result, so the workspace holds what it
	/// returned and the receipt holds no place. The release changed nothing.
	Kept,
}

impl Release {
	/// Every answer, in the order the browser mirror lists their words.
	pub const ALL: [Self; 3] = [Self::Released, Self::Running, Self::Kept];

	/// The word the release verbs answer.
	pub const fn wire(self) -> &'static str {
		match self {
			Self::Released => "released",
			Self::Running => "running",
			Self::Kept => "kept",
		}
	}

	/// The outcome a release answer names, or none for any other word.
	pub fn from_wire(word: &str) -> Option<Self> {
		Self::ALL.into_iter().find(|release| release.wire() == word)
	}
}

/// The reason a receipt released before its outcome was known carries. It is
/// a diagnostic for a person, and no code matches on it.
pub const RELEASED_UNKNOWN: &str = "released by its source before its outcome was known";

/// How long one run of an executor lasts at most before it settles, pauses,
/// or stops: [`OBSERVATION_PHASES`] observations of [`OBSERVATION_MS`] each.
/// Every wait of a run is one such observation, and the executor pauses when
/// one expires. An upload's staging and post, an archive share, and a bridge
/// each run inside a single observation. Only the request's source starts
/// another run, by resuming a paused executor. One run is longer: a room
/// upload's fill after its post is acknowledged. It never pauses. It runs in
/// rounds of [`FILL_ROUND_MS`] and ends when a round does not finish, so
/// its length follows the bytes it moves, and a receipt that answers running
/// past this bound has a fill whose rounds still finish. The Rooms
/// proofs' `session_executor/upload_bound.rs` holds an upload whose staging
/// wait expires to a pause that only its source's resume runs again, and
/// `upload_fill.rs` holds a fill longer than this bound in rounds within it.
pub const RUNNING_BOUND_MS: u64 = OBSERVATION_PHASES * OBSERVATION_MS;

/// How long one round of an upload's fill lasts at most. A round appends one
/// chunk of every unfinished file. The room renews a file's lease
/// ([`UPLOAD_IDLE_MS`](crate::files::UPLOAD_IDLE_MS)) when a write crosses a
/// multiple of the chunk size or finishes the file, which a whole chunk
/// always does and a short read may not. A file whose chunks come whole waits
/// less than two rounds between them, which is less than the lease, so a
/// fill that keeps this bound loses no such file to the lease. A round that
/// outlasts it ends the fill with the files incomplete.
///
/// The first round starts when the post's answer reaches the session, and the
/// room restarted every lease at the post. Nothing here bounds how long that
/// answer takes. If it takes more than `UPLOAD_IDLE_MS - FILL_ROUND_MS`, the
/// first write can arrive after the lease expires. The room then refuses it,
/// and the fill reports the files incomplete.
pub const FILL_ROUND_MS: u64 = 14_000;

// Within one uninterrupted observation, a staged file's lease lasts
// through the post. A pause can outlast it. The room restarts it at the post, and a file whose
// chunks come whole waits less than two rounds between them, strictly less
// than the lease, because the room ends a lease at its deadline.
const _: () = assert!(OBSERVATION_MS < crate::files::UPLOAD_IDLE_MS);
const _: () = assert!(2 * FILL_ROUND_MS < crate::files::UPLOAD_IDLE_MS);

/// How long the session waits on one observation of an executor before it
/// pauses the executor.
pub const OBSERVATION_MS: u64 = 20_000;

/// The most observations one run of an executor waits on in a row, each
/// bounded by [`OBSERVATION_MS`]. The longest path through the runtime's
/// executor is a manager recovery: confirming the receipt's commit, reading
/// the identity, executing the call, acquiring the result, settling the
/// receipt, and closing the membership it retires. Every other path skips
/// some of these.
pub const OBSERVATION_PHASES: u64 = 6;

/// What [`release`] did to the receipts, which decides whether the session
/// writes them and what it answers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Released {
	/// The receipt's executor is running, and nothing changed.
	Running,
	/// The receipt is released now.
	Now,
	/// An earlier release already released it, and nothing changed.
	Before,
	/// Its result was adopted, and nothing changed.
	Kept,
}

impl Released {
	/// The answer the release verbs give.
	pub const fn answer(self) -> Release {
		match self {
			Self::Running => Release::Running,
			Self::Now | Self::Before => Release::Released,
			Self::Kept => Release::Kept,
		}
	}
}

/// The source gives up on one receipt. A release never deletes a receipt:
/// only the replay window's eviction does ([`reserve`]), as for any terminal
/// receipt. An unresolved receipt settles to [`Outcome::Unknown`] with
/// [`RELEASED_UNKNOWN`], so its outcome stays unknown for good. An unadopted
/// result is forfeited. Either way its retained references and reservations
/// are freed, and the receipt answers for its operation until it is evicted:
/// a resubmission is answered from it and never dispatches. After eviction
/// the operation id must never be submitted again, as for any settled
/// receipt. A receipt whose executor is `running` stays as it is, because
/// that executor would settle a receipt its source gave up. A paused executor
/// is retired by the session after this release. An adopted receipt stays as
/// it is and answers [`Released::Kept`], because the workspace holds its
/// result and a release must never erase that. Release itself never
/// dispatches anything, and a second release changes nothing.
pub fn release<R: References>(
	receipts: &mut EffectReceipts<R>,
	operation: &OperationId,
	source: &R::SessionAccess,
	intent: &Text<262144, true>,
	running: bool,
) -> Result<Released, Refusal>
where
	R::SessionAccess: PartialEq,
{
	let held = inspect(receipts, operation, source, intent)?.ok_or(Refusal::Unknown)?;
	if held.disposition == Disposition::Adopted {
		return Ok(Released::Kept);
	}
	if running {
		return Ok(Released::Running);
	}
	let receipt = receipts
		.0
		.iter_mut()
		.find(|receipt| &receipt.operation == operation)
		.ok_or(Refusal::Unknown)?;
	if receipt.disposition == Disposition::Released {
		return Ok(Released::Before);
	}
	match &mut receipt.outcome {
		Outcome::Unresolved => {
			receipt.outcome = Outcome::Unknown {
				reason: Text::new(RELEASED_UNKNOWN.into()).ok_or(Refusal::Capacity)?,
			};
		}
		Outcome::Committed { retained, .. } => retained.0.clear(),
		Outcome::Unknown { .. } | Outcome::KnownAbsent | Outcome::Refused { .. } => {}
	}
	receipt.disposition = Disposition::Released;
	Ok(Released::Now)
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
		.ok_or(Refusal::Unknown)?;
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

#[cfg(test)]
mod tests {
	use super::{Holder, Release};

	#[test]
	fn each_holder_reads_back_from_its_wire_word_and_no_other_word_reads() {
		for holder in [Holder::Mine, Holder::Another, Holder::Nobody] {
			assert_eq!(Holder::from_wire(holder.wire()), Some(holder));
		}
		assert_eq!(Holder::from_wire("Mine"), None);
		assert_eq!(Holder::from_wire(""), None);
	}

	#[test]
	fn each_release_reads_back_from_its_wire_word_and_no_other_word_reads() {
		for release in Release::ALL {
			assert_eq!(Release::from_wire(release.wire()), Some(release));
		}
		assert_eq!(Release::from_wire("Released"), None);
		assert_eq!(Release::from_wire(""), None);
	}
}
