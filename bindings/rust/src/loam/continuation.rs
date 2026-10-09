//! Receipt confirmation transfers an already owned observer, without callbacks.
use super::{AttachmentInner, Call, EffectExecution, ValueBounds, check, invalid};
use crate::{Ref, Result, sys::loam as ffi};
use std::rc::Rc;

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
		let mut raw = unsafe { core::mem::zeroed() };
		check(
			unsafe { ffi::glowcap_loam_continuation_reservation_source(self.raw, &mut raw) },
			false,
		)?;
		Ok(owned_reference(self.owner, raw))
	}
	/// Own an independent occurrence of the exact selected target.
	pub fn target(&self, index: usize) -> Result<Ref> {
		let mut raw = unsafe { core::mem::zeroed() };
		check(
			unsafe { ffi::glowcap_loam_continuation_reservation_target(self.raw, index, &mut raw) },
			false,
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
	/// an application effect receipt. The reservation cannot leave this callback;
	/// Pending owns the independent executor observation through commit/recovery.
	pub fn reserve_continuation_copying(
		&mut self,
		targets: &[Ref],
	) -> Result<(ContinuationReservation<'call>, PendingContinuation)> {
		let targets = targets.iter().map(Ref::to_sys).collect::<Result<Vec<_>>>()?;
		let mut reservation = core::ptr::null_mut();
		let mut pending = core::ptr::null_mut();
		check(
			unsafe {
				ffi::glowcap_loam_call_reserve_continuation_copying(
					self.raw,
					targets.as_ptr(),
					targets.len(),
					&mut reservation,
					&mut pending,
				)
			},
			false,
		)?;
		Ok((
			ContinuationReservation {
				raw: reservation,
				owner: self.owner,
			},
			PendingContinuation {
				raw: pending,
				owner: Rc::clone(self.owner),
			},
		))
	}
}

/// One observer of kernel confirmation. Drop detaches observation; it does not
/// classify an uncertain commit or cancel an admitted target effect.
pub struct PendingContinuation {
	raw: *mut ffi::GlowcapLoamPendingContinuation,
	owner: Rc<AttachmentInner>,
}
impl PendingContinuation {
	/// Pending returns None; confirmed absence returns UNCHANGED. Success
	/// transfers the same observer once, without allocating or admitting work.
	pub fn try_take(&mut self) -> Result<Option<Continuation>> {
		if self.raw.is_null() {
			return Err(invalid("continuation observation is consumed"));
		}
		let mut raw = core::ptr::null_mut();
		let code = unsafe { ffi::glowcap_loam_pending_continuation_take(self.raw, &mut raw) };
		if code == crate::sys::WOULD_BLOCK {
			return Ok(None);
		}
		check(code, false)?;
		self.raw = core::ptr::null_mut();
		Ok(Some(Continuation {
			raw,
			owner: Rc::clone(&self.owner),
		}))
	}
	/// Drive through the existing Host owner. Register activity before checking
	/// progress so completion between the check and wait cannot lose its wake.
	pub async fn confirmed(&mut self) -> Result<Continuation> {
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
}
impl Drop for PendingContinuation {
	fn drop(&mut self) {
		if !self.raw.is_null() {
			let code = unsafe { ffi::glowcap_loam_pending_continuation_release(self.raw) };
			if let Err(error) = check(code, false) {
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
		let mut raw = unsafe { core::mem::zeroed() };
		check(
			unsafe { ffi::glowcap_loam_continuation_size_bound(&arguments.raw(), verb_bytes, targets, &mut raw) },
			false,
		)?;
		Ok(ContinuationBounds {
			custody_bytes: raw.custody_bytes,
			observer_bytes: raw.observer_bytes,
			call_bytes: raw.call_bytes,
		})
	}
	/// Public delivery rechecks original source admission after target waits.
	pub fn project(&self, index: usize) -> Result<Ref> {
		let mut raw = unsafe { core::mem::zeroed() };
		check(
			unsafe { ffi::glowcap_loam_continuation_project(self.raw, index, &mut raw) },
			false,
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
		let code = unsafe { ffi::glowcap_loam_continuation_release(self.raw) };
		if let Err(error) = check(code, false) {
			self.owner.host.record_background_failure(error);
		}
	}
}
