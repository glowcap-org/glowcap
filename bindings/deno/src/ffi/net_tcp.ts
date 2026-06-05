/**
 * net_tcp.ts — `Deno.dlopen` bindings for the TCP/TLS netlayer cdylib
 * (`libpancake_ffi_net_tcp`). Mirrors `crates/ffi/pancake-ffi-net-tcp/
 * include/pancake_net_tcp.h`.
 *
 * The cleartext and `tcp-tls` surfaces mirror each other fn-for-fn
 * (rustls over the same sync TCP core). Both share this cdylib's own
 * last-error slot; read_frame hands back a self-describing
 * PancakeManagedFrame released via the shared
 * `pancake_managed_frame_release` (abi seam).
 */

import { makeLastError, type Ptr } from "./abi.ts";

const NET_TCP_SYMBOLS = {
  pancake_last_error: { parameters: [], result: "pointer" },
  pancake_clear_last_error: { parameters: [], result: "void" },
  // Shared abi-seam release for managed read frames (self-describing).
  pancake_managed_frame_release: { parameters: ["buffer"], result: "void" },

  // Cleartext TCP.
  pancake_endpoint_tcp_connect: { parameters: ["buffer"], result: "pointer" },
  pancake_endpoint_tcp_listen: {
    parameters: ["buffer", "buffer", "usize"],
    result: "pointer",
  },
  pancake_endpoint_tcp_accept_timed: {
    parameters: ["pointer", "u64", "buffer"],
    result: "i32",
  },
  pancake_endpoint_tcp_set_read_timeout_ms: {
    parameters: ["pointer", "u64"],
    result: "i32",
  },
  pancake_endpoint_tcp_read_frame: {
    parameters: ["pointer", "buffer"],
    result: "i32",
  },
  pancake_endpoint_tcp_write_frame: {
    parameters: ["pointer", "buffer", "usize"],
    result: "i32",
  },
  pancake_endpoint_tcp_conn_close: { parameters: ["pointer"], result: "void" },
  pancake_endpoint_tcp_listener_close: { parameters: ["pointer"], result: "void" },

  // tcp-tls.
  pancake_endpoint_tcp_tls_connect: { parameters: ["buffer"], result: "pointer" },
  pancake_endpoint_tcp_tls_listen: {
    parameters: ["buffer", "buffer", "usize"],
    result: "pointer",
  },
  pancake_endpoint_tcp_tls_accept_timed: {
    parameters: ["pointer", "u64", "buffer"],
    result: "i32",
  },
  pancake_endpoint_tcp_tls_set_read_timeout_ms: {
    parameters: ["pointer", "u64"],
    result: "i32",
  },
  pancake_endpoint_tcp_tls_read_frame: {
    parameters: ["pointer", "buffer"],
    result: "i32",
  },
  pancake_endpoint_tcp_tls_write_frame: {
    parameters: ["pointer", "buffer", "usize"],
    result: "i32",
  },
  pancake_endpoint_tcp_tls_conn_close: { parameters: ["pointer"], result: "void" },
  pancake_endpoint_tcp_tls_listener_close: { parameters: ["pointer"], result: "void" },
} as const satisfies Deno.ForeignLibraryInterface;

export type NetTcpLib = Deno.DynamicLibrary<typeof NET_TCP_SYMBOLS>;

export interface NetTcp {
  readonly lib: NetTcpLib;
  readonly sym: NetTcpLib["symbols"];
  readonly lastError: () => string;
  close(): void;
}

export function loadNetTcp(path = Deno.env.get("PANCAKE_NET_TCP_LIB")): NetTcp {
  if (!path) {
    throw new Error(
      "PANCAKE_NET_TCP_LIB not set; point it at libpancake_ffi_net_tcp.{so,dylib,dll}",
    );
  }
  const lib = Deno.dlopen(path, NET_TCP_SYMBOLS);
  const lastError = makeLastError(() => lib.symbols.pancake_last_error() as Ptr);
  return { lib, sym: lib.symbols, lastError, close: () => lib.close() };
}
