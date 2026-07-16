//! Host action park + execute: run `pancake_host_pump_drain` with sync
//! park-only hooks, then honor each parked arm (dial / flush / close /
//! gift-id / settle / fail). Decode/types come from the generated
//! [`host_action_gen`](crate::host_action_gen) module
//! (`zig build gen-binding-host-action`). The CapTP [`Host`](crate::Host) and
//! vow table stay in `host.rs`; this module is the drain's park+execute half
//! that [`HostShared::kick_actions`](crate::host::HostShared::kick_actions)
//! drives. Async I/O never runs inside the C callback.

use std::rc::Rc;

use crate::dial::dial_exporter;
use crate::host::{check_host, try_spawn_local, HostShared};
use crate::host_action_gen::{self, HostAction};
use crate::sys::driver as ffi;
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

/// The executor is deliberately dumb: every decision was already made in the
/// core; each arm is pure I/O or marshalling. Exhaustive on the generated
/// `HostAction` enum — a seventh kind fails compile.
pub(crate) async fn run(host: &Rc<HostShared>, action: HostAction) -> Result<()> {
	match action {
		HostAction::Dial {
			ticket,
			transport,
			designator,
			direct_addresses_hint,
		} => {
			// Boxed to break the async recursion cycle: the dial's establish
			// runs its own reentrant drain (its start-session FLUSH), which
			// is this very function.
			let dialed = Box::pin(dial_exporter(
				&transport,
				&designator,
				&direct_addresses_hint,
				Rc::clone(host),
			))
			.await;
			match dialed {
				Ok(conn) => {
					conn.mark_host_dialed();
					let raw_conn = conn.raw_conn();
					// Keep the exporter connection pumped: the withdraw's
					// resolution — and any later routed traffic — rides it
					// immediately. The task owns the wrapper so the exporter
					// lives until its own transport ends.
					let serving = conn.serve();
					try_spawn_local(async move {
						serving.await;
						drop(conn);
					});
					check_host(unsafe { ffi::pancake_host_dialed(host.raw(), ticket, raw_conn) })
				}
				Err(error) => {
					// The host turns a failed dial into broken redeems.
					let reason = error.to_string();
					check_host(unsafe {
						ffi::pancake_host_dial_failed(
							host.raw(),
							ticket,
							reason.as_ptr(),
							reason.len(),
						)
					})
				}
			}
		}
		HostAction::Flush { conn } => {
			let target = host.sessions.borrow().get(&conn).cloned();
			match target {
				Some(conn) => conn.flush_outbound().await,
				None => Ok(()),
			}
		}
		HostAction::Close { conn } => {
			// The host condemned the connection mid-pump (local turn
			// budget exceeded): write its queued resource_exhausted abort
			// best-effort, then close the transport and release the conn
			// shell.
			let target = host.sessions.borrow().get(&conn).cloned();
			if let Some(conn) = target {
				let _ = conn.flush_outbound().await;
				conn.close_transport();
			}
			Ok(())
		}
		HostAction::NeedGiftId { ticket } => {
			// Entropy is a host effect, drawn only when a reply actually
			// becomes a gift. The OS RNG failing is not a recoverable
			// condition, the same stance the host constructor takes.
			let mut gift_id = [0u8; 32];
			getrandom::fill(&mut gift_id).expect("the OS RNG provides gift-id entropy");
			check_host(unsafe {
				ffi::pancake_host_provide_gift_id(
					host.raw(),
					ticket,
					gift_id.as_ptr(),
					gift_id.len(),
				)
			})
		}
		HostAction::Settle { ticket, value } => {
			host.settle_vow(ticket, Ok(value));
			Ok(())
		}
		HostAction::Fail { ticket, message } => {
			// Every break — a partner refusal and a disconnect's own break
			// alike — surfaces as the typed Broken carrying the reason, the
			// classification the pre-host surface promised its consumers
			// (the TS/Python siblings type a closing connection's break
			// Closed instead; the divergence is deliberate, not drift).
			host.settle_vow(ticket, Err(Error::broken(message)));
			Ok(())
		}
	}
}
