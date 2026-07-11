// Internal: the FFI mirror of `libpancake_net_transport_inproc` — the
// in-process transport archive (ADR-0059).
//
// Nothing here is public; `inproc.ts` is the ergonomic surface over it. This
// loader opens *only* the inproc archive, so importing `inproc.ts` never pulls
// in the TCP or iroh archives. The inproc family is symbol-disjoint from the
// core and shares the frame/context types by layout; it carries its own
// thread-local last-error read through `pancake_inproc_last_error`.
//
// The one-letter type shorthands mirror `ocapn.ts`; every `internal/ffi` loader
// opens with the same header so a symbol's signature reads on one line.

import { libPath } from "./load.ts";
import { ffi } from "./runtime.ts";

const P = "pointer",
	B = "buffer",
	U = "usize",
	I = "i32",
	V = "void",
	U32 = "u32";

export const inprocS = ffi.dlopen(libPath("pancake_net_transport_inproc"), {
	pancake_inproc_last_error: { parameters: [B, U], result: U },
	pancake_inproc_netlayer_new: { parameters: [B], result: I },
	pancake_inproc_netlayer_release: { parameters: [P], result: V },
	pancake_inproc_connect: { parameters: [P, B, U, U32, U, B], result: I },
	pancake_inproc_listen: { parameters: [P, B, U, B], result: I },
	pancake_inproc_accept: { parameters: [P, U32, U, B], result: I },
	pancake_inproc_conn_read_frame: { parameters: [P, B], result: I },
	pancake_inproc_conn_write_frame: { parameters: [P, B], result: I },
	pancake_inproc_conn_release: { parameters: [P], result: V },
	pancake_inproc_listener_release: { parameters: [P], result: V },
});
