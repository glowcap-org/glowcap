// Internal: the FFI mirror of `libpancake_driver` — the byte-fed host archive
// (ADR-0072), the sibling of the Racket binding's `ffi-driver.rkt`.
//
// Nothing here is public. The archive is a companion of libpancake_ocapn: it
// exports only the `pancake_host_*` family and shares the frame, argument,
// reference, and last-abort layouts by layout, so this loader opens ONLY
// libpancake_driver and declares no core symbol. The host surface over it
// spans `../../host.ts`, `../../session.ts`, `../../action.ts`, and
// `../../pump.ts`.
//
// Callback discipline: the ONE native callback in the whole binding — the
// shared behavior trampoline (`../../trampoline.ts`) — fires synchronously on
// the thread executing the enclosing `pancake_host_*` call. Deno and Bun both
// register callbacks globally, so it is minted through the runtime FFI's
// `makeCallback`, callable from any loaded archive. Settlements carry no
// callback at all: they ride the action queue as SETTLE/FAIL and the drain
// routes them by vow id (`../../action.ts` + `../../promise.ts`).
//
// `fetch`/`enliven`/`send` and the `vow_*` verbs each mint a host vow whose id
// lands in the trailing out-buffer; the outcome arrives as that vow's
// SETTLE/FAIL action. The `free` parameter of publish/spawn is always NULL
// from this binding: the JS side owns its behavior entries in the trampoline
// registry, so there is nothing for the library to free.

import { libPath } from "./load.ts";
import { ffi } from "./runtime.ts";

const P = "pointer",
	B = "buffer",
	U = "usize",
	I = "i32",
	V = "void",
	U64 = "u64";

export const driverS = ffi.dlopen(libPath("pancake_driver"), {
	// Lifecycle.
	pancake_host_new: { parameters: [B, U, U, "u32", "u32", "u32", B], result: I },
	pancake_host_new_in: { parameters: [P, B, U, U, "u32", "u32", "u32", B], result: I },
	pancake_host_release: { parameters: [P], result: V },
	pancake_host_designator_from_seed: { parameters: [B, U, B, U], result: I },
	pancake_host_set_self_designator: { parameters: [P, B, U], result: I },
	pancake_host_session_open_dialed_locator: { parameters: [P, B, U, B, U, B], result: I },
	// Resolve a dial to a PancakeDialPlan (grammar + hint + iroh posture); a free function.
	pancake_host_plan_dial: { parameters: [B, U, B, U, B, U, "u32", "u32", B], result: I },
	pancake_host_session_open_accepted: { parameters: [P, B, U, B, U, B, U, B], result: I },
	pancake_host_session_release: { parameters: [P], result: V },
	pancake_host_session_session_open: { parameters: [P], result: I },
	// The byte pump and action queue.
	pancake_host_session_feed_bytes: { parameters: [P, B, U, B], result: I },
	pancake_host_session_take_outbound: { parameters: [P, B], result: I },
	pancake_host_next_action: { parameters: [P, B], result: I },
	pancake_host_dialed: { parameters: [P, U64, P], result: I },
	pancake_host_dial_failed: { parameters: [P, U64, B, U], result: I },
	pancake_host_provide_gift_id: { parameters: [P, U64, B, U], result: I },
	// Publish and spawn (behavior = the trampoline pointer, ctx = the JS
	// registry id packed as a pointer-sized integer, free = NULL).
	pancake_host_session_publish: { parameters: [P, B, U, P, P, P, B], result: I },
	pancake_host_session_spawn: { parameters: [P, P, P, P, B], result: I },
	pancake_host_publish: { parameters: [P, B, U, P, P, P], result: I },
	// Fetch and enliven — each mints a host vow (out param).
	pancake_host_session_fetch: { parameters: [P, B, U, B], result: I },
	pancake_host_session_enliven: { parameters: [P, B, U, B], result: I },
	// Send, tell, vows, projections.
	pancake_host_session_send: { parameters: [P, B, B, U, B, U, B], result: I },
	pancake_host_session_tell: { parameters: [P, B, B, U, B, U], result: I },
	pancake_host_vow_send: { parameters: [P, U64, B, U, B, U, B], result: I },
	pancake_host_vow_index: { parameters: [P, U64, U64, B], result: I },
	pancake_host_vow_untag: { parameters: [P, U64, B, U, B], result: I },
	// Turn verbs (legal only inside a behavior callback). `turn_forward`'s
	// out-reply is the raw pointer the trampoline was handed, so it crosses as
	// a pointer, not a JS buffer.
	pancake_host_turn_forward: { parameters: [P, B, B, U, B, U, P], result: I },
	pancake_host_turn_spawn: { parameters: [P, P, P, P, B], result: I },
	pancake_host_turn_break: { parameters: [P, B, U], result: I },
	// GC, teardown, diagnostics.
	pancake_host_gc_release: { parameters: [P, U64, U64], result: I },
	pancake_host_session_break_far_vows: { parameters: [P, B, U], result: I },
	pancake_host_session_set_exporter_location: { parameters: [P, B, U], result: I },
	pancake_host_session_last_abort: { parameters: [P, B], result: I },
	pancake_host_last_error: { parameters: [B, U], result: U },
});
