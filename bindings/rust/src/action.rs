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
	let parked = unsafe { &mut *(ctx as *mut Vec<HostAction>) };
	parked.push(host_action_gen::decode(unsafe { &*action }));
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
	check_host(unsafe {
		ffi::pancake_host_pump_drain(host.raw(), &hooks, &mut acted, &mut yielded)
	})?;
	Ok((parked, yielded != 0))
}

/// Per-arm I/O for the generated [`host_action_gen::dispatch`] inventory.
struct Handlers<'a> {
	host: &'a Rc<HostShared>,
}

impl HostActionHandlers for Handlers<'_> {
	async fn dial(&self, action: HostAction) -> Result<()> {
		let HostAction::Dial { ticket } = action else {
			unreachable!("dispatch routes only Dial here");
		};
		if self.host.spawn_dial_task(move |host| async move {
			let _ = run_dial_ticket(&host, ticket).await;
			if !host.closing() {
				host.kick_actions().await;
			}
		}) {
			return Ok(());
		}
		let reason = b"dial executor unavailable";
		check_host(unsafe {
			ffi::pancake_host_dial_failed(self.host.raw(), ticket, reason.as_ptr(), reason.len())
		})
	}

	async fn flush(&self, action: HostAction) -> Result<()> {
		let HostAction::Flush { session } = action else {
			unreachable!("dispatch routes only Flush here");
		};
		let target = self.host.sessions.borrow().get(&session).cloned();
		match target {
			Some(session) => {
				let result = crate::pump::flush_outbound(&session).await;
				if result.is_err() {
					session.close_transport();
				}
				result
			}
			None => Ok(()),
		}
	}

	async fn close(&self, action: HostAction) -> Result<()> {
		let HostAction::Close { session } = action else {
			unreachable!("dispatch routes only Close here");
		};
		let target = self.host.sessions.borrow().get(&session).cloned();
		if let Some(session) = target {
			let _ = crate::pump::flush_outbound(&session).await;
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
				ffi::pancake_host_provide_gift_id(
					self.host.raw(),
					ticket,
					gift_id.as_ptr(),
					gift_id.len(),
				)
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
		let HostAction::Fail { ticket, message } = action else {
			unreachable!("dispatch routes only Fail here");
		};
		let err = if self.host.vow_session_closing(ticket) {
			Error::with_detail(sys::ERR_CLOSED, message)
		} else {
			Error::broken(message)
		};
		self.host.settle_vow(ticket, Err(err));
		Ok(())
	}

	async fn resume(&self, action: HostAction) -> Result<()> {
		let HostAction::Resume = action else {
			unreachable!("dispatch routes only Resume here");
		};
		Ok(())
	}
}

/// The executor is deliberately dumb: every decision was already made in the
/// core; each arm is pure I/O or marshalling. The kind inventory lives in
/// generated [`host_action_gen::dispatch`] — a new kind fails compile.
pub(crate) async fn run(host: &Rc<HostShared>, action: HostAction) -> Result<()> {
	host.guard_open()?;
	host_action_gen::dispatch(action, &Handlers { host }).await
}
