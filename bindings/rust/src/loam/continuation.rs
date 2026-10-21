//! Receipt confirmation transfers an already owned observer, without callbacks.
use super::{AttachmentInner, Call, EffectExecution, ValueBounds, check, invalid};
use crate::{Ref, Result, sys::loam as ffi};
use std::{cell::Cell, rc::Rc};

/// Independent owners: shared immutable custody, C observer metadata, and
/// temporary source-call target decoding. Host actors and Rust buffers are separate.
pub struct ContinuationBounds {
	pub custody_bytes: usize,
	pub observer_bytes: usize,
	pub call_bytes: usize,
}

pub struct ContinuationReservation<'call> {
	raw: *mut ffi::GlowcapLoamContinuationReservation,
	owner: &'call Rc<AttachmentInner>,
}
impl ContinuationReservation<'_> {
	/// Own an independent occurrence of the actual source for receipt staging.
	pub fn source(&self) -> Result<Ref> {
		// SAFETY: `GlowcapReference` is a plain C struct of integers and null pointers; all-zero is a valid value, and
		// the callee fills it before it is read.
		let mut raw = unsafe { core::mem::zeroed() };
		check(
			// SAFETY: `self.raw` is this `ContinuationReservation`'s handle from `reserve_continuation_copying`; its
			// `'call` lifetime ties it to the receipt callback, which keeps the reservation live until it returns;
			// `raw` is an out-parameter the callee fills.
			unsafe { ffi::glowcap_loam_continuation_reservation_source(self.raw, &mut raw) },
		)?;
		Ok(owned_reference(self.owner, raw))
	}
	/// Own an independent occurrence of the exact selected target.
	pub fn target(&self, index: usize) -> Result<Ref> {
		// SAFETY: `GlowcapReference` is a plain C struct of integers and null pointers; all-zero is a valid value, and
		// the callee fills it before it is read.
		let mut raw = unsafe { core::mem::zeroed() };
		check(
			// SAFETY: `self.raw` is this `ContinuationReservation`'s handle from `reserve_continuation_copying`; its
			// `'call` lifetime ties it to the receipt callback, which keeps the reservation live until it returns;
			// `index` is a plain integer and `raw` is an out-parameter the callee fills.
			unsafe { ffi::glowcap_loam_continuation_reservation_target(self.raw, index, &mut raw) },
		)?;
		Ok(owned_reference(self.owner, raw))
	}
}
pub(super) fn owned_reference(owner: &Rc<AttachmentInner>, raw: crate::sys::GlowcapReference) -> Ref {
	let mut value = Ref::from_sys(&raw);
	value.attach_guard(crate::gc::owned_guard(&owner.host, raw.id));
	value
}

impl<'call> Call<'call> {
	/// Reserve original intent and exact targets before replacing content with
	/// an application effect receipt. The reservation cannot leave this callback.
	/// Pending owns the independent executor observation through commit/recovery.
	pub fn reserve_continuation_copying(
		&mut self,
		targets: &[Ref],
	) -> Result<(ContinuationReservation<'call>, PendingContinuation)> {
		let targets = targets.iter().map(Ref::to_sys).collect::<Result<Vec<_>>>()?;
		let mut reservation = core::ptr::null_mut();
		let mut pending = core::ptr::null_mut();
		check(
			// SAFETY: `self.raw` is the call handle the C side passed to the enclosing receipt callback; `Call`'s
			// lifetime ties this borrow to that callback, which keeps the handle live until it returns; `targets` is a
			// local `Vec` of `GlowcapReference` whose pointer and length stay live for the call; `reservation` and
			// `pending` are local out-parameters the callee fills, and a refusal leaves both null.
			unsafe {
				ffi::glowcap_loam_call_reserve_continuation_copying(
					self.raw,
					targets.as_ptr(),
					targets.len(),
					&mut reservation,
					&mut pending,
				)
			},
		)?;
		Ok((
			ContinuationReservation {
				raw: reservation,
				owner: self.owner,
			},
			PendingContinuation {
				raw: Cell::new(pending),
				owner: Rc::clone(self.owner),
			},
		))
	}
}

/// One observer of kernel confirmation. Drop detaches observation. It does not
/// classify an uncertain commit or cancel an admitted target effect. Every
/// method takes `&self`, so a shared owner can ask about absence while another
/// waits on confirmation.
pub struct PendingContinuation {
	raw: Cell<*mut ffi::GlowcapLoamPendingContinuation>,
	owner: Rc<AttachmentInner>,
}
impl PendingContinuation {
	/// Pending returns None. Confirmed absence returns UNCHANGED. Success
	/// transfers the same observer once, without allocating or admitting work.
	pub fn try_take(&self) -> Result<Option<Continuation>> {
		let pending = self.live()?;
		let mut raw = core::ptr::null_mut();
		// SAFETY: `pending` is this `PendingContinuation`'s live handle from `reserve_continuation_copying`, released
		// only by its `Drop` or consumed by this call's success; `raw` is an out-parameter the callee fills.
		let code = unsafe { ffi::glowcap_loam_pending_continuation_take(pending, &mut raw) };
		if code == crate::sys::WOULD_BLOCK {
			return Ok(None);
		}
		check(code)?;
		self.raw.set(core::ptr::null_mut());
		Ok(Some(Continuation {
			raw,
			owner: Rc::clone(&self.owner),
		}))
	}
	/// True once the commit is confirmed absent, which is final. Pending and
	/// confirmed answer false and leave the observer for `try_take`. Unlike
	/// `try_take`, it reads only the observer, so a content callback may ask.
	pub fn absent(&self) -> Result<bool> {
		let pending = self.live()?;
		let mut absent = 0;
		// SAFETY: `pending` is this `PendingContinuation`'s live handle from `reserve_continuation_copying`, released
		// only by its `Drop`; the callee only reads it, and `absent` is an out-parameter the callee fills.
		check(unsafe { ffi::glowcap_loam_pending_continuation_absent(pending, &mut absent) })?;
		Ok(absent != 0)
	}
	/// Drive through the existing Host owner. Register activity before checking
	/// progress so completion between the check and wait cannot lose its wake.
	pub async fn confirmed(&self) -> Result<Continuation> {
		loop {
			let host = Rc::clone(&self.owner.host);
			let activity = host.close_activity();
			tokio::pin!(activity);
			activity.as_mut().enable();
			if let Some(value) = self.try_take()? {
				return Ok(value);
			}
			let progress = host.kick_actions().await;
			if let Some(value) = self.try_take()? {
				return Ok(value);
			}
			progress?;
			activity.await;
		}
	}
	fn live(&self) -> Result<*mut ffi::GlowcapLoamPendingContinuation> {
		let pending = self.raw.get();
		if pending.is_null() {
			return Err(invalid("continuation observation is consumed"));
		}
		Ok(pending)
	}
}
impl Drop for PendingContinuation {
	fn drop(&mut self) {
		let raw = self.raw.get();
		if !raw.is_null() {
			// SAFETY: `raw` is this `PendingContinuation`'s non-null handle (checked above), not yet consumed by status-allow: pending state or quoted runtime label
			// `try_take`, and released exactly once here; its `owner` `Rc<AttachmentInner>` keeps the attachment alive.
			let code = unsafe { ffi::glowcap_loam_pending_continuation_release(raw) };
			if let Err(error) = check(code) {
				self.owner.host.record_background_failure(error);
			}
		}
	}
}

pub struct Continuation {
	pub(super) raw: *mut ffi::GlowcapLoamContinuation,
	pub(super) owner: Rc<AttachmentInner>,
}
impl Continuation {
	pub fn size_bound(arguments: ValueBounds, verb_bytes: usize, targets: usize) -> Result<ContinuationBounds> {
		// SAFETY: `GlowcapLoamContinuationBounds` is a plain C struct of `usize` fields; all-zero is a valid value, and
		// the callee fills it before it is read.
		let mut raw = unsafe { core::mem::zeroed() };
		check(
			// SAFETY: `arguments.raw()` is a temporary `GlowcapLoamValueBounds` that lives to the end of this statement
			// and the callee only reads it; `verb_bytes` and `targets` are plain integers and `raw` is an out-parameter
			// the callee fills; no handle is involved.
			unsafe { ffi::glowcap_loam_continuation_size_bound(&arguments.raw(), verb_bytes, targets, &mut raw) },
		)?;
		Ok(ContinuationBounds {
			custody_bytes: raw.custody_bytes,
			observer_bytes: raw.observer_bytes,
			call_bytes: raw.call_bytes,
		})
	}
	/// Public delivery rechecks original source admission after target waits.
	pub fn project(&self, index: usize) -> Result<Ref> {
		// SAFETY: `GlowcapReference` is a plain C struct of integers and null pointers; all-zero is a valid value, and
		// the callee fills it before it is read.
		let mut raw = unsafe { core::mem::zeroed() };
		check(
			// SAFETY: `self.raw` is this `Continuation`'s handle from `PendingContinuation::try_take`, released only by
			// its `Drop`; its `owner` `Rc<AttachmentInner>` keeps the attachment alive; `index` is a plain integer and
			// `raw` is an out-parameter the callee fills.
			unsafe { ffi::glowcap_loam_continuation_project(self.raw, index, &mut raw) },
		)?;
		Ok(owned_reference(&self.owner, raw))
	}
	pub fn execute(
		&self,
		index: usize,
		verb: &str,
		args: &[crate::Argument],
		reply_bytes: usize,
	) -> Result<EffectExecution> {
		EffectExecution::start(self, index, verb, args, reply_bytes)
	}
}
impl Drop for Continuation {
	fn drop(&mut self) {
		// SAFETY: `self.raw` is this `Continuation`'s handle from `PendingContinuation::try_take`, released only by its
		// `Drop`; its `owner` `Rc<AttachmentInner>` keeps the attachment alive, so the consuming release runs once
		// after the borrows of it end.
		let code = unsafe { ffi::glowcap_loam_continuation_release(self.raw) };
		if let Err(error) = check(code) {
			self.owner.host.record_background_failure(error);
		}
	}
}
