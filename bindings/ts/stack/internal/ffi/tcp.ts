// Internal: the FFI mirror of `libpancake_net_transport_tcp` — the blocking-TCP
// transport archive (ADR-0059).
//
// Nothing here is public; `tcp.ts` is the ergonomic surface over it. This
// loader opens *only* the TCP archive, so importing `tcp.ts` never pulls in
// the inproc or iroh archives. The TCP family is symbol-disjoint from the core
// (it shares the frame/context types by layout, not by symbol), so it loads
// alongside `libpancake_ocapn` rather than instead of it, and carries its own
// thread-local last-error read through `pancake_tcp_last_error`.

import { libPath } from "./load.ts";
import { ffi } from "./runtime.ts";

const tcpS = ffi.dlopen(libPath("pancake_net_transport_tcp"), {
	pancake_tcp_last_error: { parameters: ["buffer", "usize"], result: "usize" },
	pancake_tcp_netlayer_new: { parameters: ["buffer"], result: "i32" },
	pancake_tcp_netlayer_release: { parameters: ["pointer"], result: "void" },
	pancake_tcp_connect: {
		parameters: ["pointer", "buffer", "usize", "u16", "u32", "usize", "buffer"],
		result: "i32",
	},
	pancake_tcp_listen: {
		parameters: ["pointer", "buffer", "usize", "u16", "buffer"],
		result: "i32",
	},
	pancake_tcp_listener_port: {
		parameters: ["pointer", "buffer"],
		result: "i32",
	},
	pancake_tcp_accept: {
		parameters: ["pointer", "u32", "usize", "buffer"],
		result: "i32",
	},
	pancake_tcp_conn_read_frame: {
		parameters: ["pointer", "buffer"],
		result: "i32",
	},
	pancake_tcp_conn_write_frame: {
		parameters: ["pointer", "buffer"],
		result: "i32",
	},
	pancake_tcp_conn_release: { parameters: ["pointer"], result: "void" },
	pancake_tcp_listener_release: { parameters: ["pointer"], result: "void" },
});

export { tcpS };
