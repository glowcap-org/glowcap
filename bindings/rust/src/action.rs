//! Host action park + execute: run `pancake_host_pump_drain` with sync
//! park-only hooks, then honor each parked arm (dial / flush / close /
//! gift-id / settle / fail). Decode/types and the exhaustive dispatch come
//! from the generated [`host_action_gen`](crate::host_action_gen) module
//! (`zig build gen-binding-host-action`). The CapTP [`Host`](crate::Host) and
//! vow table stay in `host.rs`; this module is the drain's park+execute half
//! that [`HostShared::kick_actions`](crate::host::HostShared::kick_actions)
//! drives. Async I/O never runs inside the C callback.

use std::rc::Rc;

use crate::dial::run_dial_ticket;
use crate::host::{check_host, HostShared};
use crate::host_action_gen::{self, HostAction, HostActionHandlers};
use crate::sys::host as ffi;
use crate::{sys, Error, Result};

/// Sync park arm for every `PancakeHostPumpHooks` slot: decode+append, set
/// progress, return. Views are copied inside [`host_action_gen::decode`]
/// before the next pop frees them.
unsafe extern "C" fn park_arm(
	ctx: *mut core::ffi::c_void,
	_host: *mut ffi::PancakeHost,
	action: *const ffi::PancakeHostAction,
	out_progressed: *mut u32,
) -> i32 {
	debug_assert!(!ctx.is_null());
	debug_assert!(!action.is_null());
	let action = unsafe { &*action };
	if !host_action_gen::is_known_kind(action.kind) {
		return sys::ERR_INTERNAL;
	}
	let parked = unsafe { &mut *(ctx as *mut Vec<HostAction>) };
	parked.push(host_action_gen::decode(action));
	if !out_progressed.is_null() {
		unsafe { *out_progressed = 1 };
	}
	sys::OK
}

/// Run `pancake_host_pump_drain` with park-only arms; return decoded actions
/// in queue order. The hooks struct and the parked vec stay alive for the
/// duration of the C call.
pub(crate) fn park(host: &HostShared) -> Result<(Vec<HostAction>, bool)> {
	let mut parked: Vec<HostAction> = Vec::new();
	let hooks = ffi::PancakeHostPumpHooks {
		ctx: &mut parked as *mut Vec<HostAction> as *mut core::ffi::c_void,
		flush: Some(park_arm),
		close: Some(park_arm),
		need_gift_id: Some(park_arm),
		complete: Some(park_arm),
		dial: Some(park_arm),
	};
	let mut acted: u32 = 0;
	let mut yielded: u32 = 0;
	check_host(unsafe { ffi::pancake_host_pump_drain(host.raw(), &hooks, &mut acted, &mut yielded) })?;
	Ok((parked, yielded != 0))
}

/// Per-arm I/O for the generated [`host_action_gen::dispatch`] inventory.
struct Handlers<'a> {
	host: &'a Rc<HostShared>,
}

/** A detached Host-progress task has no caller to return an error to. Settle
 * binding waiters so none park forever, then retain the exact first cause for
 * the next observable Host verb. */
fn retain_detached_failure(host: &HostShared, context: &str, error: Error) {
	let detail = format!("{context}: {error}");
	host.fail_pending_vows(error.code(), &detail);
	host.record_background_failure(error);
}

impl HostActionHandlers for Handlers<'_> {
	async fn dial(&self, action: HostAction) -> Result<()> {
		let HostAction::Dial { ticket } = action else {
			unreachable!("dispatch routes only Dial here");
		};
		if self.host.spawn_dial_task(ticket, move |host| async move {
			if let Err(error) = run_dial_ticket(&host, ticket).await {
				retain_detached_failure(&host, "dial terminal report failed", error);
				return;
			}
			// A reported dial outcome can advance close-relevant state even
			// when the drain below finds nothing queued, so the detached task
			// wakes the parked close drivers itself.
			host.note_close_activity();
			if !host.raw().is_null() {
				if let Err(error) = host.kick_actions().await {
					retain_detached_failure(&host, "action drain failed after dial completion", error);
				}
			}
		}) {
			return Ok(());
		}
		let reason = b"dial executor unavailable";
		check_host(unsafe { ffi::pancake_host_dial_failed(self.host.raw(), ticket, reason.as_ptr(), reason.len()) })
	}

	async fn flush(&self, action: HostAction) -> Result<()> {
		let HostAction::Flush { session } = action else {
			unreachable!("dispatch routes only Flush here");
		};
		let target = self.host.sessions.borrow().get(&session).cloned();
		match target {
			Some(session) => {
				if let Err(error) = crate::pump::flush_outbound(&session).await {
					session.record_wire_failure(error);
					session.close_transport();
				}
				// The serve result and pending vows carry this session-scoped
				// failure. It is handled here so an unrelated Host drain does not
				// report the same transport loss a second time.
				Ok(())
			}
			None => Ok(()),
		}
	}

	async fn close(&self, action: HostAction) -> Result<()> {
		let HostAction::Close { session, result } = action else {
			unreachable!("dispatch routes only Close here");
		};
		let target = self.host.sessions.borrow().get(&session).cloned();
		if let Some(session) = target {
			if let Err(error) = crate::pump::flush_outbound(&session).await {
				session.record_wire_failure(error);
			}
			session.record_close_result(result);
			session.close_transport();
		}
		Ok(())
	}

	async fn need_gift_id(&self, action: HostAction) -> Result<()> {
		let HostAction::NeedGiftId { ticket } = action else {
			unreachable!("dispatch routes only NeedGiftId here");
		};
		let mut gift_id = [0u8; 32];
		let provided = getrandom::fill(&mut gift_id).is_ok()
			&& check_host(unsafe {
				ffi::pancake_host_provide_gift_id(self.host.raw(), ticket, gift_id.as_ptr(), gift_id.len())
			})
			.is_ok();
		if provided {
			return Ok(());
		}
		check_host(unsafe { ffi::pancake_host_gift_id_failed(self.host.raw(), ticket) })
	}

	async fn settle(&self, action: HostAction) -> Result<()> {
		let HostAction::Settle { ticket, value } = action else {
			unreachable!("dispatch routes only Settle here");
		};
		self.host.settle_vow(ticket, Ok(value));
		Ok(())
	}

	async fn fail(&self, action: HostAction) -> Result<()> {
		let HostAction::Fail {
			ticket,
			result,
			message,
		} = action
		else {
			unreachable!("dispatch routes only Fail here");
		};
		self.host.settle_vow(ticket, Err(Error::with_detail(result, message)));
		Ok(())
	}

	async fn resume(&self, action: HostAction) -> Result<()> {
		let HostAction::Resume = action else {
			unreachable!("dispatch routes only Resume here");
		};
		Ok(())
	}

	async fn cancel_dial(&self, action: HostAction) -> Result<()> {
		let HostAction::CancelDial { ticket } = action else {
			unreachable!("dispatch routes only CancelDial here");
		};
		self.host.cancel_dial_task(ticket).await
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn unknown_native_action_kind_is_a_returned_callback_failure() {
		let mut parked = Vec::new();
		let mut action: ffi::PancakeHostAction = unsafe { core::mem::zeroed() };
		action.kind = u32::MAX;
		let rc = unsafe {
			park_arm(
				&mut parked as *mut Vec<HostAction> as *mut core::ffi::c_void,
				core::ptr::null_mut(),
				&action,
				core::ptr::null_mut(),
			)
		};
		assert_eq!(rc, sys::ERR_INTERNAL);
		assert!(parked.is_empty());
	}

	#[test]
	fn detached_failure_retains_the_exact_first_cause() {
		let owner = crate::Host::new_host();
		let host = owner.shared();
		let first = Error::with_detail(sys::ERR_IO, "terminal report refused".to_string());
		let later = Error::with_detail(sys::ERR_INTERNAL, "follow-up drain refused".to_string());

		retain_detached_failure(&host, "dial terminal report failed", first.clone());
		retain_detached_failure(&host, "action drain failed after dial completion", later.clone());

		assert_eq!(host.take_background_failure(), Some(first.with_secondary(later)));
		assert_eq!(host.take_background_failure(), None);
	}
}

/// The executor is deliberately dumb: every decision was already made in the
/// core; each arm is pure I/O or marshalling. The kind inventory lives in
/// generated [`host_action_gen::dispatch`] — a new kind fails compile.
pub(crate) async fn run(host: &Rc<HostShared>, action: HostAction) -> Result<()> {
	host_action_gen::dispatch(action, &Handlers { host }).await
}
