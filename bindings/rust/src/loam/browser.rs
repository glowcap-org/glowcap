//! Browser storage executes the same Zig plans under exclusive Web Lock custody.
mod plan;
pub(crate) mod work;
use super::{Attachment, Limits, Resource, Schema, Store, StoreInner, check, invalid};
use crate::{Ref, Result, sys::loam as ffi};
use js_sys::{Function, Promise, Reflect, Uint8Array};
pub use plan::StorageStatistics;
use plan::{Plan, callback};
use std::{
	cell::{Cell, RefCell},
	future::Future,
	rc::Rc,
};
use wasm_bindgen::{JsCast, JsValue, closure::Closure, prelude::*};
use wasm_bindgen_futures::JsFuture;

#[wasm_bindgen(module = "/src/loam/browser/storage.js")]
extern "C" {
	#[wasm_bindgen(catch, js_name = open)]
	fn js_open(name: &str, create: bool) -> std::result::Result<Promise, JsValue>;
	#[wasm_bindgen(catch, js_name = close)]
	fn js_close(owner: &JsValue) -> std::result::Result<Promise, JsValue>;
	#[wasm_bindgen(catch, js_name = quiescent)]
	fn js_quiescent(owner: &JsValue) -> std::result::Result<(), JsValue>;
	#[wasm_bindgen(catch, js_name = execute)]
	fn js_execute(owner: &JsValue, write: bool, step: &Function) -> std::result::Result<Promise, JsValue>;
	#[wasm_bindgen(catch, js_name = put)]
	fn js_put(rows: &JsValue, key: &Uint8Array, value: Option<&Uint8Array>) -> std::result::Result<(), JsValue>;
}
/// Await a promise the JavaScript shim settles. Settlement enters Rust once.
async fn settled(statistics: &RefCell<StorageStatistics>, promise: Promise) -> std::result::Result<JsValue, JsValue> {
	let result = JsFuture::from(promise).await;
	statistics.borrow_mut().count_callback();
	result
}
fn js_error(value: JsValue) -> crate::Error {
	invalid(&format!("browser Loam storage: {value:?}"))
}

/// One task owns each transaction through its terminal event. The oneshot is
/// only an observer. Cancellation leaves callback and C handle custody intact.
pub(super) async fn retained<T: 'static>(future: impl Future<Output = Result<T>> + 'static) -> Result<T> {
	let (answer, result) = tokio::sync::oneshot::channel();
	wasm_bindgen_futures::spawn_local(async move {
		deliver(answer, future.await);
	});
	result
		.await
		.map_err(|_| invalid("browser storage owner ended without an outcome"))?
}

fn deliver<T>(answer: tokio::sync::oneshot::Sender<Result<T>>, outcome: Result<T>) {
	if let Err(Err(error)) = answer.send(outcome) {
		crate::record_runtime_failure(crate::FailureLayer::Binding, "loam-browser.unobserved", error);
	}
}

/// Physical tasks survive LocalSet teardown. Host delivery belongs to the
/// existing LocalSet. Admit this relay before starting I/O, so cancellation of
/// the public observer cannot strand cleanup or run it on the browser executor.
/// One task/channel and Host registration own delivery, without another runtime.
pub(super) async fn retained_on_host<T: 'static>(
	host: Rc<crate::host::HostShared>,
	future: impl Future<Output = Result<T>> + 'static,
	handoff: Option<tokio::sync::oneshot::Receiver<()>>,
) -> Result<T> {
	let registration = host.start_owned_task()?;
	let (answer, result) = tokio::sync::oneshot::channel();
	if !crate::host::try_spawn_local(async move {
		let outcome = future.await;
		// Publish this operation's terminal outcome before progressing any
		// unrelated attachment, whose storage may independently be blocked.
		deliver(answer, outcome);
		// A successful send still leaves raw custody buffered in the observer.
		// Keep the admitted relay until consumption or abandonment, so dropping
		// that buffer cannot strand cleanup after the relay has ended.
		if let Some(handoff) = handoff {
			// Raw IDs have ordinary reference lifetime. An unpolled result
			// must not block Host retirement after physical work has finished.
			drop(registration);
			let _ = handoff.await;
			if let Err(error) = host.kick_actions().await {
				host.record_background_failure(error);
			}
		} else {
			if let Err(error) = host.kick_actions().await {
				host.record_background_failure(error);
			}
			drop(registration);
		}
	}) {
		return Err(invalid("Loam Host delivery requires a running LocalSet"));
	}
	result
		.await
		.map_err(|_| invalid("Loam Host delivery ended without an outcome"))?
}

pub(crate) struct Storage {
	owner: JsValue,
	closed: Cell<bool>,
	limit: usize,
	statistics: Rc<RefCell<StorageStatistics>>,
}
pub(super) struct Terminal {
	pub outcome: u32,
	pub failure: Option<crate::Error>,
}
impl Storage {
	async fn transaction(&self, write: bool, mut evaluate: impl FnMut(&mut Plan) -> Result<i32> + 'static) -> Terminal {
		let mut plan = match Plan::new(self.limit, write, Rc::clone(&self.statistics)) {
			Ok(plan) => plan,
			Err(error) => {
				return Terminal {
					outcome: 1,
					failure: Some(error),
				};
			}
		};
		// JavaScript observes the refusal to abort its transaction. Keep the
		// original typed error in Rust until that terminal event; stringifying it
		// cannot erase NotFound, capacity, or corruption distinctions at recovery.
		let failure = Rc::new(RefCell::new(None));
		let callback_failure = Rc::clone(&failure);
		let entries = Rc::clone(&self.statistics);
		let step = Closure::wrap(Box::new(
			move |rows: JsValue, key: JsValue, value: JsValue, cursor: bool| -> std::result::Result<JsValue, JsValue> {
				entries.borrow_mut().count_callback();
				let apply = || -> Result<JsValue> {
					if cursor {
						plan.input_cursor(rows, key, value)?;
					} else {
						plan.input(rows, key, value)?;
					}
					let code = evaluate(&mut plan)?;
					plan.output(code)
				};
				apply().map_err(|error| {
					let message = JsValue::from_str(&error.to_string());
					*callback_failure.borrow_mut() = Some(error);
					message
				})
			},
		)
			as Box<dyn FnMut(JsValue, JsValue, JsValue, bool) -> std::result::Result<JsValue, JsValue>>);
		let terminal = async {
			{
				// A transaction is counted where it crosses into JavaScript.
				let mut statistics = self.statistics.borrow_mut();
				statistics.transactions = statistics.transactions.saturating_add(1);
				statistics.count_js_call();
			}
			let promise = js_execute(&self.owner, write, step.as_ref().unchecked_ref()).map_err(js_error)?;
			let result = settled(&self.statistics, promise).await.map_err(js_error)?;
			// A malformed terminal result cannot establish non-commit. Fence
			// writes conservatively; Promise rejection only occurs before I/O.
			let parsed = (|| -> Result<Terminal> {
				let outcome = Reflect::get(&result, &"outcome".into())
					.map_err(js_error)?
					.as_f64()
					.ok_or_else(|| invalid("invalid browser transaction outcome"))?;
				if outcome != 0.0 && outcome != 1.0 && outcome != 2.0 {
					return Err(invalid("invalid browser transaction outcome"));
				}
				let error = Reflect::get(&result, &"error".into())
					.map_err(js_error)?
					.as_string()
					.ok_or_else(|| invalid("invalid browser transaction error"))?;
				Ok(Terminal {
					outcome: outcome as u32,
					failure: (!error.is_empty()).then(|| invalid(&error)),
				})
			})();
			Ok(parsed.unwrap_or_else(|error| Terminal {
				outcome: if write { 2 } else { 1 },
				failure: Some(error),
			}))
		}
		.await;
		let mut terminal = match terminal {
			Ok(result) => result,
			Err(error) => Terminal {
				outcome: 1,
				failure: Some(error),
			},
		};
		if let Some(error) = failure.borrow_mut().take() {
			terminal.failure = Some(error);
		}
		terminal
	}
	async fn close(&self, store: *mut ffi::GlowcapLoamStore) -> Result<()> {
		if !self.closed.get() {
			self.statistics.borrow_mut().count_js_call();
			js_quiescent(&self.owner).map_err(js_error)?;
			check(unsafe { ffi::glowcap_loam_store_release(store) })?;
			self.closed.set(true);
		}
		self.statistics.borrow_mut().count_js_call();
		settled(&self.statistics, js_close(&self.owner).map_err(js_error)?)
			.await
			.map_err(js_error)?;
		Ok(())
	}
	pub fn retire(&self, store: *mut ffi::GlowcapLoamStore) {
		if self.closed.get() {
			return;
		}
		let backend = Self {
			owner: self.owner.clone(),
			closed: Cell::new(false),
			limit: self.limit,
			statistics: Rc::clone(&self.statistics),
		};
		wasm_bindgen_futures::spawn_local(async move {
			match backend.close(store).await {
				Ok(()) => return,
				Err(error) => {
					crate::record_runtime_failure(crate::FailureLayer::Binding, "loam-store.release", error);
					if backend.closed.get() {
						return;
					}
				}
			}
			let terminal = backend
				.transaction(false, move |plan| {
					Ok(unsafe { ffi::glowcap_loam_store_plan(store, 1, Some(callback), plan.context()) })
				})
				.await;
			let rc = unsafe { ffi::glowcap_loam_store_finish(store, 1, terminal.outcome) };
			if rc == crate::sys::OK || rc == ffi::GLOWCAP_LOAM_ERR_UNCHANGED {
				if let Err(error) = backend.close(store).await {
					crate::record_runtime_failure(crate::FailureLayer::Binding, "loam-browser.release", error);
				}
			} else if let Err(error) = check(rc) {
				// Unresolved authority retains its database and exclusive lock.
				// Report once; releasing either would admit a stale writer.
				crate::record_runtime_failure(crate::FailureLayer::Binding, "loam-browser.recovery", error);
				crate::finalizer::park_browser_loam_store(backend, store);
			}
		});
	}
}
impl StoreInner {
	pub(super) fn live(&self) -> Result<()> {
		if self.backend.closed.get() {
			Err(invalid("store is closed"))
		} else {
			Ok(())
		}
	}
}

impl Store {
	/// Join database and Web Lock retirement. Dropping the observer leaves the
	/// close owner alive. Successful return permits an immediate reopen.
	pub async fn close(&mut self) -> Result<()> {
		let inner = Rc::clone(&self.inner);
		retained(async move { inner.backend.close(inner.store).await }).await
	}
	/// Inspect physical adapter work and copies independently of core residency.
	pub fn storage_statistics(&self) -> StorageStatistics {
		*self.inner.backend.statistics.borrow()
	}
	/// Claim one origin database exclusively. Creation and reopening are explicit.
	/// Unsupported locking or durability refuses, with no memory fallback.
	pub async fn open(
		name: &str,
		identity: [u8; 16],
		create: bool,
		schemas: &[Schema],
		limits: Limits,
	) -> Result<Self> {
		Self::open_mode(name, identity, u32::from(create), schemas, limits).await
	}
	/// Bootstrap only under a private identity persisted by the embedding.
	/// Existing Store records and identity are verified and never replaced.
	pub async fn open_bootstrap(name: &str, identity: [u8; 16], schemas: &[Schema], limits: Limits) -> Result<Self> {
		Self::open_mode(name, identity, 2, schemas, limits).await
	}
	async fn open_mode(name: &str, identity: [u8; 16], mode: u32, schemas: &[Schema], limits: Limits) -> Result<Self> {
		if name.is_empty() || name.len() > 256 {
			return Err(invalid("Loam database name must contain 1 to 256 UTF-8 bytes"));
		}
		if unsafe { ffi::glowcap_loam_archive_fingerprint() } != ffi::LOAM_ARCHIVE_FINGERPRINT {
			return Err(invalid("Loam archive contract mismatch"));
		}
		let schemas: Vec<_> = schemas.iter().map(|s| s.raw()).collect();
		// Validate schemas and budgets before opening or durably claiming storage.
		check(unsafe { ffi::glowcap_loam_validate_configuration(schemas.as_ptr(), schemas.len(), &limits.raw()) })?;
		let limit = limits.record_bytes.max(ffi::GLOWCAP_LOAM_METADATA_SIZE);
		Plan::input_capacity(limit)?;
		let name = name.to_owned();
		retained(async move {
			let statistics: Rc<RefCell<StorageStatistics>> = Default::default();
			statistics.borrow_mut().count_js_call();
			let owner = settled(&statistics, js_open(&name, mode != 0).map_err(js_error)?)
				.await
				.map_err(js_error)?;
			let backend = Storage {
				owner,
				closed: Cell::new(false),
				limit,
				statistics,
			};
			let slot = Rc::new(Cell::new(core::ptr::null_mut()));
			let output = Rc::clone(&slot);
			let terminal = backend
				.transaction(true, move |plan| {
					let previous = match plan.get(b"m") {
						Ok(value) => value,
						Err(error) => return Ok(error.code),
					};
					let mut metadata = [0u8; ffi::GLOWCAP_LOAM_METADATA_SIZE];
					check(unsafe {
						ffi::glowcap_loam_metadata_claim(
							identity.as_ptr(),
							mode,
							previous.map_or(core::ptr::null(), |v| v.as_ptr()),
							previous.map_or(0, |v| v.len()),
							metadata.as_mut_ptr(),
							metadata.len(),
						)
					})?;
					let mut store = core::ptr::null_mut();
					check(unsafe {
						ffi::glowcap_loam_store_new(
							metadata.as_ptr(),
							metadata.len(),
							schemas.as_ptr(),
							schemas.len(),
							&limits.raw(),
							&mut store,
						)
					})?;
					output.set(store);
					plan.put(b"m", Some(&metadata))?;
					Ok(crate::sys::OK)
				})
				.await;
			if terminal.outcome != 0 {
				if !slot.get().is_null() {
					check(unsafe { ffi::glowcap_loam_store_release(slot.get()) })?;
				}
				backend.statistics.borrow_mut().count_js_call();
				settled(&backend.statistics, js_close(&backend.owner).map_err(js_error)?)
					.await
					.map_err(js_error)?;
				return Err(terminal
					.failure
					.unwrap_or_else(|| invalid("browser claim did not commit")));
			}
			Ok(Self {
				inner: Rc::new(StoreInner {
					backend,
					store: slot.get(),
					pending_creation: Default::default(),
					creation_outcome: Cell::new(None),
					creation_active: Cell::new(false),
					creation_changed: Default::default(),
				}),
			})
		})
		.await
	}
	/// Run one bounded collection step of `work_limit` units plus the steps that
	/// finish an open unit. Returns true while the cycle has more to do. The
	/// step waits for a creation in flight, is refused while an attachment is
	/// live or a creation is staged, and a refused or aborted step committed
	/// nothing. An indeterminate IndexedDB outcome leaves the store needing the
	/// same recovery as a creation.
	pub async fn collect(&self, work_limit: usize) -> Result<bool> {
		claim_store_batch(&self.inner).await;
		let inner = Rc::clone(&self.inner);
		retained(async move {
			let _done = CreationDone(Rc::clone(&inner));
			let store = inner.store;
			let terminal = inner
				.backend
				.transaction(true, move |plan| {
					Ok(unsafe {
						ffi::glowcap_loam_store_collect_plan(store, work_limit, Some(callback), plan.context())
					})
				})
				.await;
			// A batch that never reached evaluation left no staging, so there is
			// nothing to abort, and the refusal that stopped it is the cause.
			let rc = unsafe { ffi::glowcap_loam_store_finish(store, 0, terminal.outcome) };
			if let Err(error) = check(rc) {
				return Err(match terminal.failure {
					Some(physical) if rc == ffi::GLOWCAP_LOAM_ERR_STALE_COMPLETION => physical,
					Some(physical) => error.with_secondary(physical),
					None => error,
				});
			}
			if let Some(error) = terminal.failure {
				return Err(error);
			}
			let mut collecting = 0u32;
			// SAFETY: `store` is the live portable Store this handle owns, released only by `close`, and
			// `collecting` is a valid output for the call.
			check(unsafe { ffi::glowcap_loam_store_collecting(store, &mut collecting) })?;
			Ok(collecting != 0)
		})
		.await
	}
	pub async fn recover_creation(&self) -> Result<Resource> {
		while self.inner.creation_active.get() {
			self.inner.creation_changed.notified().await;
		}
		let resource = self
			.inner
			.pending_creation
			.borrow()
			.as_ref()
			.copied()
			.ok_or_else(|| invalid("there is no retained creation result"))?;
		let inner = Rc::clone(&self.inner);
		let result = if let Some(code) = inner.creation_outcome.get() {
			check(code)
		} else {
			inner.creation_active.set(true);
			retained(async move { startup(&inner, true).await }).await
		};
		if result.as_ref().is_ok()
			|| result
				.as_ref()
				.is_err_and(|error| error.code == ffi::GLOWCAP_LOAM_ERR_UNCHANGED)
		{
			self.inner.creation_outcome.set(None);
			self.inner.pending_creation.borrow_mut().take();
		}
		result?;
		self.inner.pending_creation.borrow_mut().take();
		Ok(resource)
	}
}
/// Wait until no store-level batch is in flight, then claim the flag for the
/// caller. A creation commit, a creation recovery, and a collection step each
/// finish through `glowcap_loam_store_finish`, which retires whichever batch is
/// open, so only one may be in flight. The claim has no await after the wait,
/// so nothing interleaves between them.
pub(super) async fn claim_store_batch(inner: &StoreInner) {
	while inner.creation_active.get() {
		inner.creation_changed.notified().await;
	}
	inner.creation_active.set(true);
}
/// Clears the store-level batch flag when the holder's work ends, however it ends.
struct CreationDone(Rc<StoreInner>);
impl Drop for CreationDone {
	fn drop(&mut self) {
		self.0.creation_active.set(false);
		self.0.creation_changed.notify_waiters();
	}
}
pub(super) async fn startup(inner: &Rc<StoreInner>, recovery: bool) -> Result<()> {
	let _done = CreationDone(Rc::clone(inner));
	let store = inner.store;
	let terminal = inner
		.backend
		.transaction(!recovery, move |plan| {
			Ok(unsafe { ffi::glowcap_loam_store_plan(store, u32::from(recovery), Some(callback), plan.context()) })
		})
		.await;
	let mut rc = unsafe { ffi::glowcap_loam_store_finish(store, u32::from(recovery), terminal.outcome) };
	if !recovery && terminal.outcome == 1 && rc == ffi::GLOWCAP_LOAM_ERR_STALE_COMPLETION {
		// The database refused before evaluation prepared a write. Retire
		// the still-unsubmitted staging through its ordinary abort boundary.
		check(unsafe { ffi::glowcap_loam_store_abort(store) })?;
		rc = ffi::GLOWCAP_LOAM_ERR_UNCHANGED;
	}
	if rc == crate::sys::OK || rc == ffi::GLOWCAP_LOAM_ERR_UNCHANGED {
		inner.creation_outcome.set(Some(rc));
	}
	if let Err(error) = check(rc) {
		return Err(if let Some(physical) = terminal.failure {
			error.with_secondary(physical)
		} else {
			error
		});
	}
	if let Some(error) = terminal.failure {
		return Err(error);
	}
	Ok(())
}
impl Attachment {
	pub async fn restore(&self, resource: Resource) -> Result<(Ref, Ref)> {
		let owner = Rc::clone(self.inner()?);
		// Acquire before spawning: cancelling the observer can immediately make
		// explicit close possible, before the retained task has first run.
		let (consumed, handoff) = tokio::sync::oneshot::channel();
		let custody = RestoreCustody::new(Rc::clone(&owner))?;
		let occurrences = RestoredOccurrences {
			host: Rc::clone(&owner.host),
			consumed: Some(consumed),
			ids: [0; 2],
		};
		retained_on_host(
			Rc::clone(&owner.host),
			async move {
				retained(async move {
					let _custody = custody;
					let mut occurrences = occurrences;
					for (index, object) in [resource.raw.r#use, resource.raw.control].into_iter().enumerate() {
						loop {
							let slot = Rc::new(Cell::new(0u64));
							let output = Rc::clone(&slot);
							let attached = owner.raw.get();
							let terminal = owner
								.store
								.backend
								.transaction(false, move |plan| {
									let mut raw = unsafe { core::mem::zeroed() };
									let rc = unsafe {
										ffi::glowcap_loam_restore_plan(
											attached,
											&object,
											Some(callback),
											plan.context(),
											&mut raw,
										)
									};
									if rc == crate::sys::OK {
										output.set(raw.id);
									}
									Ok(rc)
								})
								.await;
							occurrences.ids[index] = slot.get();
							if terminal.outcome == 0 {
								break;
							}
							let failure = terminal
								.failure
								.unwrap_or_else(|| invalid("browser restore did not complete"));
							if slot.get() != 0 || !owner.waits_on_commit(&failure) {
								return Err(failure);
							}
							owner.join_progress().await;
						}
						if occurrences.ids[index] == 0 {
							return Err(invalid("browser restore returned no capability"));
						}
					}
					Ok(occurrences)
				})
				.await
			},
			Some(handoff),
		)
		.await
		.map(RestoredOccurrences::into_refs)
	}
}

/// Rc preserves Rust allocation. This obligation also prevents explicit C
/// retirement through both restore transactions and terminal handling. The
/// fixed counter and call-owned guard add no allocation or record copy.
struct RestoreCustody(Rc<super::AttachmentInner>);
impl RestoreCustody {
	fn new(owner: Rc<super::AttachmentInner>) -> Result<Self> {
		let count = owner
			.active_restores
			.get()
			.checked_add(1)
			.ok_or_else(|| invalid("restore custody overflow"))?;
		owner.active_restores.set(count);
		Ok(Self(owner))
	}
}
impl Drop for RestoreCustody {
	fn drop(&mut self) {
		let remaining = self.0.active_restores.get() - 1;
		self.0.active_restores.set(remaining);
		if remaining == 0 {
			self.0.restores_changed.notify_waiters();
			self.0.host.note_close_activity();
		}
	}
}

/// Two separately retained occurrences, even when their IDs coincide. Physical
/// completion keeps only POD IDs. Abandonment and partial restoration park each
/// occurrence exactly once. The admitted Host relay owns their actual release.
struct RestoredOccurrences {
	host: Rc<crate::host::HostShared>,
	consumed: Option<tokio::sync::oneshot::Sender<()>>,
	ids: [u64; 2],
}
impl RestoredOccurrences {
	fn into_refs(mut self) -> (Ref, Ref) {
		let refs = self.ids.map(|id| {
			let mut reference = Ref::bare_id(id);
			reference.attach_guard(crate::gc::owned_guard(&self.host, id));
			reference
		});
		self.ids = [0; 2];
		let [access, control] = refs;
		(access, control)
	}
}
impl Drop for RestoredOccurrences {
	fn drop(&mut self) {
		if !self.host.raw().is_null() {
			self.host
				.gc_pending
				.borrow_mut()
				.extend(self.ids.iter().copied().filter(|id| *id != 0));
			self.host.note_close_activity();
		}
		// Signal only after parking every outstanding occurrence.
		if let Some(consumed) = self.consumed.take() {
			let _ = consumed.send(());
		}
	}
}
