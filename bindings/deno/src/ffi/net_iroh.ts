/**
 * net_iroh.ts — `Deno.dlopen` bindings for the iroh (QUIC) netlayer
 * cdylib (`libpancake_ffi_net_iroh`). Mirrors
 * `crates/ffi/pancake-ffi-net-iroh/include/pancake_net_iroh.h`.
 *
 * iroh differs from TCP: the endpoint is constructed standalone (UDP
 * auto-bound, no host:port), addressed by a base32 `EndpointId`, and
 * dialed by EndpointId + an optional direct UDP `host:port` hint
 * (loopback without discovery). read_frame hands back a self-describing
 * PancakeManagedFrame released via the shared
 * `pancake_managed_frame_release` (abi seam); failures read from its own
 * last-error slot.
 */

import { makeLastError, type Ptr } from "./abi.ts";

/** base32 EndpointId is 64 chars; +1 for NUL. */
export const IROH_ID_CAP = 65;

const NET_IROH_SYMBOLS = {
  pancake_last_error: { parameters: [], result: "pointer" },
  pancake_clear_last_error: { parameters: [], result: "void" },
  // Shared abi-seam release for managed read frames (self-describing).
  pancake_managed_frame_release: { parameters: ["buffer"], result: "void" },

  pancake_endpoint_iroh_new: { parameters: [], result: "pointer" },
  pancake_endpoint_iroh_endpoint_id: {
    parameters: ["pointer", "buffer", "usize"],
    result: "i32",
  },
  pancake_endpoint_iroh_bound_addr: {
    parameters: ["pointer", "buffer", "usize"],
    result: "i32",
  },
  pancake_endpoint_iroh_connect: {
    parameters: ["pointer", "buffer", "buffer"],
    result: "pointer",
  },
  pancake_endpoint_iroh_listen: { parameters: ["pointer"], result: "pointer" },
  pancake_endpoint_iroh_accept_timed: {
    parameters: ["pointer", "u64", "buffer"],
    result: "i32",
  },
  pancake_endpoint_iroh_set_read_timeout_ms: {
    parameters: ["pointer", "u64"],
    result: "i32",
  },
  pancake_endpoint_iroh_read_frame: {
    parameters: ["pointer", "buffer"],
    result: "i32",
  },
  pancake_endpoint_iroh_write_frame: {
    parameters: ["pointer", "buffer", "usize"],
    result: "i32",
  },
  pancake_endpoint_iroh_conn_close: { parameters: ["pointer"], result: "void" },
  pancake_endpoint_iroh_listener_close: { parameters: ["pointer"], result: "void" },
  pancake_endpoint_iroh_close: { parameters: ["pointer"], result: "void" },
} as const satisfies Deno.ForeignLibraryInterface;

export type NetIrohLib = Deno.DynamicLibrary<typeof NET_IROH_SYMBOLS>;

export interface NetIroh {
  readonly lib: NetIrohLib;
  readonly sym: NetIrohLib["symbols"];
  readonly lastError: () => string;
  close(): void;
}

export function loadNetIroh(path = Deno.env.get("PANCAKE_NET_IROH_LIB")): NetIroh {
  if (!path) {
    throw new Error(
      "PANCAKE_NET_IROH_LIB not set; point it at libpancake_ffi_net_iroh.{so,dylib,dll}",
    );
  }
  const lib = Deno.dlopen(path, NET_IROH_SYMBOLS);
  const lastError = makeLastError(() => lib.symbols.pancake_last_error() as Ptr);
  return { lib, sym: lib.symbols, lastError, close: () => lib.close() };
}
