//! Operation transitions admit and retire durable session commands.
use super::transaction::Candidate;
use super::*;
use crate::session::fields::Nullable;

pub enum Admission {
	Repeated(u64),
	Write(Prepared),
}
pub enum Inspection {
	Committed(u64),
	New(Inspected),
}
/// An inspection is bound to its exact owner, not a caller-supplied session id.
pub struct Inspected {
	owner: Rc<Cell<Phase>>,
	id: OperationId,
	digest: Digest,
}
impl Inspected {
	/// Includes the owned id's spare capacity. The shared owner's fixed phase
	/// allocation remains charged to the session owner.
	pub fn retained_bytes(&self) -> usize {
		core::mem::size_of::<Self>().saturating_add(self.id.text().heap_bytes())
	}
}

pub struct PendingResult<'a> {
	pub id: &'a OperationId,
	pub kind: &'a ResultKind,
	pub intent: &'a ResultText,
	pub result: Option<&'a ResultText>,
	pub phase: crate::session::snapshot::views::EffectPhase,
}
pub enum PendingView<'a> {
	Ordinary {
		id: &'a OperationId,
		subject: &'a Text<256, true>,
	},
	Result(PendingResult<'a>),
}
fn pending_view(pending: &Pending) -> PendingView<'_> {
	use crate::session::snapshot::views::EffectPhase;
	match pending {
		Pending::Ordinary(v) => PendingView::Ordinary {
			id: &v.id,
			subject: &v.subject,
		},
		Pending::Result(v) => PendingView::Result(PendingResult {
			id: &v.id,
			kind: &v.result_kind,
			intent: &v.intent,
			result: v.result.as_ref().map(Rc::as_ref),
			phase: if v.marker.as_ref().is_some() {
				EffectPhase::Applied
			} else if v.result.as_ref().is_some() {
				EffectPhase::Completed
			} else {
				EffectPhase::Prepared
			},
		}),
	}
}
impl SessionState {
	pub fn pending(&self) -> Result<impl ExactSizeIterator<Item = PendingView<'_>>, Error> {
		self.readable()?;
		Ok(self.effects.pending.0.iter().map(|v| pending_view(v)))
	}
	pub fn pending_result(&self, id: &OperationId) -> Result<PendingResult<'_>, Error> {
		self.readable()?;
		let value = self
			.effects
			.pending
			.0
			.iter()
			.find(|v| v.id() == id)
			.ok_or(Error::Missing)?;
		match pending_view(value) {
			PendingView::Result(v) => Ok(v),
			_ => Err(Error::Missing),
		}
	}

	pub fn mutate(
		&mut self,
		id: OperationId,
		base: u64,
		material: &DocumentText,
		impact: Impact,
		change: impl FnOnce(&Checkpoint) -> Result<Checkpoint, Error>,
	) -> Result<Admission, Error> {
		self.writable()?;
		let hash = digest(material);
		if let Some(revision) = self.command_status(&id, base, &hash)? {
			return Ok(Admission::Repeated(revision));
		}
		let revision = SafeInteger::new(base + 1).ok_or(Error::Exhausted)?;
		let checkpoint = change(&self.disk.checkpoint)?;
		let mut next = self.disk.clone();
		next.revision = revision;
		next.workspace_adoption = Adoption::Closed;
		next.checkpoint = Rc::new(checkpoint);
		next.recent.0.insert(
			0,
			Rc::new(RecentOperation {
				id,
				digest: hash,
				revision,
			}),
		);
		next.recent.0.truncate(64);
		self.staged(Candidate::Disk(next), Some(impact)).map(Admission::Write)
	}
	/// Read-only preflight for a checkpoint command. This does not reserve the
	/// revision: mutate must recheck after any external capability work.
	pub fn inspect_command(&self, id: &OperationId, base: u64, material: &DocumentText) -> Result<Option<u64>, Error> {
		self.writable()?;
		self.command_status(id, base, &digest(material))
	}
	fn command_status(&self, id: &OperationId, base: u64, hash: &Digest) -> Result<Option<u64>, Error> {
		if let Some(recent) = self.disk.recent.0.iter().find(|v| &v.id == id) {
			if &recent.digest != hash {
				return Err(Error::Reused);
			}
			return Ok(Some(recent.revision.get()));
		}
		if self.effects.recent.0.iter().any(|v| &v.id == id) || self.effects.pending.0.iter().any(|v| v.id() == id) {
			return Err(Error::OtherLedger);
		}
		if base != self.disk.revision.get() {
			return Err(Error::Revision);
		}
		if self
			.effects
			.pending
			.0
			.iter()
			.any(|v| matches!(v.as_ref(),Pending::Result(v) if v.result.as_ref().is_some()))
		{
			return Err(Error::ResultNeedsRecovery);
		}
		SafeInteger::<false>::new(base + 1).ok_or(Error::Exhausted)?;
		Ok(None)
	}
	pub fn adopt(
		&mut self,
		id: OperationId,
		base: u64,
		material: &DocumentText,
		checkpoint: Checkpoint,
	) -> Result<Admission, Error> {
		let available = self.disk.workspace_adoption == Adoption::Available;
		self.mutate(id, base, material, Impact::Realization, move |_| {
			if available {
				Ok(checkpoint)
			} else {
				Err(Error::AdoptionClosed)
			}
		})
	}
	/// Administrator replacement of the whole workspace, including after initial
	/// adoption has closed. Retry identity is the operation id and material digest.
	pub fn replace(
		&mut self,
		id: OperationId,
		base: u64,
		material: &DocumentText,
		checkpoint: Checkpoint,
	) -> Result<Admission, Error> {
		self.mutate(id, base, material, Impact::Realization, move |_| Ok(checkpoint))
	}
	/// Learned facts do not advance the optimistic command revision. The
	/// reducer must compare the exact authority/generation before returning a
	/// replacement. None or an identical checkpoint leaves both persistence and
	/// observation untouched. A committed changed fact closes initial adoption.
	pub fn reconcile(
		&mut self,
		impact: Impact,
		reduce: impl FnOnce(&Checkpoint) -> Result<Option<Checkpoint>, Error>,
	) -> Result<Option<Prepared>, Error> {
		self.writable()?;
		if self
			.effects
			.pending
			.0
			.iter()
			.any(|v| matches!(v.as_ref(),Pending::Result(v) if v.result.as_ref().is_some()))
		{
			return Err(Error::ResultNeedsRecovery);
		}
		let Some(checkpoint) = reduce(&self.disk.checkpoint)? else {
			return Ok(None);
		};
		if &checkpoint == self.disk.checkpoint.as_ref() {
			return Ok(None);
		}
		let mut next = self.disk.clone();
		next.workspace_adoption = Adoption::Closed;
		next.checkpoint = Rc::new(checkpoint);
		self.staged(Candidate::Disk(next), Some(impact)).map(Some)
	}
	pub fn inspect_ordinary(&self, id: OperationId, base: u64, material: &DocumentText) -> Result<Inspection, Error> {
		self.writable()?;
		let hash = digest(material);
		if self.disk.recent.0.iter().any(|v| v.id == id) {
			return Err(Error::OtherLedger);
		}
		if let Some(v) = self.effects.recent.0.iter().find(|v| v.id == id) {
			if v.result_kind.as_ref().is_some() {
				return Err(Error::OtherLedger);
			}
			if v.digest != hash {
				return Err(Error::Reused);
			}
			if v.outcome == Outcome::Abandoned {
				return Err(Error::Abandoned);
			}
			return Ok(Inspection::Committed(v.revision.get()));
		}
		if let Some(v) = self.effects.pending.0.iter().find(|v| v.id() == &id) {
			if matches!(v.as_ref(), Pending::Result(_)) {
				return Err(Error::OtherLedger);
			}
			if v.digest() != &hash {
				return Err(Error::Reused);
			}
			return Err(Error::Unresolved);
		}
		if base != self.disk.revision.get() {
			return Err(Error::Revision);
		}
		Ok(Inspection::New(Inspected {
			owner: self.phase.clone(),
			id,
			digest: hash,
		}))
	}
	pub fn prepare_ordinary(
		&mut self,
		id: OperationId,
		base: u64,
		material: &DocumentText,
	) -> Result<Admission, Error> {
		match self.inspect_ordinary(id, base, material)? {
			Inspection::Committed(v) => Ok(Admission::Repeated(v)),
			Inspection::New(v) => self.reserve_ordinary(v, material).map(Admission::Write),
		}
	}
	pub fn prepare_inspected(&mut self, inspected: Inspected, material: &DocumentText) -> Result<Admission, Error> {
		self.writable()?;
		if !Rc::ptr_eq(&inspected.owner, &self.phase) {
			return Err(Error::WrongOwner);
		}
		if inspected.digest != digest(material) {
			return Err(Error::Reused);
		}
		self.prepare_ordinary(inspected.id, self.disk.revision.get(), material)
	}
	fn reserve_ordinary(&mut self, inspected: Inspected, material: &DocumentText) -> Result<Prepared, Error> {
		if self.effects.pending.0.len() == 64 {
			return Err(Error::Full);
		}
		let mut next = self.effects.clone();
		next.pending.0.push(Rc::new(Pending::Ordinary(Ordinary {
			kind: OrdinaryTag::Ordinary,
			id: inspected.id,
			digest: inspected.digest,
			subject: Text(ordinary_subject(material).into()),
		})));
		self.staged(Candidate::Effects(next), None)
	}
	pub fn commit_ordinary(&mut self, id: &OperationId, material: &DocumentText) -> Result<Prepared, Error> {
		self.writable()?;
		let hash = digest(material);
		let at = self
			.effects
			.pending
			.0
			.iter()
			.position(|v| v.id() == id)
			.ok_or(Error::Missing)?;
		let v = &self.effects.pending.0[at];
		if !matches!(v.as_ref(), Pending::Ordinary(_)) || v.digest() != &hash {
			return Err(Error::Missing);
		}
		self.finish_effect(at, Outcome::Committed, None)
	}
	pub fn resolve(&mut self, id: &OperationId, outcome: Outcome) -> Result<Prepared, Error> {
		self.writable()?;
		let at = self
			.effects
			.pending
			.0
			.iter()
			.position(|v| v.id() == id)
			.ok_or(Error::Missing)?;
		let result_kind = match self.effects.pending.0[at].as_ref() {
			Pending::Ordinary(_) => None,
			Pending::Result(v) if outcome == Outcome::Abandoned && v.result.as_ref().is_none() => {
				Some(v.result_kind.clone())
			}
			Pending::Result(_) => return Err(Error::ResultChanged),
		};
		self.finish_effect(at, outcome, result_kind)
	}
	fn finish_effect(&self, at: usize, outcome: Outcome, result_kind: Option<ResultKind>) -> Result<Prepared, Error> {
		let mut next = self.effects.clone();
		let pending = next.pending.0.remove(at);
		next.recent.0.insert(
			0,
			Rc::new(RecentEffect {
				id: pending.id().clone(),
				digest: pending.digest().clone(),
				revision: self.disk.revision,
				outcome,
				result_kind: result_kind.map_or(Nullable::Null, Nullable::Value),
				result: Nullable::Null,
			}),
		);
		next.recent.0.truncate(64);
		self.staged(Candidate::Effects(next), None)
	}
}
fn ordinary_subject(material: &DocumentText) -> &'static str {
	struct Command;
	impl<'de> serde::de::Visitor<'de> for Command {
		type Value = Option<alloc::string::String>;
		fn expecting(&self, f: &mut core::fmt::Formatter) -> core::fmt::Result {
			f.write_str("operation material")
		}
		fn visit_seq<A: serde::de::SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
			let first = seq.next_element::<&serde_json::value::RawValue>()?;
			let command = first
				.filter(|v| v.get().len() <= 256)
				.and_then(|v| serde_json::from_str(v.get()).ok());
			while seq.next_element::<serde::de::IgnoredAny>()?.is_some() {}
			Ok(command)
		}
	}
	use serde::Deserializer;
	let scalar = material.utf8_lossy();
	let mut parser = serde_json::Deserializer::from_str(&scalar);
	let command = parser
		.deserialize_seq(Command)
		.ok()
		.flatten()
		.filter(|_| parser.end().is_ok());
	match command.as_deref() {
		Some("say") => "Send a message",
		Some("sendFiles") => "Send message attachments",
		Some("editLine") => "Edit a message",
		Some("withdrawLine") => "Withdraw a message",
		Some("setRoomTopic") => "Set a room topic",
		Some("kickRoomMember") => "Ask a room member to leave",
		Some("offerRoom") => "Offer a room invitation",
		Some("operator") => "Run a Rooms operator action",
		Some("operations") => "Run a directory operation",
		_ => "Run a shared session operation",
	}
}
