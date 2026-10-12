//! Private receipt observation owns one Call result and independent projections.
use super::{AttachmentInner, Continuation, check, invalid};
use crate::{Argument, Error, Result, SendArena, sys::loam as ffi};
use std::rc::Rc;

pub struct EffectExecutionBounds {
	/// Owning reply, C observer metadata and bounded C result projections.
	pub caller_bytes: usize,
	/// Shared Host dispatch metadata. Queue, actors and registry are separate.
	pub host_dispatch_bytes: usize,
}
pub enum EffectResult {
	Pending,
	Ready(Argument),
	/// No target request crossed Host admission.
	Unsent(Error),
	/// Target admission occurred. The application receipt must resolve outcome.
	Unknown(Error),
}
pub struct EffectExecution {
	raw: *mut ffi::GlowcapLoamEffectExecution,
	owner: Rc<AttachmentInner>,
}
impl EffectExecution {
	pub(super) fn start(
		continuation: &Continuation,
		index: usize,
		verb: &str,
		args: &[Argument],
		reply_bytes: usize,
	) -> Result<Self> {
		let mut arena = SendArena::default();
		let (args, count) = arena.build(args)?;
		let mut raw = core::ptr::null_mut();
		check(
			// SAFETY: `continuation.raw` is the live `Continuation` handle from `PendingContinuation::try_take`,
			// released only by its `Drop`; `verb` borrows the caller's `&str`, and `args` and `count` come from the
			// local `arena`, which borrows `args` and outlives the call; the callee copies both into the Host queue
			// before returning, and `raw` is a local out-parameter the callee fills with an owned execution handle.
			unsafe {
				ffi::glowcap_loam_continuation_execute_copying(
					continuation.raw,
					index,
					verb.as_ptr(),
					verb.len(),
					args,
					count,
					reply_bytes,
					&mut raw,
				)
			},
			false,
		)?;
		Ok(Self {
			raw,
			owner: Rc::clone(&continuation.owner),
		})
	}
	/// Pure sizing of result ownership. Constructor input spines, Rust argument
	/// storage and application executor buffers have separate owners.
	pub fn result_size_bound(reply_bytes: usize) -> Result<EffectExecutionBounds> {
		// SAFETY: `GlowcapLoamEffectExecutionBounds` is a plain C struct of `usize` fields; all-zero is a valid value,
		// and the callee fills it before it is read.
		let mut raw = unsafe { core::mem::zeroed() };
		check(
			// SAFETY: `raw` is a local out-parameter the callee writes; `reply_bytes` is a plain integer and no pointer
			// is passed in.
			unsafe { ffi::glowcap_loam_effect_execution_result_size_bound(reply_bytes, &mut raw) },
			false,
		)?;
		Ok(EffectExecutionBounds {
			caller_bytes: raw.caller_bytes,
			host_dispatch_bytes: raw.host_dispatch_bytes,
		})
	}
	/// Every ready observation produces the usual owned Rust Argument and grants
	/// its own exact capability occurrences. C projection refusal preserves the
	/// original ready result for retry. It never redispatches the target.
	pub fn result(&mut self) -> Result<EffectResult> {
		// SAFETY: `GlowcapLoamEffectResult` is a plain C struct of integers and null pointers; all-zero is a valid
		// value, and the callee fills it before it is read.
		let mut raw = unsafe { core::mem::zeroed() };
		check(
			// SAFETY: `self.raw` is this `EffectExecution`'s handle from `glowcap_loam_continuation_execute_copying`,
			// released only by its `Drop`; `raw` is a local out-parameter the callee fills.
			unsafe { ffi::glowcap_loam_effect_execution_result(self.raw, &mut raw) },
			false,
		)?;
		match raw.state {
			0 => Ok(EffectResult::Pending),
			1 => {
				// SAFETY: `raw.value` was just filled by `glowcap_loam_effect_execution_result` on the live `self.raw`;
				// its spines and leaves stay borrowed until the next result query or release, neither of which runs
				// before `arg_from_sys` copies them into an owned `Argument`.
				let mut value = unsafe { crate::arg_from_sys(&raw.value) }?;
				crate::gc::track_owned_argument(&self.owner.host, &mut value);
				Ok(EffectResult::Ready(value))
			}
			2 | 3 => {
				let message = if raw.message_len == 0 {
					&[]
				} else {
					// SAFETY: `raw.message` and `raw.message_len` are the failure-text view
					// `glowcap_loam_effect_execution_result` just wrote, borrowed from `self.raw` until its release;
					// the length is nonzero here, and `from_utf8_lossy(..).into_owned()` copies the bytes before this
					// call returns.
					unsafe { core::slice::from_raw_parts(raw.message, raw.message_len) }
				};
				let failure = Error::with_detail(raw.result, String::from_utf8_lossy(message).into_owned());
				Ok(if raw.state == 2 {
					EffectResult::Unsent(failure)
				} else {
					EffectResult::Unknown(failure)
				})
			}
			_ => Err(invalid("unknown effect execution state")),
		}
	}
	/// Refusal preserves this observer for retry. A terminal target result takes
	/// precedence over an unrelated action-drain failure.
	pub async fn completed(&mut self) -> Result<EffectResult> {
		loop {
			let host = Rc::clone(&self.owner.host);
			let activity = host.close_activity();
			tokio::pin!(activity);
			activity.as_mut().enable();
			let result = self.result()?;
			if !matches!(result, EffectResult::Pending) {
				return Ok(result);
			}
			let progress = host.kick_actions().await;
			let result = self.result()?;
			if !matches!(result, EffectResult::Pending) {
				return Ok(result);
			}
			progress?;
			activity.await;
		}
	}
}
impl Drop for EffectExecution {
	fn drop(&mut self) {
		// SAFETY: `self.raw` is this `EffectExecution`'s handle from `glowcap_loam_continuation_execute_copying`;
		// `Drop` runs once, and a refusal parks the handle for a later release rather than reusing it.
		let code = unsafe { ffi::glowcap_loam_effect_execution_release(self.raw) };
		if let Err(error) = check(code, false) {
			if code != crate::sys::WOULD_BLOCK {
				self.owner.host.record_background_failure(error);
			}
			crate::finalizer::park_loam_effect_execution(Rc::clone(&self.owner), self.raw);
		}
	}
}
