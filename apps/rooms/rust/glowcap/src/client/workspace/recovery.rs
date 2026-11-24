//! Receipt recovery holds the original source and canonical intent. Inventory
//! rows describe only that source's receipts and cannot restore other authority.
use super::*;
use rooms_application::content::session::custody::MAX_EFFECTS;

pub struct EffectEntry {
	pub operation: String,
	pub status: EffectStatus,
	pub resumable: bool,
	/// Its source gave the receipt up. It stays only to answer a resubmission
	/// until the replay window evicts it, and nothing is left to decide.
	pub released: bool,
}
pub use rooms_application::content::session::effects::{Holder, Release};

/// What a release verb answered. Any word that is not a [`Release`] is an
/// invalid answer, never a release.
pub(super) fn read_release(reply: &Argument) -> Result<Release, Error> {
	reply
		.as_str()
		.and_then(Release::from_wire)
		.ok_or_else(|| loam::refusal("invalid effect release answer").into())
}

/// `operation` when it is an identity the session accepts for an effect.
fn identity(operation: &str) -> Result<&str, Error> {
	if rooms_application::session::state::OperationId::accepts_utf16(operation.encode_utf16()) {
		Ok(operation)
	} else {
		Err(loam::refusal("invalid effect identity").into())
	}
}

/// One canonical intent moves from the admitted Loam reply into this owner.
/// The original endpoint remains held for status, result and explicit resume.
/// An operation ID alone never selects authority or permits fresh dispatch.
pub struct RecoveredEffect<D> {
	caller: Caller<D>,
	source: Ref,
	operation: String,
	canonical: String,
}
impl<D: Deadline + Clone> Workspace<D> {
	pub async fn effects(&self) -> Result<Vec<EffectEntry>, Error> {
		#[derive(serde::Deserialize)]
		#[serde(deny_unknown_fields)]
		struct Entry {
			operation: String,
			status: String,
			resumable: bool,
			released: bool,
		}
		let reply = self.call("effect-inventory", &[]).await?;
		let rows: Vec<Entry> = serde_json::from_str(
			reply
				.as_str()
				.ok_or_else(|| loam::refusal("invalid effect inventory"))?,
		)
		.map_err(|_| loam::refusal("invalid effect inventory"))?;
		if rows.len() > MAX_EFFECTS {
			return Err(loam::refusal("effect inventory exceeds its bound").into());
		}
		rows.into_iter()
			.map(|row| {
				identity(&row.operation)?;
				Ok(EffectEntry {
					operation: row.operation,
					status: EffectStatus::read(&row.status.into())?,
					resumable: row.resumable,
					released: row.released,
				})
			})
			.collect()
	}
	/// Whose receipt `operation` is. A read that reveals no more than the
	/// receipt's existence, and never sends, resumes, or changes anything.
	pub async fn effect_holder(&self, operation: &str) -> Result<Holder, Error> {
		identity(operation)?;
		self.call("effect-holder", &[operation.into()])
			.await?
			.as_str()
			.and_then(Holder::from_wire)
			.ok_or_else(|| loam::refusal("invalid effect holder").into())
	}
	/// The operations of this access's own receipts that still keep a place in
	/// the session's replay window: unresolved ones, and committed ones whose
	/// result is not adopted yet. A read that names no status, so an access
	/// whose rights were narrowed learns only that its own request still holds
	/// a place, and never sends, resumes, or changes anything.
	pub async fn held_effects(&self) -> Result<Vec<String>, Error> {
		let Argument::List(rows) = self.call("held-effects", &[]).await? else {
			return Err(loam::refusal("invalid held effects").into());
		};
		if rows.len() > MAX_EFFECTS {
			return Err(loam::refusal("held effects exceed their bound").into());
		}
		rows.into_iter()
			.map(|row| {
				let Argument::String(operation) = row else {
					return Err(loam::refusal("invalid held effects").into());
				};
				identity(&operation)?;
				Ok(operation)
			})
			.collect()
	}
	/// None means the receipt was already adopted or released, or left the
	/// bounded replay window. It grants no permission to prepare or resend the original effect.
	pub async fn recover_effect(&self, operation: &str) -> Result<Option<RecoveredEffect<D>>, Error> {
		identity(operation)?;
		let reply = self.call("effect-intent", &[operation.into()]).await?;
		if matches!(reply, Argument::Void) {
			return Ok(None);
		}
		let Argument::String(canonical) = reply else {
			return Err(loam::refusal("invalid original effect intent").into());
		};
		if !rooms_application::fields::Text::<262144, true>::accepts_utf16(canonical.encode_utf16()) {
			return Err(loam::refusal("original effect intent exceeds its bound").into());
		}
		Ok(Some(RecoveredEffect {
			caller: self.caller.clone(),
			source: self.reference.clone(),
			operation: operation.into(),
			canonical,
		}))
	}
}
impl<D: Deadline> RecoveredEffect<D> {
	fn observer(&self) -> super::observer::EffectObserver<'_, D> {
		super::observer::EffectObserver {
			caller: &self.caller,
			source: &self.source,
			operation: &self.operation,
			canonical: &self.canonical,
		}
	}
	pub async fn adopted(&self) -> Result<bool, Error> {
		self.observer().adopted().await
	}
	pub fn canonical(&self) -> &str {
		&self.canonical
	}
	pub fn operation(&self) -> &str {
		&self.operation
	}
	pub fn retained_bytes(&self) -> usize {
		size_of::<Self>() + self.operation.capacity() + self.canonical.capacity()
	}
	pub async fn status(&self) -> Result<EffectStatus, Error> {
		self.observer().status("the original receipt did not answer").await
	}
	/// Wait on this exact observer, including a retained execution interruption.
	pub async fn receive(&self) -> Result<EffectStatus, Error> {
		self.observer().receive().await
	}
	pub async fn result(&self) -> Result<Argument, Error> {
		self.observer().result("the original result did not answer").await
	}
	/// The committed result's JSON text, as [`Command::result_text`] reads it.
	pub async fn result_text(&self) -> Result<String, Error> {
		super::committed_text(&self.result().await?)
	}
	/// Give up on this receipt. Its outcome stays unknown, an unadopted result
	/// is forfeited, and the operation can never be resumed or resubmitted.
	/// A receipt already released, or one the session no longer holds, answers
	/// [`Release::Released`]. One whose executor runs answers
	/// [`Release::Running`] and stays until that executor settles or pauses,
	/// and the session retires a paused executor. One whose result was adopted
	/// since it was recovered answers [`Release::Kept`] and stays adopted.
	pub async fn release(&self) -> Result<Release, Error> {
		self.observer().release("the original receipt did not answer").await
	}
	/// Resume only the already retained observation. Cold unknown receipts have
	/// no executor to resume and cannot become another upstream dispatch.
	pub async fn resume(&self) -> Result<EffectStatus, Error> {
		let reply = self
			.caller
			.call(
				&self.source,
				"resume-effect",
				&[self.operation.clone().into(), self.canonical.clone().into()],
				"the original observation did not answer",
			)
			.await?;
		EffectStatus::read(&reply)
	}
}

impl<D: Deadline + Clone> RecoveredEffect<D> {
	pub fn prepare_result_acquisition_with_source(
		&self,
		expected: u64,
		imports: &[ResultImport],
		releases: &[custody::Coordinate],
		intent: &Intent,
		source: Option<custody::FieldKey<custody::SessionAccess>>,
	) -> glowcap::Result<ResultAcquisition<D>> {
		super::results::prepare(self.observer(), expected, imports, releases, intent, source)
	}
}
