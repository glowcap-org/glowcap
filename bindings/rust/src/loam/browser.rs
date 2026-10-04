//! Browser storage executes the same Zig plans under exclusive Web Lock custody.
mod plan;
pub(crate) mod work;
use super::{Attachment, Limits, Policy, Resource, Schema, Store, StoreInner, check, invalid};
use crate::{Ref, Result, sys::loam as ffi};
use js_sys::{Function, Promise, Reflect};
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
	fn js_close(owner: &JsValue) -> std::result::Result<(), JsValue>;
	#[wasm_bindgen(catch, js_name = execute)]
	fn js_execute(owner: &JsValue, write: bool, step: &Function) -> std::result::Result<Promise, JsValue>;
}
fn js_error(value: JsValue) -> crate::Error {
	invalid(&format!("browser Loam storage: {value:?}"))
}

/// One task owns each transaction through its terminal event. The oneshot is
/// only an observer; cancellation leaves callback and C handle custody intact.
async fn retained<T: 'static>(future: impl Future<Output = Result<T>> + 'static) -> Result<T> {
	let (answer, result) = tokio::sync::oneshot::channel();
	wasm_bindgen_futures::spawn_local(async move {
		let outcome = future.await;
		if let Err(Err(error)) = answer.send(outcome) {
			crate::record_runtime_failure(crate::FailureLayer::Binding, "loam-browser.unobserved", error);
		}
	});
	result
		.await
		.map_err(|_| invalid("browser storage owner ended without an outcome"))?
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
		{
			let mut statistics = self.statistics.borrow_mut();
			statistics.transactions = statistics.transactions.saturating_add(1);
		}
		let mut plan = Plan::new(self.limit, Rc::clone(&self.statistics));
		let step = Closure::wrap(Box::new(
			move |key: JsValue, value: JsValue| -> std::result::Result<JsValue, JsValue> {
				let apply = || -> Result<JsValue> {
					plan.input(key, value)?;
					let code = evaluate(&mut plan)?;
					plan.output(code)
				};
				apply().map_err(|error| JsValue::from_str(&error.to_string()))
			},
		)
			as Box<dyn FnMut(JsValue, JsValue) -> std::result::Result<JsValue, JsValue>>);
		let terminal = async {
			let promise = js_execute(&self.owner, write, step.as_ref().unchecked_ref()).map_err(js_error)?;
			let result = JsFuture::from(promise).await.map_err(js_error)?;
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
		match terminal {
			Ok(result) => result,
			Err(error) => Terminal {
				outcome: 1,
				failure: Some(error),
			},
		}
	}
	fn close(&self, store: *mut ffi::GlowcapLoamStore) -> Result<()> {
		if self.closed.get() {
			return Ok(());
		}
		check(unsafe { ffi::glowcap_loam_store_release(store) }, false)?;
		self.closed.set(true);
		js_close(&self.owner).map_err(js_error)
	}
	pub fn retire(&self, store: *mut ffi::GlowcapLoamStore) {
		let backend = Self {
			owner: self.owner.clone(),
			closed: Cell::new(false),
			limit: self.limit,
			statistics: Rc::clone(&self.statistics),
		};
		wasm_bindgen_futures::spawn_local(async move {
			let terminal = backend
				.transaction(false, move |plan| {
					Ok(unsafe { ffi::glowcap_loam_store_plan(store, 1, Some(callback), plan.context()) })
				})
				.await;
			let rc = unsafe { ffi::glowcap_loam_store_finish(store, 1, terminal.outcome) };
			if rc == crate::sys::OK || rc == ffi::GLOWCAP_LOAM_ERR_UNCHANGED {
				if let Err(error) = backend.close(store) {
					crate::record_runtime_failure(crate::FailureLayer::Binding, "loam-browser.release", error);
				}
			} else if let Err(error) = check(rc, false) {
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
	pub(super) fn close(&self) -> Result<()> {
		self.backend.close(self.store)
	}
}

impl Store {
	/// Inspect physical adapter work and copies independently of core residency.
	pub fn storage_statistics(&self) -> StorageStatistics {
		*self.inner.backend.statistics.borrow()
	}
	/// Claim one origin database exclusively. Creation and reopening are explicit;
	/// unsupported locking or durability refuses, with no memory fallback.
	pub async fn open(
		name: &str,
		identity: [u8; 16],
		create: bool,
		schemas: &[Schema],
		limits: Limits,
	) -> Result<Self> {
		if name.is_empty() || name.len() > 256 {
			return Err(invalid("Loam database name must contain 1 to 256 UTF-8 bytes"));
		}
		if unsafe { ffi::glowcap_loam_archive_fingerprint() } != ffi::LOAM_ARCHIVE_FINGERPRINT {
			return Err(invalid("Loam archive contract mismatch"));
		}
		let schemas: Vec<_> = schemas
			.iter()
			.map(|s| ffi::GlowcapLoamSchema {
				id: s.id,
				version: s.version,
				max_payload: s.max_payload,
				max_edges: s.max_edges,
			})
			.collect();
		// Validate schemas and budgets before opening or durably claiming storage.
		check(
			unsafe { ffi::glowcap_loam_validate_configuration(schemas.as_ptr(), schemas.len(), &limits.raw()) },
			false,
		)?;
		let limit = limits
			.staging_bytes
			.checked_add(limits.resident_bytes)
			.ok_or_else(|| invalid("browser transaction budget overflow"))?;
		let name = name.to_owned();
		retained(async move {
			let owner = JsFuture::from(js_open(&name, create).map_err(js_error)?)
				.await
				.map_err(js_error)?;
			let backend = Storage {
				owner,
				closed: Cell::new(false),
				limit,
				statistics: Default::default(),
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
					check(
						unsafe {
							ffi::glowcap_loam_metadata_claim(
								identity.as_ptr(),
								u32::from(create),
								previous.map_or(core::ptr::null(), |v| v.as_ptr()),
								previous.map_or(0, |v| v.len()),
								metadata.as_mut_ptr(),
								metadata.len(),
							)
						},
						false,
					)?;
					let mut store = core::ptr::null_mut();
					check(
						unsafe {
							ffi::glowcap_loam_store_new(
								metadata.as_ptr(),
								metadata.len(),
								schemas.as_ptr(),
								schemas.len(),
								&limits.raw(),
								&mut store,
							)
						},
						false,
					)?;
					output.set(store);
					plan.put(b"m", Some(&metadata))?;
					Ok(crate::sys::OK)
				})
				.await;
			if terminal.outcome != 0 {
				if !slot.get().is_null() {
					check(unsafe { ffi::glowcap_loam_store_release(slot.get()) }, false)?;
				}
				js_close(&backend.owner).map_err(js_error)?;
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
	pub async fn create_resource(
		&self,
		policy: &Policy,
		schema: Schema,
		kind: u64,
		initial: &[u8],
		delegation_depth: u16,
	) -> Result<Resource> {
		self.inner.live()?;
		if self.inner.pending_creation.borrow().is_some() {
			return Err(invalid("a creation outcome is still retained"));
		}
		let mut identity = [0u8; 16];
		getrandom::fill(&mut identity).map_err(|error| invalid(&error.to_string()))?;
		let mut raw = unsafe { core::mem::zeroed() };
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
					&mut raw,
				)
			},
			false,
		)?;
		let resource = Resource { raw };
		*self.inner.pending_creation.borrow_mut() = Some(resource);
		self.inner.creation_active.set(true);
		let inner = Rc::clone(&self.inner);
		retained(async move { startup(&inner, false).await }).await?;
		self.inner.creation_outcome.set(None);
		self.inner.pending_creation.borrow_mut().take();
		Ok(resource)
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
			check(code, false)
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
async fn startup(inner: &Rc<StoreInner>, recovery: bool) -> Result<()> {
	struct Done(Rc<StoreInner>);
	impl Drop for Done {
		fn drop(&mut self) {
			self.0.creation_active.set(false);
			self.0.creation_changed.notify_waiters();
		}
	}
	let _done = Done(Rc::clone(inner));
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
		check(unsafe { ffi::glowcap_loam_store_abort(store) }, false)?;
		rc = ffi::GLOWCAP_LOAM_ERR_UNCHANGED;
	}
	if rc == crate::sys::OK || rc == ffi::GLOWCAP_LOAM_ERR_UNCHANGED {
		inner.creation_outcome.set(Some(rc));
	}
	if let Err(error) = check(rc, false) {
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
		retained(async move {
			let mut references = Vec::new();
			for object in [resource.raw.r#use, resource.raw.control] {
				let slot = Rc::new(Cell::new(0u64));
				let output = Rc::clone(&slot);
				let attached = owner.raw.get();
				let terminal = owner
					.store
					.backend
					.transaction(false, move |plan| {
						let mut raw = unsafe { core::mem::zeroed() };
						let rc = unsafe {
							ffi::glowcap_loam_restore_plan(attached, &object, Some(callback), plan.context(), &mut raw)
						};
						if rc == crate::sys::OK {
							output.set(raw.id);
						}
						Ok(rc)
					})
					.await;
				let reference = if slot.get() != 0 {
					let mut reference = Ref::bare_id(slot.get());
					reference.attach_guard(crate::gc::owned_guard(&owner.host, slot.get()));
					Some(reference)
				} else {
					None
				};
				if terminal.outcome != 0 {
					return Err(terminal
						.failure
						.unwrap_or_else(|| invalid("browser restore did not complete")));
				}
				references.push(reference.ok_or_else(|| invalid("browser restore returned no capability"))?);
			}
			let control = references.pop().expect("control occurrence");
			Ok((references.pop().expect("use occurrence"), control))
		})
		.await
	}
}
