//! Durable session commits and recovery, shared by native and browser hosts.
use crate::documents::{Completion, Documents};
use crate::entropy::Entropy;
use rooms_application::{
	documents::{SessionDocument, WriteFailure},
	session::{
		checkpoint::{
			Checkpoint,
			commands::{Command, Facts, results},
		},
		state::{
			self, Admission, Change, Impact, Inspected, Inspection, OperationId, Outcome, Prepared, ResultAdmission,
			ResultKind, ResultProgress, ResultRecorded, ResultText, SessionState,
		},
	},
	text::DocumentText,
};
use rooms_glowcap::routes::CheckpointRoutes;
use std::{
	cell::{Ref, RefCell, RefMut},
	rc::{Rc, Weak},
};

#[derive(Debug)]
pub enum Error<E> {
	State(state::Error),
	Storage(E),
	Write(WriteFailure<E>),
	Pending,
	Missing,
	OrphanedEffects,
	Entropy,
	Unloaded,
	/// The effects an owner had to settle before this boundary failed, still
	/// carrying the class that owner gave it.
	Effects(crate::Error),
}
impl<E> From<state::Error> for Error<E> {
	fn from(value: state::Error) -> Self {
		Self::State(value)
	}
}
impl<E: core::fmt::Display> core::fmt::Display for Error<E> {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::State(e) => e.fmt(f),
			Self::Storage(e) => e.fmt(f),
			Self::Write(WriteFailure::Unchanged(e)) => write!(f, "session write did not commit: {e}"),
			Self::Write(WriteFailure::Indeterminate(e)) => write!(f, "session write needs recovery: {e}"),
			Self::Pending => f.write_str("a document operation is still owned; finish it before reloading"),
			Self::Missing => f.write_str("durable session document is missing"),
			Self::OrphanedEffects => f.write_str("nonempty effects have no checkpoint owner"),
			Self::Entropy => f.write_str("session initialization could not obtain platform entropy"),
			Self::Unloaded => f.write_str("session state is not loaded"),
			Self::Effects(error) => write!(f, "session committed effects are not settled: {error}"),
		}
	}
}
impl<E: core::error::Error + 'static> core::error::Error for Error<E> {}
pub struct DurableSession<S, G> {
	storage: S,
	entropy: G,
	state: Rc<RefCell<Option<SessionState>>>,
	loaded: bool,
}
impl<S: Documents, G: Entropy> DurableSession<S, G> {
	pub fn new(storage: S, entropy: G) -> Self {
		Self {
			storage,
			entropy,
			state: Rc::new(RefCell::new(None)),
			loaded: false,
		}
	}
	pub fn state(&self) -> Result<Ref<'_, SessionState>, Error<S::Error>> {
		let held = self.state.try_borrow().map_err(|_| state::Error::Busy)?;
		if held.is_none() {
			return Err(Error::Unloaded);
		}
		Ok(Ref::map(held, |v| v.as_ref().expect("checked loaded state")))
	}
	pub fn view(&self) -> SessionView {
		SessionView(Rc::downgrade(&self.state))
	}
	fn mutable(&self) -> Result<RefMut<'_, SessionState>, Error<S::Error>> {
		let held = self.state.try_borrow_mut().map_err(|_| state::Error::Busy)?;
		if held.is_none() {
			return Err(Error::Unloaded);
		}
		Ok(RefMut::map(held, |v| v.as_mut().expect("checked loaded state")))
	}
	/// Every completion is returned to its owner, including an abandoned write
	/// that failed. Restore cannot stand in for observing worker retirement.
	pub async fn finish_pending(&mut self) -> [Option<Completion<S::Error>>; 2] {
		self.storage.finish_pending().await
	}
	/// Load validates both documents before exposing identity or checkpoint.
	/// Fresh initialization writes the empty effects document first; a crash
	/// before checkpoint creation can safely resume that unpublished state.
	pub async fn load(&mut self) -> Result<LoadStatus, Error<S::Error>> {
		if self.storage.has_pending() {
			return Err(Error::Pending);
		}
		*self.state.try_borrow_mut().map_err(|_| state::Error::Busy)? = None;
		let crate::documents::Stored { checkpoint, effects } = self.storage.read().await.map_err(Error::Storage)?;
		let state = match (checkpoint, effects) {
			(Some(checkpoint), Some(effects)) => SessionState::restore(&checkpoint, &effects, &CheckpointRoutes)?,
			(Some(_), None) => return Err(Error::Missing),
			(None, _) if self.loaded => return Err(Error::Missing),
			(None, effects) => {
				if let Some(bytes) = effects.as_ref()
					&& !SessionState::effects_are_initial(bytes)?
				{
					return Err(Error::OrphanedEffects);
				}
				let mut identity = [0; 32];
				let mut entropy = [0; glowcap::Host::DURABLE_ENTROPY_BYTES];
				self.entropy.fill(&mut identity).map_err(|_| Error::Entropy)?;
				self.entropy.fill(&mut entropy).map_err(|_| Error::Entropy)?;
				let state = SessionState::fresh(identity, entropy);
				if effects.is_none() {
					self.storage
						.replace(SessionDocument::Effects, state.document(SessionDocument::Effects)?)
						.await
						.map_err(Error::Write)?;
				}
				self.storage
					.replace(
						SessionDocument::Checkpoint,
						state.document(SessionDocument::Checkpoint)?,
					)
					.await
					.map_err(Error::Write)?;
				state
			}
		};
		let checkpoint = state.checkpoint()?;
		for pending in state.pending()? {
			let state::PendingView::Result(pending) = pending else {
				continue;
			};
			let kind = pending
				.kind
				.text()
				.as_str()
				.and_then(results::Kind::parse)
				.ok_or(state::Error::ResultChanged)?;
			results::Plan::decode(kind, pending.intent.text(), &CheckpointRoutes)
				.and_then(|plan| plan.resume(checkpoint, &CheckpointRoutes))
				.map_err(state::Error::Command)?;
		}
		let status = state
			.recoverable_result()?
			.map_or(LoadStatus::Ready, |id| LoadStatus::RecoverResult(id.clone()));
		*self.state.try_borrow_mut().map_err(|_| state::Error::Busy)? = Some(state);
		self.loaded = true;
		Ok(status)
	}
	async fn persist(&mut self, write: Prepared) -> Result<Change, Error<S::Error>> {
		let written = write.persist(&mut self.storage).await.map_err(Error::Write)?;
		let mut owner = self.mutable()?;
		Ok(written.commit(&mut owner)?)
	}
	pub(crate) async fn admitted(&mut self, admission: Admission) -> Result<(u64, Option<Change>), Error<S::Error>> {
		match admission {
			Admission::Repeated(revision) => Ok((revision, None)),
			Admission::Write(write) => {
				let change = self.persist(write).await?;
				Ok((change.revision, Some(change)))
			}
		}
	}
	pub async fn mutate(
		&mut self,
		id: OperationId,
		base: u64,
		material: &DocumentText,
		impact: Impact,
		change: impl FnOnce(&Checkpoint) -> Result<Checkpoint, state::Error>,
	) -> Result<(u64, Option<Change>), Error<S::Error>> {
		let admitted = self.mutable()?.mutate(id, base, material, impact, change)?;
		self.admitted(admitted).await
	}
	/// Execute shared Rooms policy through the same retry and acknowledgement
	/// transaction as imported checkpoints. Runtime facts are sampled by the
	/// caller at the serialized command boundary; effects follow the returned Change.
	pub fn command<'a, F: Facts>(
		&'a mut self,
		id: OperationId,
		base: u64,
		command: Command,
		args: &[DocumentText],
		facts: &F,
	) -> impl core::future::Future<Output = Result<(u64, Option<Change>), Error<S::Error>>> + use<'a, F, S, G> {
		let admission = self.prepare_command(id, base, command, args, facts);
		async move { self.admitted(admission?).await }
	}
	pub(crate) fn prepare_command<F: Facts>(
		&mut self,
		id: OperationId,
		base: u64,
		command: Command,
		args: &[DocumentText],
		facts: &F,
	) -> Result<Admission, Error<S::Error>> {
		let material = command.material(args).map_err(state::Error::Command)?;
		Ok(self
			.mutable()?
			.mutate(id, base, &material, command.impact(), |current| {
				command
					.apply(current, args, &CheckpointRoutes, facts)
					.map_err(state::Error::Command)
			})?)
	}
	pub(crate) fn prepare_adopt(
		&mut self,
		id: OperationId,
		base: u64,
		material: &DocumentText,
		checkpoint: Checkpoint,
	) -> Result<Admission, Error<S::Error>> {
		Ok(self.mutable()?.adopt(id, base, material, checkpoint)?)
	}
	pub(crate) fn prepare_replace(
		&mut self,
		id: OperationId,
		base: u64,
		material: &DocumentText,
		checkpoint: Checkpoint,
	) -> Result<Admission, Error<S::Error>> {
		Ok(self.mutable()?.replace(id, base, material, checkpoint)?)
	}

	pub async fn adopt(
		&mut self,
		id: OperationId,
		base: u64,
		material: &DocumentText,
		checkpoint: Checkpoint,
	) -> Result<(u64, Option<Change>), Error<S::Error>> {
		let admitted = self.prepare_adopt(id, base, material, checkpoint)?;
		self.admitted(admitted).await
	}
	pub async fn replace(
		&mut self,
		id: OperationId,
		base: u64,
		material: &DocumentText,
		checkpoint: Checkpoint,
	) -> Result<(u64, Option<Change>), Error<S::Error>> {
		let admitted = self.prepare_replace(id, base, material, checkpoint)?;
		self.admitted(admitted).await
	}
	pub async fn reconcile(
		&mut self,
		impact: Impact,
		reduce: impl FnOnce(&Checkpoint) -> Result<Option<Checkpoint>, state::Error>,
	) -> Result<Option<Change>, Error<S::Error>> {
		let Some(write) = self.mutable()?.reconcile(impact, reduce)? else {
			return Ok(None);
		};
		self.persist(write).await.map(Some)
	}
	pub async fn reconcile_fact(
		&mut self,
		fact: &rooms_application::session::checkpoint::reconciliation::Fact,
	) -> Result<Option<Change>, Error<S::Error>> {
		self.reconcile(fact.impact(), |current| {
			fact.apply(current, &CheckpointRoutes).map_err(state::Error::Command)
		})
		.await
	}
	pub fn inspect_ordinary(
		&self,
		id: OperationId,
		base: u64,
		material: &DocumentText,
	) -> Result<Inspection, Error<S::Error>> {
		Ok(self.state()?.inspect_ordinary(id, base, material)?)
	}
	async fn ordinary_admitted(
		&mut self,
		admission: Admission,
	) -> Result<(OrdinaryStatus, Option<Change>), Error<S::Error>> {
		match admission {
			Admission::Repeated(revision) => Ok((OrdinaryStatus::Committed(revision), None)),
			Admission::Write(write) => {
				let change = self.persist(write).await?;
				Ok((OrdinaryStatus::Prepared, Some(change)))
			}
		}
	}
	pub async fn prepare_ordinary(
		&mut self,
		id: OperationId,
		base: u64,
		material: &DocumentText,
	) -> Result<(OrdinaryStatus, Option<Change>), Error<S::Error>> {
		let admitted = self.mutable()?.prepare_ordinary(id, base, material)?;
		self.ordinary_admitted(admitted).await
	}
	pub async fn prepare_inspected(
		&mut self,
		inspection: Inspected,
		material: &DocumentText,
	) -> Result<(OrdinaryStatus, Option<Change>), Error<S::Error>> {
		let admitted = self.mutable()?.prepare_inspected(inspection, material)?;
		self.ordinary_admitted(admitted).await
	}
	pub async fn commit_ordinary(
		&mut self,
		id: &OperationId,
		material: &DocumentText,
	) -> Result<Change, Error<S::Error>> {
		let write = self.mutable()?.commit_ordinary(id, material)?;
		self.persist(write).await
	}
	pub async fn resolve(&mut self, id: &OperationId, outcome: Outcome) -> Result<Change, Error<S::Error>> {
		let write = self.mutable()?.resolve(id, outcome)?;
		self.persist(write).await
	}
	async fn prepare_result(
		&mut self,
		id: OperationId,
		base: u64,
		material: &DocumentText,
		kind: ResultKind,
		intent: ResultText,
	) -> Result<(ResultStatus, Option<Change>), Error<S::Error>> {
		let admission = self.mutable()?.prepare_result(id, base, material, kind, intent)?;
		match admission {
			ResultAdmission::Write(write) => {
				let change = self.persist(write).await?;
				Ok((ResultStatus::Prepared, Some(change)))
			}
			ResultAdmission::Prepared => Ok((ResultStatus::Prepared, None)),
			ResultAdmission::Returned(result) => Ok((ResultStatus::Returned(result), None)),
			ResultAdmission::Committed { revision, result } => Ok((ResultStatus::Committed { revision, result }, None)),
		}
	}
	pub async fn prepare_plan(
		&mut self,
		id: OperationId,
		base: u64,
		material: &DocumentText,
		plan: &results::Plan,
	) -> Result<(ResultStatus, Option<Change>), Error<S::Error>> {
		{
			let state = self.state()?;
			if !state.operation_known(&id)? {
				plan.validate_fresh(state.checkpoint()?, &CheckpointRoutes)
					.map_err(state::Error::Command)?;
			}
		}
		let kind = ResultKind::new(plan.kind().as_str().into()).ok_or(state::Error::Document)?;
		let intent = ResultText::new(plan.intent().map_err(state::Error::Command)?).ok_or(state::Error::Document)?;
		self.prepare_result(id, base, material, kind, intent).await
	}
	pub async fn finish_result(&mut self, id: &OperationId) -> Result<(u64, Option<Change>), Error<S::Error>> {
		self.advance_result(id, |current, kind, intent, returned| {
			results::apply(current, kind, intent, returned, &CheckpointRoutes)
		})
		.await
	}
	pub async fn record_result(
		&mut self,
		id: &OperationId,
		material: Option<&DocumentText>,
		result: ResultText,
	) -> Result<(RecordedStatus, Option<Change>), Error<S::Error>> {
		let admission = self.mutable()?.record_result(id, material, result)?;
		match admission {
			ResultRecorded::Write(write) => {
				let change = self.persist(write).await?;
				Ok((RecordedStatus::Stored, Some(change)))
			}
			ResultRecorded::Stored => Ok((RecordedStatus::Stored, None)),
			ResultRecorded::Committed(revision) => Ok((RecordedStatus::Committed(revision), None)),
		}
	}
	/// Advances one write at a time so the caller observes each committed
	/// checkpoint/effect change even if a later recovery write fails.
	async fn advance_result(
		&mut self,
		id: &OperationId,
		apply: impl FnMut(&Checkpoint, &ResultKind, &ResultText, &ResultText) -> Result<Checkpoint, state::Error>,
	) -> Result<(u64, Option<Change>), Error<S::Error>> {
		let admission = self.mutable()?.advance_result(id, apply)?;
		match admission {
			ResultProgress::Write(write) => {
				let change = self.persist(write).await?;
				Ok((change.revision, Some(change)))
			}
			ResultProgress::Complete(revision) => Ok((revision, None)),
		}
	}
}
#[derive(Clone, Copy, Debug)]
pub enum ViewError {
	Busy,
	Unloaded,
}
impl core::fmt::Display for ViewError {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Busy => "session state is already borrowed",
			Self::Unloaded => "session state is not loaded",
		})
	}
}
impl core::error::Error for ViewError {}
impl<E> From<ViewError> for Error<E> {
	fn from(error: ViewError) -> Self {
		match error {
			ViewError::Busy => Self::State(state::Error::Busy),
			ViewError::Unloaded => Self::Unloaded,
		}
	}
}
/// Read current committed state during platform I/O. The weak handle retires
/// with its owner and observes reload through that same owner cell. No RefCell
/// borrow leaves the callback or crosses a document await.
#[derive(Clone)]
pub struct SessionView(Weak<RefCell<Option<SessionState>>>);
impl SessionView {
	pub fn same_owner(&self, other: &Self) -> bool {
		Weak::ptr_eq(&self.0, &other.0)
	}
	pub fn read<T>(&self, inspect: impl FnOnce(&SessionState) -> T) -> Result<T, ViewError> {
		let owner = self.0.upgrade().ok_or(ViewError::Unloaded)?;
		let held = owner.try_borrow().map_err(|_| ViewError::Busy)?;
		Ok(inspect(held.as_ref().ok_or(ViewError::Unloaded)?))
	}
}
/// A restored returned authority must be applied before publishing the session.
#[must_use = "finish result recovery before publishing this session"]
pub enum LoadStatus {
	Ready,
	RecoverResult(OperationId),
}
pub enum OrdinaryStatus {
	Prepared,
	Committed(u64),
}
pub enum ResultStatus {
	Prepared,
	Returned(std::rc::Rc<ResultText>),
	Committed {
		revision: u64,
		result: std::rc::Rc<ResultText>,
	},
}
pub enum RecordedStatus {
	Stored,
	Committed(u64),
}
