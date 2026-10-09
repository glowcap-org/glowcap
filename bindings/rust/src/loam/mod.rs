//! Optional durable resources on an existing Host. Zig owns policy and commit
//! decisions; the Rust projection owns callbacks, handles, and storage jobs.
#[cfg(target_arch = "wasm32")]
pub(crate) mod browser;
mod content;
mod reads;
pub use reads::{ReadInterface, ReadMethod, ReadScopeBounds};
mod content_graph;
mod creation;
#[cfg(not(target_arch = "wasm32"))]
mod lmdb;
pub use creation::StagedResource;
mod continuation;
pub use continuation::{Continuation, ContinuationBounds, ContinuationReservation, PendingContinuation};
mod effect_execution;
#[cfg(target_arch = "wasm32")]
pub use browser::StorageStatistics;
pub use effect_execution::{EffectExecution, EffectExecutionBounds, EffectResult};
mod descriptions;
mod observation;
pub use observation::{
	ObservationCursor, ObservationDescription, ObservationNotices, ObservedDescription, UseDescription, UseSnapshot,
};
mod live;
mod policy;
pub use descriptions::{
	AccessStatus, BoundOperator, ControlDescription, ControlSnapshot, GrantDescription, InventoryPage, PolicyBound,
	PolicyDescription,
};
mod registration;
pub use live::{LiveIncarnation, LiveMarker};
#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests;
#[cfg(not(target_arch = "wasm32"))]
pub(crate) mod work;
#[cfg(not(target_arch = "wasm32"))]
use crate::Ref;
use crate::host::HostShared;
use crate::sys::loam as ffi;
use crate::{Error, Host, Result};
#[cfg(target_arch = "wasm32")]
pub(crate) use browser::work;
pub use content::{
	BoundResource, Call, Content, Delivery, Invocation, Method, ReferenceRequest, Registration, ResourceId, Retry,
};
pub use content_graph::{Graph, GraphField, GraphPage, Page, PageSchema, Pages};
mod invocation_bounds;
pub use invocation_bounds::{InvocationBounds, ValueBounds};
mod staging_bounds;
pub use policy::{
	ControlPowers, IssuePolicy, KindRule, Operator, Policy, PolicyValue, Requirement, control_revision,
	parse_control_revision,
};
pub use staging_bounds::StagingBounds;
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

/// Return-code vocabulary shared with the storage archive.
pub const RECOVERY_REQUIRED: i32 = ffi::GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED;
pub const STALE_COMPLETION: i32 = ffi::GLOWCAP_LOAM_ERR_STALE_COMPLETION;
pub const DENIED: i32 = ffi::GLOWCAP_LOAM_ERR_DENIED;
pub const UNCHANGED: i32 = ffi::GLOWCAP_LOAM_ERR_UNCHANGED;
pub const APPLICATION_REFUSED: i32 = ffi::GLOWCAP_LOAM_ERR_APPLICATION;

/// Construct a deliberate content callback refusal. The callback boundary
/// reports APPLICATION_REFUSED to Zig. Local detail is not forwarded or queued;
/// the application must record it before returning when it needs that diagnostic.
pub fn refusal(message: impl Into<String>) -> Error {
	Error::with_detail(APPLICATION_REFUSED, message.into())
}

pub(super) fn invalid(message: &str) -> Error {
	Error::with_detail(crate::sys::ERR_INVALID_ARGUMENT, message.to_owned())
}
pub(super) fn check(code: i32, _storage: bool) -> Result<()> {
	if code == crate::sys::OK {
		return Ok(());
	}
	let mut bytes = [0u8; 512];
	let len = unsafe {
		if _storage {
			#[cfg(not(target_arch = "wasm32"))]
			{
				ffi::glowcap_loam_lmdb_last_error(bytes.as_mut_ptr(), bytes.len())
			}
			#[cfg(target_arch = "wasm32")]
			{
				ffi::glowcap_loam_last_error(bytes.as_mut_ptr(), bytes.len())
			}
		} else {
			ffi::glowcap_loam_last_error(bytes.as_mut_ptr(), bytes.len())
		}
	};
	Err(Error::with_detail(
		code,
		String::from_utf8_lossy(&bytes[..len]).into_owned(),
	))
}
#[derive(Clone, Copy)]
pub struct Schema {
	pub id: u64,
	pub version: u32,
	pub max_payload: usize,
	pub max_edges: usize,
}
impl Schema {
	fn raw(self) -> ffi::GlowcapLoamSchema {
		ffi::GlowcapLoamSchema {
			id: self.id,
			version: self.version,
			max_payload: self.max_payload,
			max_edges: self.max_edges,
		}
	}
	/// Maximum encoded record bytes, including envelope and checksum. The
	/// shared writer derives this without allocation or storage access; it does
	/// not admit the schema or guarantee available backend capacity.
	pub fn encoded_size_bound(self) -> Result<usize> {
		let mut bytes = 0;
		check(
			unsafe { ffi::glowcap_loam_schema_size_bound(&self.raw(), &mut bytes) },
			false,
		)?;
		Ok(bytes)
	}
}
#[derive(Clone, Copy)]
pub struct Limits {
	pub resident_bytes: usize,
	pub staging_bytes: usize,
	pub cache_slots: usize,
	pub max_leases: usize,
	pub max_changes: usize,
	/// Live attachment endpoints, independent of Store retention tokens.
	pub max_references: usize,
	pub max_operations: usize,
	/// One retained call's arena blocks, including graph snapshots,
	/// block headers, alignment and spare capacity. Backing grows as needed.
	pub call_bytes: usize,
	/// Whole-call ceiling reservations for admitted calls in this attachment.
	pub pending_bytes: usize,
	/// Whole-call ceiling reservations per attachment and ingress, after dispatch.
	pub ingress_bytes: usize,
	/// Pinned managed records per operation, excluding temporary directory and
	/// descriptor leases. Store max_leases must leave room for both.
	pub record_capacity: usize,
	/// Live save proofs, including completed proofs retained through outcome.
	pub max_reference_saves: usize,
	/// Maximum encoded physical record, including its envelope and checksum.
	pub record_bytes: usize,
	/// Live Store roots, including restored recipes held through settlement.
	pub max_retentions: usize,
	/// Live receipt continuations, independent of pending call admission.
	pub max_continuations: usize,
	/// Complete immutable intent and exact-target custody per continuation.
	pub continuation_bytes: usize,
	pub max_continuation_targets: usize,
	/// Fixed owning reply allowance for each forwarded target execution.
	pub forward_reply_bytes: usize,
}
impl Default for Limits {
	fn default() -> Self {
		Self {
			resident_bytes: 4 * 1024 * 1024,
			staging_bytes: 4 * 1024 * 1024,
			cache_slots: 64,
			max_leases: 128,
			max_changes: 64,
			max_references: 128,
			max_operations: 32,
			call_bytes: 64 * 1024,
			pending_bytes: 4 * 1024 * 1024,
			ingress_bytes: 1024 * 1024,
			record_capacity: 8,
			max_reference_saves: 64,
			record_bytes: 64 * 1024,
			max_retentions: 128,
			max_continuations: 64,
			continuation_bytes: 64 * 1024,
			max_continuation_targets: 32,
			forward_reply_bytes: 16 * 1024,
		}
	}
}
impl Limits {
	fn raw(self) -> ffi::GlowcapLoamLimits {
		ffi::GlowcapLoamLimits {
			resident_bytes: self.resident_bytes,
			staging_bytes: self.staging_bytes,
			cache_slots: self.cache_slots,
			max_leases: self.max_leases,
			max_changes: self.max_changes,
			max_references: self.max_references,
			max_operations: self.max_operations,
			call_bytes: self.call_bytes,
			pending_bytes: self.pending_bytes,
			ingress_bytes: self.ingress_bytes,
			record_capacity: self.record_capacity,
			max_reference_saves: self.max_reference_saves,
			record_bytes: self.record_bytes,
			max_retentions: self.max_retentions,
			max_continuations: self.max_continuations,
			continuation_bytes: self.continuation_bytes,
			max_continuation_targets: self.max_continuation_targets,
			forward_reply_bytes: self.forward_reply_bytes,
		}
	}
}
/// Trusted persisted names. Serialization carries metadata, never invocation
/// authority. Restoration validates the committed rooted endpoint before use.
#[derive(Clone, Copy)]
pub struct Resource {
	raw: ffi::GlowcapLoamResource,
}
impl Resource {
	pub fn encode(self) -> [u8; 99] {
		let mut bytes = [0u8; 99];
		bytes[..33].copy_from_slice(&self.raw.owner.key);
		bytes[33..66].copy_from_slice(&self.raw.r#use.key);
		bytes[66..].copy_from_slice(&self.raw.control.key);
		bytes
	}
	pub fn decode(bytes: [u8; 99]) -> Self {
		Self {
			raw: ffi::GlowcapLoamResource {
				owner: ffi::GlowcapLoamObject {
					key: bytes[..33].try_into().expect("fixed owner key"),
				},
				r#use: ffi::GlowcapLoamObject {
					key: bytes[33..66].try_into().expect("fixed use key"),
				},
				control: ffi::GlowcapLoamObject {
					key: bytes[66..].try_into().expect("fixed control key"),
				},
			},
		}
	}
}
/// Exclusive storage persistence owner. Opening and fresh creation perform
/// blocking startup I/O; call them before admitting application traffic.
pub struct Store {
	inner: Rc<StoreInner>,
}
pub(super) struct StoreInner {
	#[cfg(not(target_arch = "wasm32"))]
	storage: Cell<*mut ffi::GlowcapLoamLmdb>,
	#[cfg(target_arch = "wasm32")]
	backend: browser::Storage,
	#[cfg(target_arch = "wasm32")]
	creation_outcome: Cell<Option<i32>>,
	#[cfg(target_arch = "wasm32")]
	creation_active: Cell<bool>,
	#[cfg(target_arch = "wasm32")]
	creation_changed: tokio::sync::Notify,
	store: *mut ffi::GlowcapLoamStore,
	pending_creation: RefCell<Option<Resource>>,
}
impl Store {
	pub fn attach(&self, host: &Host, registrations: Vec<Registration>) -> Result<Attachment> {
		self.inner.live()?;
		let shared = host.shared();
		shared.guard_handle()?;
		let diagnostics = shared
			.retained_context()
			.ok_or_else(|| invalid("Host diagnostic context is closed"))?;
		let prepared = registration::Prepared::new(registrations, diagnostics, shared.diagnostic_id());
		let mut raw = core::ptr::null_mut();
		check(
			unsafe {
				ffi::glowcap_loam_attach(
					self.inner.store,
					shared.raw(),
					prepared.declarations.as_ptr(),
					prepared.declarations.len(),
					Some(content::entropy),
					core::ptr::null_mut(),
					&mut raw,
				)
			},
			false,
		)?;
		let inner = Rc::new(AttachmentInner {
			raw: Cell::new(raw),
			store: Rc::clone(&self.inner),
			host: shared,
			callbacks: RefCell::new(Some(prepared.callbacks)),
			driving: Cell::new(false),
			progress_changed: Default::default(),
			#[cfg(target_arch = "wasm32")]
			storage_jobs: Cell::new(0),
			release_refusal_reported: Cell::new(false),
			#[cfg(target_arch = "wasm32")]
			active_restores: Cell::new(0),
			#[cfg(target_arch = "wasm32")]
			restores_changed: Default::default(),
		});
		if let Some(callbacks) = inner.callbacks.borrow_mut().as_mut() {
			for callback in callbacks {
				callback.owner = Rc::downgrade(&inner);
			}
		}
		inner.host.loam.register(&inner);
		Ok(Attachment { inner: Some(inner) })
	}
}
impl StoreInner {
	#[cfg(not(target_arch = "wasm32"))]
	fn live(&self) -> Result<()> {
		if self.storage.get().is_null() {
			Err(invalid("store is closed"))
		} else {
			Ok(())
		}
	}
	#[cfg(not(target_arch = "wasm32"))]
	fn close(&self) -> Result<()> {
		if self.storage.get().is_null() {
			return Ok(());
		}
		check(unsafe { ffi::glowcap_loam_lmdb_release(self.storage.get()) }, true)?;
		self.storage.set(core::ptr::null_mut());
		Ok(())
	}
}
impl Drop for StoreInner {
	fn drop(&mut self) {
		#[cfg(not(target_arch = "wasm32"))]
		if let Err(error) = self.close() {
			crate::record_runtime_failure(crate::FailureLayer::Binding, "loam-store.release", error);
			crate::finalizer::park_loam_store(self.storage.replace(core::ptr::null_mut()));
		}
		#[cfg(target_arch = "wasm32")]
		self.backend.retire(self.store);
	}
}
pub struct Attachment {
	inner: Option<Rc<AttachmentInner>>,
}
pub(crate) struct AttachmentInner {
	raw: Cell<*mut ffi::GlowcapLoamAttachment>,
	store: Rc<StoreInner>,
	pub(super) host: Rc<HostShared>,
	// This fixed Vec never grows after publishing element addresses to Zig.
	// Moving its owner preserves those addresses through Busy and workers.
	callbacks: RefCell<Option<Vec<content::Callback>>>,
	driving: Cell<bool>,
	progress_changed: tokio::sync::Notify,
	// Browser storage survives cancellation of its progress observer. This
	// count belongs to the retained physical jobs, not the driving future.
	#[cfg(target_arch = "wasm32")]
	storage_jobs: Cell<usize>,
	release_refusal_reported: Cell<bool>,
	#[cfg(target_arch = "wasm32")]
	active_restores: Cell<usize>,
	#[cfg(target_arch = "wasm32")]
	restores_changed: tokio::sync::Notify,
}
impl Attachment {
	fn inner(&self) -> Result<&Rc<AttachmentInner>> {
		self.inner
			.as_ref()
			.filter(|owner| !owner.raw.get().is_null())
			.ok_or_else(|| invalid("attachment is closed"))
	}
	#[cfg(not(target_arch = "wasm32"))]
	pub fn restore(&self, resource: Resource) -> Result<(Ref, Ref)> {
		let owner = self.inner()?;
		let restore = |object: &ffi::GlowcapLoamObject| -> Result<Ref> {
			let mut raw = unsafe { core::mem::zeroed() };
			check(
				unsafe { ffi::glowcap_loam_lmdb_restore(owner.store.storage.get(), owner.raw.get(), object, &mut raw) },
				true,
			)?;
			let mut reference = Ref::bare_id(raw.id);
			reference.attach_guard(crate::gc::owned_guard(&owner.host, raw.id));
			Ok(reference)
		};
		Ok((restore(&resource.raw.r#use)?, restore(&resource.raw.control)?))
	}
	pub async fn close(&mut self) -> Result<()> {
		let Some(owner) = self.inner.as_ref().map(Rc::clone) else {
			return Ok(());
		};
		#[cfg(target_arch = "wasm32")]
		while owner.active_restores.get() != 0 {
			owner.restores_changed.notified().await;
		}
		// A reply may arrive before the task driving its physical work retires.
		// Join that owner rather than racing its final portable completion.
		owner.join_progress().await;
		owner.host.kick_actions().await?;
		owner.join_progress().await;
		owner.try_close()?;
		self.inner.take();
		Ok(())
	}
}
impl Drop for Attachment {
	fn drop(&mut self) {
		if let Some(owner) = self.inner.take()
			&& !owner.close_from_drop()
		{
			owner.host.schedule_kick_or_record();
			crate::finalizer::park_loam(owner);
		}
	}
}
impl AttachmentInner {
	async fn join_progress(&self) {
		loop {
			let changed = self.progress_changed.notified();
			tokio::pin!(changed);
			changed.as_mut().enable();
			#[cfg(target_arch = "wasm32")]
			let physical = self.storage_jobs.get() != 0;
			#[cfg(not(target_arch = "wasm32"))]
			let physical = false;
			if !self.driving.get() && !physical {
				return;
			}
			changed.await;
		}
	}
	pub(crate) fn close_from_drop(&self) -> bool {
		match self.try_close() {
			Ok(()) => true,
			Err(error) => {
				if !self.release_refusal_reported.replace(true) {
					self.host.record_background_failure(error);
				}
				false
			}
		}
	}
	pub(crate) fn try_close(&self) -> Result<()> {
		if self.raw.get().is_null() {
			return Ok(());
		}
		#[cfg(target_arch = "wasm32")]
		if self.active_restores.get() != 0 {
			return Err(crate::Error::with_detail(
				crate::sys::WOULD_BLOCK,
				"Loam restores still own the attachment".into(),
			));
		}
		check(unsafe { ffi::glowcap_loam_attachment_release(self.raw.get()) }, false)?;
		self.raw.set(core::ptr::null_mut());
		self.callbacks.borrow_mut().take();
		Ok(())
	}
	#[cfg(not(target_arch = "wasm32"))]
	pub(crate) fn pending(&self) -> Result<bool> {
		if self.driving.get() || self.raw.get().is_null() {
			return Ok(false);
		}
		let mut pending = 0;
		let rc = unsafe { ffi::glowcap_loam_has_pending_work(self.raw.get(), &mut pending) };
		check(rc, false)?;
		Ok(pending != 0)
	}
	async fn progress(self: &Rc<Self>) -> Result<bool> {
		if self.raw.get().is_null() || self.driving.replace(true) {
			return Ok(false);
		}
		let _driving = Driving {
			active: &self.driving,
			changed: &self.progress_changed,
		};
		let mut progressed = 0;
		check(
			unsafe { ffi::glowcap_loam_advance(self.raw.get(), &mut progressed) },
			false,
		)?;

		loop {
			let mut raw = core::ptr::null_mut();
			check(
				unsafe { ffi::glowcap_loam_next_work(self.raw.get(), 0, &mut raw) },
				false,
			)?;
			if raw.is_null() {
				return Ok(progressed != 0);
			}
			progressed = 1;
			work::execute(Rc::clone(self), raw).await?;
		}
	}
}
struct Driving<'a> {
	active: &'a Cell<bool>,
	changed: &'a tokio::sync::Notify,
}
impl Drop for Driving<'_> {
	fn drop(&mut self) {
		self.active.set(false);
		self.changed.notify_waiters();
	}
}
/// Registration changes allocate; progress clones one immutable Rc inventory
/// and walks it without allocating a new list on each Host turn.
#[derive(Default)]
pub(crate) struct Registry {
	entries: RefCell<Rc<Vec<Weak<AttachmentInner>>>>,
}
impl Registry {
	fn register(&self, owner: &Rc<AttachmentInner>) {
		let mut entries = self.entries.borrow_mut();
		let entries = Rc::make_mut(&mut entries);
		entries.retain(|entry| entry.strong_count() != 0);
		entries.push(Rc::downgrade(owner));
	}
	pub(crate) fn close(&self) -> Result<()> {
		let entries = Rc::clone(&self.entries.borrow());
		for owner in entries.iter().filter_map(Weak::upgrade) {
			owner.try_close()?;
		}
		Ok(())
	}
	#[cfg(not(target_arch = "wasm32"))]
	pub(crate) fn pending(&self) -> Result<bool> {
		for owner in self.entries.borrow().iter().filter_map(Weak::upgrade) {
			if owner.pending()? {
				return Ok(true);
			}
		}
		Ok(false)
	}
	pub(crate) async fn progress(&self) -> Result<bool> {
		let entries = Rc::clone(&self.entries.borrow());
		let mut progressed = false;
		for owner in entries.iter().filter_map(Weak::upgrade) {
			progressed |= owner.progress().await?;
		}
		Ok(progressed)
	}
}
