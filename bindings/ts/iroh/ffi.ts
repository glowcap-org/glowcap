// Internal: the FFI mirror of `libpancake_net_transport_iroh`'s C ABI.
//
// The iroh companion library (`libpancake_net_transport_iroh`, ADR-0055) is
// optional — absent unless built with cargo — so it loads lazily on first use
// through `irohS()`, which names how to produce it rather than surfacing a raw
// dlopen failure. This loader opens *only* the iroh archive, through the core's
// shared FFI runtime (`@pancake/stack/ffi`). Nothing here is public; `mod.ts` is
// the ergonomic surface over it.

import { ffi, libFile, libPath, type Symbols } from "@pancake/stack/ffi";

const irohSymbolDefs = {
	pancake_iroh_last_error: { parameters: ["buffer", "usize"], result: "usize" },
	pancake_iroh_netlayer_new: {
		parameters: ["buffer", "usize", "u32", "buffer"],
		result: "i32",
	},
	pancake_iroh_netlayer_close: { parameters: ["pointer"], result: "void" },
	pancake_iroh_netlayer_release: { parameters: ["pointer"], result: "void" },
	pancake_iroh_netlayer_node_id: {
		parameters: ["pointer", "buffer", "usize", "buffer"],
		result: "i32",
	},
	pancake_iroh_netlayer_direct_addrs: {
		parameters: ["pointer", "buffer", "usize", "buffer"],
		result: "i32",
	},
	pancake_iroh_conn_release: { parameters: ["pointer"], result: "void" },
	// The event-driven loop surface (ADR-0057): the netlayer's one I/O model.
	// `readiness_fd` hands back the endpoint's single OS readiness fd, which the
	// event loop parks on (a `node:net` Socket over a dup of it); `drain_ready` and
	// the `try_*` calls return immediately, so they run synchronously on the
	// event-loop thread. Their `intptr_t` results stay within int32 (event counts,
	// byte counts up to a frame, and the small negative PANCAKE_ERR_* codes), so
	// `i32` reads them without truncation. `try_connect` blocks on the dial, so it
	// is the one non-blocking-FFI call.
	pancake_iroh_netlayer_readiness_fd: {
		parameters: ["pointer"],
		result: "i32",
	},
	pancake_iroh_netlayer_drain_ready: {
		parameters: ["pointer", "buffer", "usize"],
		result: "i32",
	},
	pancake_iroh_netlayer_try_accept: {
		parameters: ["pointer", "buffer"],
		result: "i32",
	},
	pancake_iroh_netlayer_try_connect: {
		parameters: ["pointer", "buffer", "usize", "buffer", "usize", "buffer"],
		result: "i32",
		nonblocking: true,
	},
	pancake_iroh_conn_try_read: {
		parameters: ["pointer", "buffer", "usize"],
		result: "i32",
	},
	pancake_iroh_conn_try_write: {
		parameters: ["pointer", "buffer", "usize"],
		result: "i32",
	},
} as const;

let irohSyms: Symbols | null = null;

// Open the iroh ABI library on first use. It is optional — absent unless built
// with cargo — so a clear error names how to produce it rather than a raw
// dlopen failure.
export function irohS(): Symbols {
	if (irohSyms !== null) return irohSyms;
	try {
		irohSyms = ffi.dlopen(
			libPath("pancake_net_transport_iroh"),
			irohSymbolDefs,
		);
	} catch (e) {
		throw new Error(
			`iroh transport unavailable: could not load ${
				libFile("pancake_net_transport_iroh")
			} from zig-out/lib. ` +
				"Build it with `zig build iroh-abi` (needs cargo). " +
				(e instanceof Error ? e.message : String(e)),
		);
	}
	return irohSyms;
}
