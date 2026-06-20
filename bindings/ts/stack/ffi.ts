// The native seam for transport-companion packages (e.g. `@pancake/iroh`).
//
// A companion transport rides its own archive but shares the core's one FFI
// runtime: it loads its symbol table through the same `ffi`, resolves its
// archive through the same `libPath`, and speaks the same `Ptr`/`Symbols`
// vocabulary and ABI constants. ES modules are singletons, so importing this
// from another package binds the *same* adapter instance the core selected,
// one runtime detection, one set of sockets, one archive resolver. The core's
// own `.` export stays free of these low-level names; a companion reaches for
// them here on purpose.

export {
	ffi,
	type NativeCallback,
	type NativeType,
	NULL,
	type Ptr,
	type SymbolDef,
	type Symbols,
} from "./internal/ffi/runtime.ts";
export { libFile, libPath } from "./internal/ffi/load.ts";
export * from "./internal/constants.ts";
