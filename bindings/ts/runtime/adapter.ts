/**
 * Types and ABI layout helpers for implementing a runtime adapter.
 * Companion packages supply FFI, callbacks, memory access, and networking
 * through these interfaces. Browser applications normally use `@glowcap/web`,
 * which installs its Wasm adapter before opening a Runtime.
 *
 * @module
 */

export * from "./internal/ffi/surface.ts";
export type {
	FfiCallback,
	FfiType,
	RuntimeAdapter,
	RuntimeFfi,
	RuntimeNet,
	SymbolDef,
} from "./internal/ffi/runtime.ts";
export { type AbiLayout, layoutFromWasmDescriptor } from "./internal/layout.ts";
