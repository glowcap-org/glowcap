/**
 * Load C transport libraries through the runtime's shared FFI adapter.
 * Companion packages use `libPath`, pointers, and symbol tables from this
 * module so their libraries share one runtime and archive resolver.
 * Applications normally use a transport package's provider or connector.
 *
 * @module
 */

export * from "./internal/ffi/surface.ts";
export { libPath } from "./internal/ffi/load.ts";
