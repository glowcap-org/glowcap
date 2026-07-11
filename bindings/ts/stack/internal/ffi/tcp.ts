// Internal: the FFI mirror of `libpancake_net_transport_tcp` — the blocking-TCP
// transport archive (ADR-0059).
//
// Nothing here is public; `tcp.ts` is the ergonomic surface over it. This
// loader opens *only* the TCP archive, so importing `tcp.ts` never pulls in
// the inproc or iroh archives. The TCP family is symbol-disjoint from the core
// (it shares the frame/context types by layout, not by symbol), so it loads
// alongside `libpancake_ocapn` rather than instead of it, and carries its own
// thread-local last-error read through `pancake_tcp_last_error`.
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
	U32 = "u32",
	U16 = "u16";

export const tcpS = ffi.dlopen(libPath("pancake_net_transport_tcp"), {
	pancake_tcp_last_error: { parameters: [B, U], result: U },
	pancake_tcp_netlayer_new: { parameters: [B], result: I },
	pancake_tcp_netlayer_release: { parameters: [P], result: V },
	pancake_tcp_connect: { parameters: [P, B, U, U16, U32, U, B], result: I },
	pancake_tcp_listen: { parameters: [P, B, U, U16, B], result: I },
	pancake_tcp_listener_port: { parameters: [P, B], result: I },
	pancake_tcp_accept: { parameters: [P, U32, U, B], result: I },
	pancake_tcp_conn_read_frame: { parameters: [P, B], result: I },
	pancake_tcp_conn_write_frame: { parameters: [P, B], result: I },
	pancake_tcp_conn_release: { parameters: [P], result: V },
	pancake_tcp_listener_release: { parameters: [P], result: V },
});
