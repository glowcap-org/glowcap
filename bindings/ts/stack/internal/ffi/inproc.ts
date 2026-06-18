// Internal: the FFI mirror of `libpancake_net_transport_inproc` — the
// in-process transport archive (ADR-0059).
//
// Nothing here is public; `inproc.ts` is the ergonomic surface over it. This
// loader opens *only* the inproc archive, so importing `inproc.ts` never pulls
// in the TCP or iroh archives. The inproc family is symbol-disjoint from the
// core and shares the frame/context types by layout; it carries its own
// thread-local last-error read through `pancake_inproc_last_error`.

import { libPath } from "./load.ts";
import { ffi } from "./runtime.ts";

const inprocS = ffi.dlopen(libPath("pancake_net_transport_inproc"), {
	pancake_inproc_last_error: {
		parameters: ["buffer", "usize"],
		result: "usize",
	},
	pancake_inproc_clear_last_error: { parameters: [], result: "void" },
	pancake_inproc_netlayer_new: { parameters: ["buffer"], result: "i32" },
	pancake_inproc_netlayer_new_in: {
		parameters: ["pointer", "buffer"],
		result: "i32",
	},
	pancake_inproc_netlayer_release: { parameters: ["pointer"], result: "void" },
	pancake_inproc_connect: {
		parameters: ["pointer", "buffer", "usize", "u32", "usize", "buffer"],
		result: "i32",
	},
	pancake_inproc_listen: {
		parameters: ["pointer", "buffer", "usize", "buffer"],
		result: "i32",
	},
	pancake_inproc_accept: {
		parameters: ["pointer", "u32", "usize", "buffer"],
		result: "i32",
	},
	pancake_inproc_conn_read_frame: {
		parameters: ["pointer", "buffer"],
		result: "i32",
	},
	pancake_inproc_conn_write_frame: {
		parameters: ["pointer", "buffer"],
		result: "i32",
	},
	pancake_inproc_conn_release: { parameters: ["pointer"], result: "void" },
	pancake_inproc_listener_release: { parameters: ["pointer"], result: "void" },
});

export { inprocS };
