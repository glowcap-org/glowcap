// Private ABI constants for the glowcap binding.
//
// The libglowcap_ocapn / libglowcap_host ABI splits by target-dependence.
// The target-independent constant values live in the `@glowcap/abi` package and
// are re-exported here. The target-specific struct sizes and field offsets are
// generated into `abi.ts` by `zig build gen-ts-abi` and re-exported here too.
// Nothing here is hand-mirrored: the iroh loop-surface constants (the
// readiness event bits and the readiness-record layout) ride the same two
// generated families.
export * from "@glowcap/abi";
export * from "./abi.ts";

// Cycle break message when a local Forward chain exceeds MAX_LOCAL_FORWARD_HOPS
// (from abi.ts / GLOWCAP_MAX_LOCAL_FORWARD_HOPS). Binding-local string — not a
// C ABI constant.
export const FORWARD_CYCLE_MESSAGE = "forward cycle: the local forward chain never terminates";
