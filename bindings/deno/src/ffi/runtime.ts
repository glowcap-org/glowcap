/**
 * runtime.ts — `Deno.dlopen` bindings for the protocol-core cdylib
 * (`libpancake_ffi_runtime`). Mirrors `crates/ffi/pancake-ffi-runtime/
 * include/pancake.h` plus the shared `pancake_abi.h` panic seam.
 *
 * Pointer-shaped C params map to Deno's `"pointer"` (opaque handles,
 * nullable arrays). Caller-owned struct buffers (frames, step-outcome,
 * typed values, out-params) map to `"buffer"` — Deno passes a pointer
 * to the backing store. `usize`/`u64` map to `"usize"`/`"u64"` and
 * cross as `bigint`.
 */

import { makeLastError, type Ptr } from "./abi.ts";

const RUNTIME_SYMBOLS = {
  // Library metadata.
  pancake_version: { parameters: [], result: "pointer" },

  // Last-error (this cdylib's own slot).
  pancake_last_error: { parameters: [], result: "pointer" },
  pancake_clear_last_error: { parameters: [], result: "void" },

  // Keypair lifecycle.
  pancake_keypair_new: { parameters: [], result: "pointer" },
  pancake_keypair_from_seed: { parameters: ["buffer", "usize"], result: "pointer" },
  pancake_keypair_free: { parameters: ["pointer"], result: "void" },
  pancake_keypair_pubkey: { parameters: ["pointer", "buffer"], result: "i32" },

  // Peer lifecycle.
  pancake_peer_new: { parameters: ["pointer", "u32"], result: "pointer" },
  pancake_peer_new_advanced: {
    parameters: ["buffer", "buffer", "u32", "u32", "pointer"],
    result: "pointer",
  },
  pancake_peer_get_my_peer_id: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_get_partner_peer_id: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_free: { parameters: ["pointer"], result: "void" },
  pancake_peer_shutdown: { parameters: ["pointer"], result: "void" },
  pancake_peer_register_bootstrap_cap: {
    parameters: ["pointer", "buffer", "usize", "u64"],
    result: "i32",
  },
  pancake_peer_register_export: { parameters: ["pointer", "u64"], result: "i32" },

  // Event callback (nullable function pointer; canonical path is
  // drain-and-poll, so this is bound but rarely used).
  pancake_peer_set_event_callback: {
    parameters: ["pointer", "pointer", "pointer"],
    result: "void",
  },

  // Per-peer step + queues.
  pancake_peer_step: { parameters: ["pointer", "buffer"], result: "i32" },
  // Inbound borrows the caller's PancakeFrame for the call (zero-copy);
  // outbound hands back a self-describing PancakeManagedFrame released
  // via the shared pancake_managed_frame_release (abi seam).
  pancake_peer_feed_inbound: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_take_outbound: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_managed_frame_release: { parameters: ["buffer"], result: "void" },
  pancake_peer_peek_event_kind: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_consume_event: { parameters: ["pointer"], result: "i32" },
  pancake_peer_session_state: { parameters: ["pointer", "buffer"], result: "i32" },
  pancake_peer_has_outbound: { parameters: ["pointer"], result: "i32" },
  pancake_peer_has_event: { parameters: ["pointer"], result: "i32" },

  // Typed send.
  pancake_peer_send_deliver: {
    parameters: ["pointer", "buffer", "pointer", "usize", "u64"],
    result: "i32",
  },
  pancake_peer_send_resolve: { parameters: ["pointer", "u64", "buffer"], result: "i32" },
  pancake_peer_send_abort: {
    parameters: ["pointer", "u32", "buffer", "usize"],
    result: "i32",
  },
  pancake_peer_send_start_session: {
    parameters: ["pointer", "buffer", "buffer"],
    result: "i32",
  },
  pancake_peer_enliven_sturdyref: { parameters: ["pointer", "buffer"], result: "i32" },

  // Typed receive (drain-and-poll).
  pancake_peer_poll_event_deliver: {
    parameters: ["pointer", "buffer", "buffer", "buffer", "buffer", "buffer"],
    result: "i32",
  },
  pancake_peer_poll_event_resolve: {
    parameters: ["pointer", "buffer", "buffer"],
    result: "i32",
  },
  pancake_peer_poll_event_abort: {
    parameters: ["pointer", "buffer", "buffer", "buffer"],
    result: "i32",
  },
  pancake_peer_poll_event_session_established: {
    parameters: ["pointer", "buffer", "buffer", "buffer"],
    result: "i32",
  },

  // Receive-side free helpers (Rust-allocated buffers).
  pancake_typed_args_free: { parameters: ["pointer", "usize"], result: "void" },
  pancake_typed_resolution_free: { parameters: ["pointer"], result: "void" },
  pancake_typed_resolve_me_desc_free: { parameters: ["pointer"], result: "void" },
  pancake_typed_abort_message_free: { parameters: ["pointer", "usize"], result: "void" },
  pancake_typed_partner_locator_free: { parameters: ["pointer", "usize"], result: "void" },

  // OCapN URI parser.
  pancake_ocapn_uri_parse: { parameters: ["buffer"], result: "pointer" },
  pancake_ocapn_uri_free: { parameters: ["pointer"], result: "void" },

  // Syrup frame probe.
  pancake_syrup_frame_probe: {
    parameters: ["buffer", "usize", "buffer", "usize"],
    result: "i32",
  },

  // Cross-peer coordination.
  pancake_sturdyref_dedup_new: { parameters: [], result: "pointer" },
  pancake_sturdyref_dedup_free: { parameters: ["pointer"], result: "void" },
  pancake_cross_peer_drain_relayed_resolutions: { parameters: ["pointer"], result: "i32" },
  pancake_cross_peer_absorb_pending_sturdyref_enlivens: {
    parameters: ["pointer", "pointer"],
    result: "i32",
  },
  pancake_cross_peer_cache_settled_sturdyref_enlivens: {
    parameters: ["pointer", "pointer"],
    result: "i32",
  },
} as const satisfies Deno.ForeignLibraryInterface;

export type RuntimeLib = Deno.DynamicLibrary<typeof RUNTIME_SYMBOLS>;

export interface Runtime {
  readonly lib: RuntimeLib;
  readonly sym: RuntimeLib["symbols"];
  /** This cdylib's own last-error slot (see abi.ts). */
  readonly lastError: () => string;
  close(): void;
}

/**
 * Open the protocol-core cdylib. `path` defaults to `PANCAKE_LIB`.
 */
export function loadRuntime(path = Deno.env.get("PANCAKE_LIB")): Runtime {
  if (!path) {
    throw new Error(
      "PANCAKE_LIB not set; point it at libpancake_ffi_runtime.{so,dylib,dll}",
    );
  }
  const lib = Deno.dlopen(path, RUNTIME_SYMBOLS);
  const lastError = makeLastError(() => lib.symbols.pancake_last_error() as Ptr);
  return {
    lib,
    sym: lib.symbols,
    lastError,
    close: () => lib.close(),
  };
}
