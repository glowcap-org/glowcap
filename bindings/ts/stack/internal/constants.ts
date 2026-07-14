// Private ABI constants for the pancake binding.
//
// Everything the libpancake_ocapn ABI defines — constant values, struct sizes,
// field offsets — is generated into `abi.ts` by `zig build gen-ts-abi` and
// re-exported here; nothing in that family is hand-mirrored. The block below
// carries only the iroh transport archive's loop-surface constants, which live
// in `pancake_net_transport_iroh.h` (a separate archive with its own header).
export * from "./abi.ts";

// iroh event-driven loop surface (ADR-0057): readiness event bits and the
// readiness-record layout for pancake_iroh_netlayer_drain_ready. Mirrors
// PANCAKE_IROH_EV_* and PancakeIrohReadyEvent in include/pancake_net_transport_iroh.h.
export const IROH_EV_READABLE = 1;
export const IROH_EV_WRITABLE = 2;
export const IROH_EV_CLOSED = 4;
export const IROH_EV_ACCEPT = 8;
// One readiness record is a pointer (8 bytes) + uint32 events, padded to 8-byte
// alignment, so the array stride is 16 bytes.
export const IROH_READY_EVENT_SIZE = 16;

// Cycle break message when a local Forward chain exceeds MAX_LOCAL_FORWARD_HOPS
// (from abi.ts / PANCAKE_MAX_LOCAL_FORWARD_HOPS). Binding-local string — not a
// C ABI constant.
export const FORWARD_CYCLE_MESSAGE = "forward cycle: the local forward chain never terminates";
