//! Endpoint labels follow application identity without replacing the trace sink.
use super::{STATE, ffi, on_native_event};
use std::ffi::c_void;

/// Change the current producer's display label and replay active session opens.
/// Identity, the installed sink and its clock remain unchanged. Withdrawal uses
/// `None`. When tracing is disabled there is no label state or replay work.
pub fn set_trace_label(label: Option<&str>) {
	let hosts = STATE.with(|state| {
		let mut state = state.borrow_mut();
		if state.sink.is_none() || state.self_label.as_deref() == label {
			return Vec::new();
		}
		state.self_label = label.map(str::to_owned);
		state
			.hosts
			.iter()
			.map(|host| (host.raw, host.cookie))
			.collect::<Vec<_>>()
	});
	// Reinstalling the same tap asks the core to describe its active sessions.
	// Release binding state before callbacks can reach the application sink.
	for (raw, cookie) in hosts {
		// SAFETY: `raw` is a Host handle `attach_host` registered, still live because `detach_host` has not run since
		// the snapshot above (nothing between them can release a Host); `on_native_event` matches the callback
		// signature, and `cookie` is an integer ctx the callback never dereferences.
		unsafe { ffi::glowcap_host_set_trace(raw, Some(on_native_event), cookie as *mut c_void) };
	}
}
