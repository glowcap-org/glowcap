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
pub(crate) fn park(host: &HostShared) -> Vec<HostAction> {
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
	let _ = check_host(unsafe { ffi::pancake_host_pump_drain(host.raw(), &hooks, &mut acted) });
	parked
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
		run_dial_ticket(self.host, ticket).await
	}

	async fn flush(&self, action: HostAction) -> Result<()> {
		let HostAction::Flush { conn } = action else {
			unreachable!("dispatch routes only Flush here");
		};
		let target = self.host.sessions.borrow().get(&conn).cloned();
		match target {
			Some(conn) => crate::pump::flush_outbound(&conn).await,
			None => Ok(()),
		}
	}

	async fn close(&self, action: HostAction) -> Result<()> {
		let HostAction::Close { conn } = action else {
			unreachable!("dispatch routes only Close here");
		};
		let target = self.host.sessions.borrow().get(&conn).cloned();
		if let Some(conn) = target {
			let _ = crate::pump::flush_outbound(&conn).await;
			conn.close_transport();
		}
		Ok(())
	}

	async fn need_gift_id(&self, action: HostAction) -> Result<()> {
		let HostAction::NeedGiftId { ticket } = action else {
			unreachable!("dispatch routes only NeedGiftId here");
		};
		let mut gift_id = [0u8; 32];
		getrandom::fill(&mut gift_id).expect("the OS RNG provides gift-id entropy");
		check_host(unsafe {
			ffi::pancake_host_provide_gift_id(
				self.host.raw(),
				ticket,
				gift_id.as_ptr(),
				gift_id.len(),
			)
		})
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
}

/// The executor is deliberately dumb: every decision was already made in the
/// core; each arm is pure I/O or marshalling. The kind inventory lives in
/// generated [`host_action_gen::dispatch`] — a seventh kind fails compile.
pub(crate) async fn run(host: &Rc<HostShared>, action: HostAction) -> Result<()> {
	host.guard_open()?;
	host_action_gen::dispatch(action, &Handlers { host }).await
}
