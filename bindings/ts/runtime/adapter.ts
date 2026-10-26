// Runtime-neutral seam for adapters supplied by companion packages.
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
