//! Optional durable resources on an existing Host. Zig owns policy and commit
//! decisions; the Rust projection owns callbacks, handles, and storage jobs.
#[cfg(target_arch = "wasm32")]
pub(crate) mod browser;
mod content;
#[cfg(target_arch = "wasm32")]
pub use browser::StorageStatistics;
mod policy;
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
pub use content::{Call, Content, Method, ReferenceRequest, Registration, Retry};
pub use policy::{ControlPowers, Operator, Policy, PolicyValue, Requirement};
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
#[derive(Clone, Copy)]
pub struct Limits {
	pub resident_bytes: usize,
	pub staging_bytes: usize,
	pub cache_slots: usize,
	pub max_leases: usize,
	pub max_changes: usize,
	pub max_references: usize,
	pub max_operations: usize,
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
	/// Open LMDB with an explicit physical map budget (at least 1 MiB). This
	/// limit is independent of resident and staged record bytes in `Limits`.
	#[cfg(not(target_arch = "wasm32"))]
	pub fn open(
		path: &std::path::Path,
		identity: [u8; 16],
		create: bool,
		map_bytes: usize,
		schemas: &[Schema],
		limits: Limits,
	) -> Result<Self> {
		if unsafe { ffi::glowcap_loam_archive_fingerprint() } != ffi::LOAM_ARCHIVE_FINGERPRINT
			|| unsafe { ffi::glowcap_loam_lmdb_archive_fingerprint() } != ffi::LOAM_LMDB_ARCHIVE_FINGERPRINT
		{
			return Err(invalid("Loam archive contract mismatch"));
		}
		let path = path.to_str().ok_or_else(|| invalid("store path is not UTF-8"))?;
		let schemas: Vec<_> = schemas
			.iter()
			.map(|s| ffi::GlowcapLoamSchema {
				id: s.id,
				version: s.version,
				max_payload: s.max_payload,
				max_edges: s.max_edges,
			})
			.collect();
		let mut storage = core::ptr::null_mut();
		let mut store = core::ptr::null_mut();
		check(
			unsafe {
				ffi::glowcap_loam_lmdb_open(
					path.as_ptr(),
					path.len(),
					identity.as_ptr(),
					u32::from(create),
					map_bytes,
					schemas.as_ptr(),
					schemas.len(),
					&limits.raw(),
					&mut storage,
					&mut store,
				)
			},
			true,
		)?;
		Ok(Self {
			inner: Rc::new(StoreInner {
				storage: Cell::new(storage),
				store,
				pending_creation: RefCell::new(None),
			}),
		})
	}
	#[cfg(not(target_arch = "wasm32"))]
	pub fn create_resource(
		&self,
		policy: &Policy,
		schema: Schema,
		kind: u64,
		initial: &[u8],
		delegation_depth: u16,
	) -> Result<Resource> {
		self.inner.live()?;
		let mut identity = [0u8; 16];
		getrandom::fill(&mut identity).map_err(|error| invalid(&error.to_string()))?;
		let mut resource = unsafe { core::mem::zeroed() };
		check(
			unsafe {
				ffi::glowcap_loam_resource_stage(
					self.inner.store,
					&policy.raw,
					identity.as_ptr(),
					kind,
					schema.id,
					schema.version,
					initial.as_ptr(),
					initial.len(),
					delegation_depth,
					&mut resource,
				)
			},
			false,
		)?;
		let resource = Resource { raw: resource };
		*self.inner.pending_creation.borrow_mut() = Some(resource);
		let rc = unsafe { ffi::glowcap_loam_lmdb_commit(self.inner.storage.get()) };
		if rc != ffi::GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED {
			self.inner.pending_creation.borrow_mut().take();
		}
		check(rc, true)?;
		Ok(resource)
	}
	/// Resolve an indeterminate creation after the synchronous commit returned.
	/// The output stays retained until the core proves commit or absence.
	#[cfg(not(target_arch = "wasm32"))]
	pub fn recover_creation(&self) -> Result<Resource> {
		let resource = self
			.inner
			.pending_creation
			.borrow()
			.as_ref()
			.copied()
			.ok_or_else(|| invalid("there is no retained creation result"))?;
		let rc = unsafe { ffi::glowcap_loam_lmdb_recover(self.inner.storage.get()) };
		if rc == crate::sys::OK || rc == ffi::GLOWCAP_LOAM_ERR_UNCHANGED {
			self.inner.pending_creation.borrow_mut().take();
		}
		check(rc, true)?;
		Ok(resource)
	}
	pub fn attach(&self, host: &Host, registrations: Vec<Registration>) -> Result<Attachment> {
		self.inner.live()?;
		let shared = host.shared();
		shared.guard_handle()?;
		let diagnostics = shared
			.retained_context()
			.ok_or_else(|| invalid("Host diagnostic context is closed"))?;
		let (rows, callbacks): (Vec<_>, Vec<_>) = registrations
			.into_iter()
			.map(|registration| {
				(
					(registration.schema, registration.version, registration.methods),
					content::Callback {
						content: registration.content,
						diagnostics: Rc::clone(&diagnostics),
						host_id: shared.diagnostic_id(),
					},
				)
			})
			.unzip();
		let method_tables: Vec<Vec<_>> = rows
			.iter()
			.map(|row| {
				row.2
					.iter()
					.map(|method| ffi::GlowcapLoamMethod {
						verb: method.verb.as_ptr(),
						verb_len: method.verb.len(),
						retry: match method.retry {
							Retry::ReadOnly => 0,
							Retry::Idempotent => 1,
							Retry::Receipt => 2,
						},
					})
					.collect()
			})
			.collect();
		let declarations: Vec<_> = rows
			.iter()
			.zip(&method_tables)
			.zip(&callbacks)
			.map(|((row, methods), callback)| ffi::GlowcapLoamContent {
				schema: row.0,
				version: row.1,
				context: (callback as *const content::Callback).cast_mut().cast(),
				methods: methods.as_ptr(),
				method_count: methods.len(),
				requirement: Some(content::requirement),
				invoke: Some(content::invoke),
				references: Some(content::references),
				dependent_requirement: Some(content::dependent_requirement),
			})
			.collect();
		let mut raw = core::ptr::null_mut();
		check(
			unsafe {
				ffi::glowcap_loam_attach(
					self.inner.store,
					shared.raw(),
					declarations.as_ptr(),
					declarations.len(),
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
			callbacks: RefCell::new(Some(callbacks)),
			driving: Cell::new(false),
			release_refusal_reported: Cell::new(false),
		});
		inner.host.loam.register(&inner);
		Ok(Attachment { inner: Some(inner) })
	}
	/// Refusal preserves the storage owner. The C Store's borrow counts decide
	/// whether attachments and effects still prevent release.
	pub fn close(&mut self) -> Result<()> {
		self.inner.close()
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
		if let Err(error) = self.close() {
			crate::record_runtime_failure(crate::FailureLayer::Binding, "loam-store.release", error);
			#[cfg(not(target_arch = "wasm32"))]
			crate::finalizer::park_loam_store(self.storage.replace(core::ptr::null_mut()));
			#[cfg(target_arch = "wasm32")]
			self.backend.retire(self.store);
		}
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
	release_refusal_reported: Cell<bool>,
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
		owner.host.kick_actions().await?;
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
		let _driving = Driving(&self.driving);
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
			let rc = work::execute(Rc::clone(self), raw).await?;
			if rc != ffi::GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED {
				check(rc, false)?;
			}
		}
	}
}
struct Driving<'a>(&'a Cell<bool>);
impl Drop for Driving<'_> {
	fn drop(&mut self) {
		self.0.set(false);
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
