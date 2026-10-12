//! Receipt recovery holds the original source and canonical intent. Inventory
//! rows describe only that source's receipts and cannot restore other authority.
use super::*;
use rooms_application::content::session::custody::MAX_EFFECTS;

pub struct EffectEntry {
	pub operation: String,
	pub status: EffectStatus,
	pub resumable: bool,
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
				if !rooms_application::session::state::OperationId::accepts_utf16(row.operation.encode_utf16()) {
					return Err(loam::refusal("invalid effect identity").into());
				}
				Ok(EffectEntry {
					operation: row.operation,
					status: EffectStatus::read(&row.status.into())?,
					resumable: row.resumable,
				})
			})
			.collect()
	}
	/// None means the receipt was already adopted or left the bounded replay
	/// window. It grants no permission to prepare or resend the original effect.
	pub async fn recover_effect(&self, operation: &str) -> Result<Option<RecoveredEffect<D>>, Error> {
		if !rooms_application::session::state::OperationId::accepts_utf16(operation.encode_utf16()) {
			return Err(loam::refusal("invalid effect identity").into());
		}
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
	pub async fn adopted(&self) -> Result<bool, Error> {
		let reply = self
			.caller
			.call(
				&self.source,
				"effect-adopted",
				&[self.operation.as_str().into()],
				"the original adoption did not answer",
			)
			.await?;
		match reply {
			Argument::Boolean(value) => Ok(value),
			_ => Err(loam::refusal("invalid adoption status").into()),
		}
	}
	pub fn canonical(&self) -> &str {
		&self.canonical
	}
	pub fn retained_bytes(&self) -> usize {
		size_of::<Self>() + self.operation.capacity() + self.canonical.capacity()
	}
	pub async fn status(&self) -> Result<EffectStatus, Error> {
		let reply = self
			.caller
			.call(
				&self.source,
				"effect-status",
				&[self.operation.clone().into(), self.source.clone().into()],
				"the original receipt did not answer",
			)
			.await?;
		EffectStatus::read(&reply)
	}
	/// Wait on this exact observer, including a retained execution interruption.
	pub async fn receive(&self) -> Result<EffectStatus, Error> {
		super::results::receive(&self.caller, &self.source, &self.operation, &self.canonical).await
	}
	pub async fn result(&self) -> Result<Argument, Error> {
		self.caller
			.call(
				&self.source,
				"effect-result",
				&[self.operation.clone().into(), self.canonical.clone().into()],
				"the original result did not answer",
			)
			.await
			.and_then(super::results::observed)
	}
	/// Give up on this receipt. Its outcome stays unknown, an unadopted result
	/// is forfeited, and the operation can never be resumed or resubmitted. A
	/// receipt whose executor remains retained, even while paused, refuses.
	pub async fn release(&self) -> Result<(), Error> {
		self.caller
			.call(
				&self.source,
				"release-effect",
				&[self.operation.clone().into(), self.canonical.clone().into()],
				"the original receipt did not answer",
			)
			.await
			.map(|_| ())
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
		super::results::prepare(
			super::results::Witness {
				caller: &self.caller,
				source: &self.source,
				operation: &self.operation,
				canonical: &self.canonical,
			},
			expected,
			imports,
			releases,
			intent,
			source,
		)
	}
}
