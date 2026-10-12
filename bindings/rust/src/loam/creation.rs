//! Prepared resource metadata precedes physical commit. The embedding can
//! persist its exact private anchor while this guard owns unsubmitted staging.
use super::{Policy, Resource, Schema, Store, StoreInner, check, ffi, invalid};
use crate::Result;
use std::rc::Rc;

/// Owns one unsubmitted core transaction. Metadata alone cannot expose use or
/// control: restoration requires the committed records. Abort or drop before
/// commit discards staging. After submission Store owns outcome recovery.
/// This guard adds one Rc retain and fixed scalar state, with no heap allocation
/// or graph copy beyond the core resource preparation it already owns.
pub struct StagedResource {
	inner: Rc<StoreInner>,
	resource: Resource,
	staged: bool,
}
impl Store {
	/// Stage under an explicit owner identity retained by the embedding. The core
	/// admits the declaration and copies its input only during this call. Neither
	/// storage I/O nor attachment publication starts here.
	pub fn stage_resource(
		&self,
		policy: &Policy,
		schema: Schema,
		kind: u64,
		initial: &[u8],
		delegation_depth: u16,
		identity: [u8; 16],
	) -> Result<StagedResource> {
		self.inner.live()?;
		if self.inner.pending_creation.borrow().is_some() {
			return Err(invalid("a creation outcome is still retained"));
		}
		// SAFETY: `GlowcapLoamResource` is a plain C struct of three `GlowcapLoamObject` values, each a fixed `uint8_t
		// key[33]` array; all-zero is a valid value, and the callee fills it before it is read.
		let mut raw = unsafe { core::mem::zeroed() };
		check(
			// SAFETY: `self.inner.store` is the `GlowcapLoamStore` borrowed from the LMDB storage owner `self.inner`
			// holds, live because `live()` above found that owner unreleased; `policy.raw` is borrowed from `policy`
			// and `identity`, `initial`, and `schema` are borrowed from this call's arguments, all live for the whole
			// call (header: inputs are borrowed, the payload is copied into staging), and `raw` is the local
			// out-parameter the callee fills.
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
		Ok(StagedResource {
			inner: self.inner.clone(),
			resource: Resource { raw },
			staged: true,
		})
	}
	#[cfg(not(target_arch = "wasm32"))]
	pub fn create_resource(
		&self,
		policy: &Policy,
		schema: Schema,
		kind: u64,
		initial: &[u8],
		depth: u16,
	) -> Result<Resource> {
		let mut identity = [0; 16];
		getrandom::fill(&mut identity).map_err(|error| invalid(&error.to_string()))?;
		self.stage_resource(policy, schema, kind, initial, depth, identity)?
			.commit()
	}
	#[cfg(target_arch = "wasm32")]
	pub async fn create_resource(
		&self,
		policy: &Policy,
		schema: Schema,
		kind: u64,
		initial: &[u8],
		depth: u16,
	) -> Result<Resource> {
		let mut identity = [0; 16];
		getrandom::fill(&mut identity).map_err(|error| invalid(&error.to_string()))?;
		self.stage_resource(policy, schema, kind, initial, depth, identity)?
			.commit()
			.await
	}
}
impl StagedResource {
	pub fn resource(&self) -> Resource {
		self.resource
	}
	/// A refused abort keeps this guard available for an exact retry.
	pub fn abort(&mut self) -> Result<()> {
		if self.staged {
			// SAFETY: `self.inner.store` is the `GlowcapLoamStore` borrowed from the LMDB storage owner `self.inner`
			// holds; while `self.staged` is true the Store is in its staging phase, so `glowcap_loam_lmdb_release`
			// refuses Busy and the handle stays alive. The call takes no other pointer.
			check(unsafe { ffi::glowcap_loam_store_abort(self.inner.store) }, false)?;
			self.staged = false;
		}
		Ok(())
	}
	fn submitting(&mut self) -> Result<()> {
		self.inner.live()?;
		if !self.staged {
			return Err(invalid("resource staging is already retired"));
		}
		*self.inner.pending_creation.borrow_mut() = Some(self.resource);
		self.staged = false;
		Ok(())
	}
	#[cfg(not(target_arch = "wasm32"))]
	pub fn commit(mut self) -> Result<Resource> {
		self.submitting()?;
		// SAFETY: `self.inner.storage` is the non-null `GlowcapLoamLmdb` handle from `glowcap_loam_lmdb_open`
		// (`submitting` checked `live()` just above), released only by `StoreInner::close`; the call takes no other
		// pointer and runs on the Host thread outside any turn.
		let rc = unsafe { ffi::glowcap_loam_lmdb_commit(self.inner.storage.get()) };
		if rc != ffi::GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED {
			self.inner.pending_creation.borrow_mut().take();
		}
		check(rc, true)?;
		Ok(self.resource)
	}
	#[cfg(target_arch = "wasm32")]
	pub async fn commit(mut self) -> Result<Resource> {
		self.submitting()?;
		self.inner.creation_active.set(true);
		let inner = self.inner.clone();
		super::browser::retained(async move { super::browser::startup(&inner, false).await }).await?;
		self.inner.creation_outcome.set(None);
		self.inner.pending_creation.borrow_mut().take();
		Ok(self.resource)
	}
}
impl Drop for StagedResource {
	fn drop(&mut self) {
		if let Err(error) = self.abort() {
			crate::record_runtime_failure(crate::FailureLayer::Binding, "loam-resource.abort", error);
		}
	}
}
