// Internal: the FFI mirror of `libpancake_ocapn` — the core archive (ADR-0059).
//
// Nothing here is part of the public API. The ergonomic surface in `mod.ts`
// reaches these symbols through `coreS`; a consumer never imports this file.
// This loader opens *only* `libpancake_ocapn`, so importing the core never
// pulls in a transport archive: a program that drives a peer in memory, or one
// that rides the runtime's own networking, links nothing else. Each transport
// archive has its own sibling loader here (`tcp.ts`, `inproc.ts`, `iroh.ts`),
// opened only when that transport is imported. The symbol definitions are
// runtime-neutral; `ffi.dlopen` (from `./runtime.ts`) resolves them through
// whichever runtime is hosting the binding.

import { libPath } from "./load.ts";
import { ffi } from "./runtime.ts";

const coreS = ffi.dlopen(libPath("pancake_ocapn"), {
	pancake_abi_version: {
		parameters: ["buffer", "buffer", "buffer"],
		result: "void",
	},
	pancake_last_error: { parameters: ["buffer", "usize"], result: "usize" },
	pancake_clear_last_error: { parameters: [], result: "void" },
	pancake_context_new: { parameters: ["buffer"], result: "i32" },
	pancake_context_new_with_allocator: {
		parameters: ["buffer", "buffer"],
		result: "i32",
	},
	pancake_context_release: { parameters: ["pointer"], result: "void" },
	pancake_peer_new_in: { parameters: ["pointer", "buffer"], result: "i32" },
	pancake_peer_new_negotiated: {
		parameters: ["u32", "u32", "buffer"],
		result: "i32",
	},
	pancake_peer_new_negotiated_in: {
		parameters: ["pointer", "u32", "u32", "buffer"],
		result: "i32",
	},
	pancake_peer_feed_owned: { parameters: ["pointer", "buffer"], result: "i32" },
	pancake_peer_new: { parameters: ["buffer"], result: "i32" },
	pancake_peer_new_raw_open: { parameters: ["buffer"], result: "i32" },
	pancake_peer_new_raw_open_in: {
		parameters: ["pointer", "buffer"],
		result: "i32",
	},
	pancake_peer_start_session: {
		parameters: [
			"pointer",
			"buffer",
			"usize",
			"buffer",
			"usize",
			"u32",
			"buffer",
			"usize",
		],
		result: "i32",
	},
	pancake_peer_session_is_open: { parameters: ["pointer"], result: "i32" },
	pancake_peer_release: { parameters: ["pointer"], result: "void" },
	pancake_peer_feed_borrowed: {
		parameters: ["pointer", "buffer"],
		result: "i32",
	},
	pancake_peer_recv_stream: {
		parameters: ["pointer", "buffer", "usize", "buffer"],
		result: "i32",
	},
	pancake_peer_step: { parameters: ["pointer"], result: "i32" },
	pancake_peer_step_to_idle: { parameters: ["pointer"], result: "i32" },
	pancake_peer_take_outbound: {
		parameters: ["pointer", "buffer"],
		result: "i32",
	},
	pancake_managed_frame_release: { parameters: ["buffer"], result: "void" },
	pancake_peer_poll_event: { parameters: ["pointer", "buffer"], result: "i32" },
	pancake_event_release: { parameters: ["buffer"], result: "void" },
	pancake_peer_last_abort: { parameters: ["pointer", "buffer"], result: "i32" },
	pancake_peer_register_export: {
		parameters: ["pointer", "u64"],
		result: "i32",
	},
	pancake_peer_next_export: {
		parameters: ["pointer", "buffer"],
		result: "i32",
	},
	pancake_peer_next_answer: {
		parameters: ["pointer", "buffer"],
		result: "i32",
	},
	pancake_peer_register_import: {
		parameters: ["pointer", "u64"],
		result: "i32",
	},
	pancake_peer_peek_event: { parameters: ["pointer"], result: "i32" },
	pancake_peer_send_deliver: {
		parameters: ["pointer", "buffer", "buffer", "usize", "u32", "u64"],
		result: "i32",
	},
	pancake_peer_send_resolve: {
		parameters: ["pointer", "u64", "u32", "buffer", "buffer", "usize"],
		result: "i32",
	},
	pancake_peer_send_get: {
		parameters: ["pointer", "buffer", "buffer", "usize", "u64"],
		result: "i32",
	},
	pancake_peer_send_index: {
		parameters: ["pointer", "buffer", "i64", "u64"],
		result: "i32",
	},
	pancake_peer_send_untag: {
		parameters: ["pointer", "buffer", "buffer", "usize", "u64"],
		result: "i32",
	},
	pancake_peer_poll_event_deliver: {
		parameters: ["pointer", "buffer"],
		result: "i32",
	},
	pancake_peer_poll_event_resolve: {
		parameters: ["pointer", "buffer"],
		result: "i32",
	},
	pancake_deliver_release: { parameters: ["buffer"], result: "void" },
	pancake_resolve_release: { parameters: ["buffer"], result: "void" },
	pancake_peer_register_bootstrap_cap: {
		parameters: ["pointer", "buffer", "usize", "buffer"],
		result: "i32",
	},
	pancake_peer_send_bootstrap_fetch: {
		parameters: ["pointer", "buffer", "usize", "buffer"],
		result: "i32",
	},
	pancake_peer_prepare_enliven: {
		parameters: ["pointer", "buffer", "usize", "buffer"],
		result: "i32",
	},
	pancake_peer_record_enlivenment: {
		parameters: ["pointer", "buffer", "usize", "u32", "u64", "u32"],
		result: "i32",
	},
	pancake_peer_codec: { parameters: ["pointer", "buffer"], result: "i32" },
	pancake_peer_send_gc_export: {
		parameters: ["pointer", "buffer", "buffer", "usize"],
		result: "i32",
	},
	pancake_peer_send_gc_answer: {
		parameters: ["pointer", "u64"],
		result: "i32",
	},
	pancake_peer_send_withdraw_gift: {
		parameters: ["pointer", "buffer", "usize", "buffer", "usize", "u64"],
		result: "i32",
	},
	// Gifter (introducer) half of three-party handoff: author + deposit + resolve,
	// plus a vat-scoped shared gift registry an exporter node binds onto every peer
	// so a deposit on one connection and a withdraw on another resolve together.
	pancake_peer_partner_session_key: {
		parameters: ["pointer", "buffer", "buffer"],
		result: "i32",
	},
	pancake_peer_partner_locator_raw: {
		parameters: ["pointer", "buffer", "buffer"],
		result: "i32",
	},
	pancake_build_handoff_give: {
		parameters: [
			"buffer",
			"usize",
			"buffer",
			"usize",
			"buffer",
			"usize",
			"buffer",
			"usize",
			"buffer",
			"usize",
			"buffer",
			"buffer",
		],
		result: "i32",
	},
	pancake_handoff_give_bytes_release: {
		parameters: ["pointer", "usize"],
		result: "void",
	},
	pancake_encode_peer_locator: {
		parameters: [
			"buffer",
			"usize",
			"buffer",
			"usize",
			"buffer",
			"usize",
			"buffer",
			"buffer",
		],
		result: "i32",
	},
	pancake_peer_locator_bytes_release: {
		parameters: ["pointer", "usize"],
		result: "void",
	},
	pancake_peer_send_deposit_gift: {
		parameters: ["pointer", "buffer", "usize", "buffer"],
		result: "i32",
	},
	pancake_peer_send_resolve_handoff_give: {
		parameters: ["pointer", "u64", "buffer", "usize"],
		result: "i32",
	},
	pancake_gift_registry_new: { parameters: ["buffer"], result: "i32" },
	pancake_gift_registry_free: { parameters: ["pointer"], result: "void" },
	pancake_peer_set_gift_registry: {
		parameters: ["pointer", "pointer"],
		result: "i32",
	},
	// Cross-connection handoff router (PancakeNode, ADR-0066): the sans-io node
	// owns the per-connection peers, the shared gift registry, the retained
	// identity, and the redeemed-token / foreign-home routing tables. The binding
	// registers each connection's node-owned peer, pumps it, and routes by
	// conn_id — every route value an integer, so the routing decision lives in Zig.
	pancake_node_new: { parameters: ["buffer", "usize", "buffer"], result: "i32" },
	pancake_node_new_in: {
		parameters: ["pointer", "buffer", "usize", "buffer"],
		result: "i32",
	},
	pancake_node_free: { parameters: ["pointer"], result: "void" },
	pancake_node_register_conn: {
		parameters: ["pointer", "buffer", "buffer"],
		result: "i32",
	},
	pancake_node_remove_conn: { parameters: ["pointer", "u64"], result: "i32" },
	pancake_node_send_withdraw: {
		parameters: ["pointer", "u64", "buffer", "usize", "u64"],
		result: "i32",
	},
	pancake_node_originate_give: {
		parameters: [
			"pointer",
			"u64",
			"u64",
			"buffer",
			"buffer",
			"usize",
			"u64",
			"buffer",
			"usize",
		],
		result: "i32",
	},
	pancake_node_enroll_redeemed: {
		parameters: ["pointer", "u64", "u64", "buffer"],
		result: "i32",
	},
	pancake_node_route: {
		parameters: ["pointer", "u64", "u64", "buffer", "buffer", "buffer"],
		result: "i32",
	},
	pancake_node_record_foreign_home: {
		parameters: ["pointer", "u64", "u64"],
		result: "i32",
	},
	pancake_node_foreign_home: {
		parameters: ["pointer", "u64", "buffer", "buffer"],
		result: "i32",
	},
	pancake_node_arg_is_foreign: {
		parameters: ["pointer", "u64", "u64", "buffer"],
		result: "i32",
	},
	// OCapN locator URIs — core vocabulary in libpancake_ocapn, so a consumer
	// reaches them without any transport archive. The one grammar every binding
	// shares.
	pancake_uri_parse_peer: {
		parameters: ["buffer", "usize", "buffer"],
		result: "i32",
	},
	pancake_uri_parse_sturdyref: {
		parameters: ["buffer", "usize", "buffer"],
		result: "i32",
	},
	pancake_uri_format_peer: {
		parameters: [
			"buffer",
			"usize",
			"buffer",
			"usize",
			"buffer",
			"buffer",
			"buffer",
			"buffer",
			"usize",
			"buffer",
			"usize",
			"buffer",
		],
		result: "i32",
	},
	pancake_uri_format_sturdyref: {
		parameters: [
			"buffer",
			"usize",
			"buffer",
			"usize",
			"buffer",
			"usize",
			"buffer",
			"buffer",
			"buffer",
			"buffer",
			"usize",
			"buffer",
			"usize",
			"buffer",
		],
		result: "i32",
	},
	pancake_locator_transport: {
		parameters: ["pointer", "buffer", "buffer"],
		result: "i32",
	},
	pancake_locator_designator: {
		parameters: ["pointer", "buffer", "buffer"],
		result: "i32",
	},
	pancake_locator_swissnum: {
		parameters: ["pointer", "buffer", "buffer"],
		result: "i32",
	},
	pancake_locator_hint: {
		parameters: ["pointer", "buffer", "usize", "buffer", "buffer"],
		result: "i32",
	},
	pancake_locator_hint_count: {
		parameters: ["pointer", "buffer"],
		result: "i32",
	},
	pancake_locator_hint_at: {
		parameters: ["pointer", "usize", "buffer", "buffer", "buffer", "buffer"],
		result: "i32",
	},
	pancake_locator_release: { parameters: ["pointer"], result: "void" },
});

export { coreS };
