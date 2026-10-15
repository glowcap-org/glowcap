//! Host action park + execute: run `glowcap_host_pump_drain` with sync
//! park-only hooks, then honor each parked arm (dial / flush / close /
//! gift-id / settle / fail). Decode/types and the exhaustive dispatch come
//! from the generated [`host_action_gen`](crate::host_action_gen) module
//! (`zig build gen-binding-host-action`). The CapTP [`Host`](crate::Host) facade
//! and its vow table live in `host/public.rs` and `host/vows.rs`. This module is
//! the drain's park+execute half
//! that [`HostShared::kick_actions`](crate::host::HostShared::kick_actions)
//! drives. Async I/O never runs inside the C callback.

use std::rc::Rc;

use crate::dial::run_dial_ticket;
use crate::host::{HostShared, check_host};
use crate::host_action_gen::{self, HostAction, HostActionHandlers};
use crate::sys::host as ffi;
use crate::{Error, Result, sys};

/// Sync park arm for every `GlowcapHostPumpHooks` slot: decode+append, set
/// progress, return. Views are copied inside [`host_action_gen::decode`]
/// before the next pop frees them.
unsafe extern "C" fn park_arm(
	ctx: *mut core::ffi::c_void,
	_host: *mut ffi::GlowcapHost,
	action: *const ffi::GlowcapHostAction,
	out_progressed: *mut u32,
) -> i32 {
	if ctx.is_null() || action.is_null() {
		return sys::ERR_NULL_POINTER;
	}
	// SAFETY: `action` is non-null (checked above) and points to the `GlowcapHostAction` the C side passed to this arm,
	// whose views stay host-owned until the next pop, after this callback has returned.
	let action = unsafe { &*action };
	let action = match host_action_gen::decode(action) {
		Ok(action) => action,
		Err(error) => return error.code(),
	};
	// SAFETY: `ctx` is non-null (checked above) and is the `&mut Vec<HostAction>` that `park` put in the hooks struct,
	// live for the whole `glowcap_host_pump_drain` call; the pump invokes the arms one at a time, so this is the only
	// reference to it.
	let parked = unsafe { &mut *(ctx as *mut Vec<HostAction>) };
	parked.push(action);
	if !out_progressed.is_null() {
		// SAFETY: `out_progressed` is non-null (checked just above) and points to a `u32` the C side gave this callback
		// for the arm to write.
		unsafe { *out_progressed = 1 };
	}
	sys::OK
}

/// Run `glowcap_host_pump_drain` with park-only arms. Return decoded actions
/// in queue order. The hooks struct and the parked vec stay alive for the
/// duration of the C call.
pub(crate) fn park(host: &HostShared) -> Result<(Vec<HostAction>, bool)> {
	let mut parked: Vec<HostAction> = Vec::new();
	let hooks = ffi::GlowcapHostPumpHooks {
		ctx: &mut parked as *mut Vec<HostAction> as *mut core::ffi::c_void,
		flush: Some(park_arm),
		close: Some(park_arm),
		need_gift_id: Some(park_arm),
		complete: Some(park_arm),
		dial: Some(park_arm),
	};
	let mut acted: u32 = 0;
	let mut yielded: u32 = 0;
	// SAFETY: `host.raw()` is the `GlowcapHost` handle `HostShared` owns from `glowcap_host_new_in`, released only by
	// its teardown, and the `&HostShared` borrow keeps it for the call; `hooks` is a local `GlowcapHostPumpHooks` whose
	// `ctx` is `parked`, and `acted` and `yielded` are local out-parameters the callee writes, all live for the call.
	check_host(unsafe { ffi::glowcap_host_pump_drain(host.raw(), &hooks, &mut acted, &mut yielded) })?;
	Ok((parked, yielded != 0))
}

/// Per-arm I/O for the generated [`host_action_gen::dispatch`] inventory.
struct Handlers<'a> {
	host: &'a Rc<HostShared>,
}

fn answer_gift_id<E>(
	draw: impl FnOnce() -> core::result::Result<[u8; 32], E>,
	provide: impl FnOnce(&[u8; 32]) -> Result<()>,
	failed: impl FnOnce() -> Result<()>,
) -> Result<()> {
	match draw() {
		Ok(gift_id) => provide(&gift_id),
		Err(_) => failed(),
	}
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
	async fn dial(&self, ticket: u64, route_index: usize) -> Result<()> {
		let spawned = self.host.spawn_dial_task(ticket, route_index, move |host| async move {
			if let Err(error) = run_dial_ticket(&host, ticket, route_index).await {
				retain_detached_failure(&host, "dial terminal report failed", error);
				return;
			}
			// A reported dial outcome can advance close-relevant state even
			// when the drain below finds nothing queued, so the detached task
			// wakes the parked close drivers itself.
			host.note_close_activity();
			if !host.raw().is_null()
				&& let Err(error) = host.kick_actions().await
			{
				retain_detached_failure(&host, "action drain failed after dial completion", error);
			}
		});
		match spawned {
			Ok(true) => Ok(()),
			Ok(false) => {
				let reason = b"dial executor unavailable";
				// SAFETY: `self.host.raw()` is the `GlowcapHost` handle `HostShared` owns from `glowcap_host_new_in`,
				// released only by its teardown, and the `&Rc<HostShared>` borrow keeps it for the call; `reason` is a
				// `'static` byte string whose pointer and length stay live for the call.
				check_host(unsafe {
					ffi::glowcap_host_dial_failed(self.host.raw(), ticket, route_index, reason.as_ptr(), reason.len())
				})
			}
			Err(primary) => {
				let reason = primary.to_string();
				// SAFETY: `self.host.raw()` is the `GlowcapHost` handle `HostShared` owns from `glowcap_host_new_in`,
				// released only by its teardown, and the `&Rc<HostShared>` borrow keeps it for the call; `reason` is a
				// local `String` whose pointer and length stay live for the call.
				let report = check_host(unsafe {
					ffi::glowcap_host_dial_failed(self.host.raw(), ticket, route_index, reason.as_ptr(), reason.len())
				});
				match report {
					Ok(()) => Ok(()),
					Err(cleanup) => Err(primary.with_secondary(cleanup)),
				}
			}
		}
	}

	async fn flush(&self, session: usize) -> Result<()> {
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

	async fn close(&self, session: usize, result: i32) -> Result<()> {
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

	async fn need_gift_id(&self, ticket: u64) -> Result<()> {
		answer_gift_id(
			|| {
				let mut gift_id = [0u8; 32];
				getrandom::fill(&mut gift_id).map(|()| gift_id)
			},
			|gift_id| {
				// SAFETY: `self.host.raw()` is the `GlowcapHost` handle `HostShared` owns from `glowcap_host_new_in`,
				// released only by its teardown, and the `&Rc<HostShared>` borrow keeps it for the call; `gift_id` is
				// the `[u8; 32]` borrowed by the closure, whose pointer and length stay live for the call.
				check_host(unsafe {
					ffi::glowcap_host_provide_gift_id(self.host.raw(), ticket, gift_id.as_ptr(), gift_id.len())
				})
			},
			// SAFETY: `self.host.raw()` is the `GlowcapHost` handle `HostShared` owns from `glowcap_host_new_in`,
			// released only by its teardown, and the `&Rc<HostShared>` borrow keeps it for the call; `ticket` is a
			// plain integer argument.
			|| check_host(unsafe { ffi::glowcap_host_gift_id_failed(self.host.raw(), ticket) }),
		)
	}

	async fn settle(&self, ticket: u64, value: crate::Argument) -> Result<()> {
		self.host.settle_vow(ticket, Ok(value));
		Ok(())
	}

	async fn fail(&self, ticket: u64, result: i32, message: String) -> Result<()> {
		self.host.settle_vow(ticket, Err(Error::with_detail(result, message)));
		Ok(())
	}

	async fn resume(&self) -> Result<()> {
		Ok(())
	}

	async fn cancel_dial(&self, ticket: u64, route_index: usize) -> Result<()> {
		self.host.cancel_dial_task(ticket, route_index).await
	}
}

/// The executor is dumb: every decision was already made in the
/// core. Each arm is pure I/O or marshalling. The kind inventory lives in
/// generated [`host_action_gen::dispatch`]: a new kind fails compile.
pub(crate) async fn run(host: &Rc<HostShared>, action: HostAction) -> Result<()> {
	host_action_gen::dispatch(action, &Handlers { host }).await
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn gift_id_completion_does_not_reclassify_provide_refusal() {
		let mut failed = 0;
		let observed = answer_gift_id(
			|| Ok::<_, ()>([0u8; 32]),
			|_| {
				Err(Error::with_detail(
					sys::ERR_INVALID_ARGUMENT,
					"ticket refused".to_string(),
				))
			},
			|| {
				failed += 1;
				Ok(())
			},
		)
		.expect_err("provide refusal must remain exact");
		assert_eq!(observed.code(), sys::ERR_INVALID_ARGUMENT);
		assert_eq!(failed, 0);

		answer_gift_id(
			|| Err::<[u8; 32], _>(()),
			|_| panic!("entropy failure reached provide"),
			|| {
				failed += 1;
				Ok(())
			},
		)
		.expect("entropy failure report");
		assert_eq!(failed, 1);
	}

	#[test]
	fn unknown_ffi_action_kind_is_a_returned_callback_failure() {
		let mut parked = Vec::new();
		// SAFETY: `GlowcapHostAction` is a plain C struct of integers, null pointers, and nested plain C structs;
		// all-zero is a valid value, and this test sets the discriminant fields it exercises before the arm reads them.
		let mut action: ffi::GlowcapHostAction = unsafe { core::mem::zeroed() };
		action.kind = u32::MAX;
		let error = host_action_gen::decode(&action)
			.err()
			.expect("generated decoder must reject an unknown ABI discriminant");
		assert_eq!(error.code(), sys::ERR_INTERNAL);
		assert!(error.message().unwrap_or_default().contains("unknown host action kind"));
		// SAFETY: `park_arm` is called directly: `ctx` is the `&mut Vec<HostAction>` of the local `parked`, `action`
		// borrows the local `action`, and the null host and null `out_progressed` are the shapes the arm ignores or
		// checks for.
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
	fn unknown_nested_argument_kind_is_a_returned_callback_failure() {
		let mut parked = Vec::new();
		// SAFETY: `GlowcapHostAction` is a plain C struct of integers, null pointers, and nested plain C structs;
		// all-zero is a valid value, and this test sets the discriminant fields it exercises before the arm reads them.
		let mut action: ffi::GlowcapHostAction = unsafe { core::mem::zeroed() };
		action.kind = host_action_gen::HOST_ACTION_SETTLE;
		action.value.kind = u32::MAX;
		let error = host_action_gen::decode(&action)
			.err()
			.expect("generated decoder must reject an unknown nested argument kind");
		assert_eq!(error.code(), sys::ERR_INTERNAL);
		assert!(error.message().unwrap_or_default().contains("unknown argument kind"));
		// SAFETY: `park_arm` is called directly: `ctx` is the `&mut Vec<HostAction>` of the local `parked`, `action`
		// borrows the local `action`, and the null host and null `out_progressed` are the shapes the arm ignores or
		// checks for.
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
