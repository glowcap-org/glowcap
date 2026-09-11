use super::transaction::Candidate;
use super::*;
use crate::session::fields::Nullable;

pub enum ResultAdmission {
	Write(Prepared),
	Prepared,
	Returned(Rc<ResultText>),
	Committed { revision: u64, result: Rc<ResultText> },
}
pub enum ResultRecorded {
	Write(Prepared),
	Stored,
	Committed(u64),
}
pub enum ResultProgress {
	Write(Prepared),
	Complete(u64),
}
impl SessionState {
	pub fn prepare_result(
		&mut self,
		id: OperationId,
		base: u64,
		material: &DocumentText,
		kind: ResultKind,
		intent: ResultText,
	) -> Result<ResultAdmission, Error> {
		self.writable()?;
		let hash = digest(material);
		if self.disk.recent.0.iter().any(|v| v.id == id) {
			return Err(Error::OtherLedger);
		}
		if let Some(v) = self.effects.recent.0.iter().find(|v| v.id == id) {
			if v.digest != hash || v.result_kind.as_ref() != Some(&kind) {
				return Err(Error::Reused);
			}
			if v.outcome == Outcome::Abandoned {
				return Err(Error::Abandoned);
			}
			let result = v.result.as_ref().ok_or(Error::Missing)?.clone();
			return Ok(ResultAdmission::Committed {
				revision: v.revision.get(),
				result,
			});
		}
		if let Some(v) = self.effects.pending.0.iter().find(|v| v.id() == &id) {
			let Pending::Result(v) = v.as_ref() else {
				return Err(Error::Reused);
			};
			if v.digest != hash
				|| v.result_kind != kind
				|| v.base_revision.get() != base
				|| v.intent.as_ref() != &intent
			{
				return Err(Error::Reused);
			}
			return Ok(v
				.result
				.as_ref()
				.map_or(ResultAdmission::Prepared, |v| ResultAdmission::Returned(v.clone())));
		}
		if self
			.effects
			.pending
			.0
			.iter()
			.any(|v| matches!(v.as_ref(), Pending::Result(_)))
		{
			return Err(Error::ResultInFlight);
		}
		if base != self.disk.revision.get() {
			return Err(Error::Revision);
		}
		if self.effects.pending.0.len() == 64 {
			return Err(Error::Full);
		}
		let mut next = self.effects.clone();
		next.pending.0.push(Rc::new(Pending::Result(ResultEffect {
			kind: ResultTag::Result,
			id,
			digest: hash,
			result_kind: kind,
			base_revision: self.disk.revision,
			intent: Rc::new(intent),
			result: Nullable::Null,
			marker: Nullable::Null,
		})));
		self.staged(Candidate::Effects(next), None).map(ResultAdmission::Write)
	}
	/// A recovery caller may omit material only for an already named pending
	/// result. The ordinary client path must supply and match its digest.
	pub fn record_result(
		&mut self,
		id: &OperationId,
		material: Option<&DocumentText>,
		result: ResultText,
	) -> Result<ResultRecorded, Error> {
		self.writable()?;
		let hash = material.map(digest);
		let Some(at) = self.effects.pending.0.iter().position(|v| v.id() == id) else {
			if let Some(hash) = hash {
				if let Some(v) = self.effects.recent.0.iter().find(|v| {
					&v.id == id
						&& v.outcome == Outcome::Committed
						&& v.digest == hash
						&& v.result.as_ref().map(Rc::as_ref) == Some(&result)
				}) {
					return Ok(ResultRecorded::Committed(v.revision.get()));
				}
			}
			return Err(Error::Missing);
		};
		let Pending::Result(pending) = self.effects.pending.0[at].as_ref() else {
			return Err(Error::Missing);
		};
		if hash.as_ref().is_some_and(|hash| hash != &pending.digest) {
			return Err(Error::Missing);
		}
		if let Some(previous) = pending.result.as_ref() {
			if previous.as_ref() != &result {
				return Err(Error::ResultChanged);
			}
			// The result is durable, but its checkpoint application is not
			// necessarily complete. The caller must advance recovery below.
			return Ok(ResultRecorded::Stored);
		}
		let mut pending = pending.clone();
		pending.result = Nullable::Value(Rc::new(result));
		let mut next = self.effects.clone();
		next.pending.0[at] = Rc::new(Pending::Result(pending));
		self.staged(Candidate::Effects(next), None).map(ResultRecorded::Write)
	}
	pub fn recoverable_result(&self) -> Result<Option<&OperationId>, Error> {
		self.readable()?;
		Ok(self.effects.pending.0.iter().find_map(|v| match v.as_ref() {
			Pending::Result(v) if v.result.as_ref().is_some() => Some(&v.id),
			_ => None,
		}))
	}
	/// Advance exactly one durable recovery boundary. The applier is pure and
	/// must be idempotent on its own returned authority. A freshly computed
	/// candidate is retained through marker/checkpoint writes; restart rebuilds
	/// it and verifies an already-applied checkpoint before finalization.
	pub fn advance_result(
		&mut self,
		id: &OperationId,
		mut apply: impl FnMut(&Checkpoint, &ResultKind, &ResultText, &ResultText) -> Result<Checkpoint, Error>,
	) -> Result<ResultProgress, Error> {
		self.writable()?;
		let Some(at) = self.effects.pending.0.iter().position(|v| v.id() == id) else {
			let recent = self
				.effects
				.recent
				.0
				.iter()
				.find(|v| &v.id == id && v.outcome == Outcome::Committed && v.result.as_ref().is_some())
				.ok_or(Error::Missing)?;
			return Ok(ResultProgress::Complete(recent.revision.get()));
		};
		let Pending::Result(pending) = self.effects.pending.0[at].as_ref() else {
			return Err(Error::Missing);
		};
		let result = pending.result.as_ref().ok_or(Error::Missing)?;
		let result_digest = digest(&result.0);
		let Some(marker) = pending.marker.as_ref() else {
			if self.disk.revision.get() < pending.base_revision.get() {
				return Err(Error::Revision);
			}
			let revision = SafeInteger::new(self.disk.revision.get() + 1).ok_or(Error::Exhausted)?;
			let checkpoint = Rc::new(apply(
				&self.disk.checkpoint,
				&pending.result_kind,
				&pending.intent,
				result,
			)?);
			let mut pending = pending.clone();
			pending.marker = Nullable::Value(Marker {
				revision,
				apply_kind: pending.result_kind.clone(),
				result_digest,
			});
			let mut next = self.effects.clone();
			next.pending.0[at] = Rc::new(Pending::Result(pending));
			return self
				.staged(Candidate::MarkedEffects(next, checkpoint), None)
				.map(ResultProgress::Write);
		};
		if marker.result_digest != result_digest {
			return Err(Error::ResultChanged);
		}
		if self.disk.revision.get() + 1 == marker.revision.get() {
			let candidate = match &self.result_candidate {
				Some(v) => v.clone(),
				None => Rc::new(apply(
					&self.disk.checkpoint,
					&marker.apply_kind,
					&pending.intent,
					result,
				)?),
			};
			let mut next = self.disk.clone();
			next.revision = marker.revision;
			next.workspace_adoption = Adoption::Closed;
			next.checkpoint = candidate;
			return self
				.staged(Candidate::Disk(next), Some(Impact::Realization))
				.map(ResultProgress::Write);
		}
		if self.disk.revision != marker.revision {
			return Err(Error::Revision);
		}
		if !self
			.result_candidate
			.as_ref()
			.is_some_and(|v| Rc::ptr_eq(v, &self.disk.checkpoint))
		{
			let reapplied = apply(&self.disk.checkpoint, &marker.apply_kind, &pending.intent, result)?;
			// Only crash recovery reconstructs a candidate. Structural equality
			// retains optional-field and answer-order distinctions without JSON
			// buffers; normal application holds the exact immutable candidate.
			if &reapplied != self.disk.checkpoint.as_ref() {
				return Err(Error::ResultChanged);
			}
		}
		let mut next = self.effects.clone();
		next.pending.0.remove(at);
		next.recent.0.insert(
			0,
			Rc::new(RecentEffect {
				id: pending.id.clone(),
				digest: pending.digest.clone(),
				revision: marker.revision,
				outcome: Outcome::Committed,
				result_kind: Nullable::Value(pending.result_kind.clone()),
				result: Nullable::Value(result.clone()),
			}),
		);
		next.recent.0.truncate(64);
		self.staged(Candidate::Effects(next), None).map(ResultProgress::Write)
	}
}
