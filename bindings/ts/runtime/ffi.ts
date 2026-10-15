// The FFI seam for transport-companion packages (e.g. `@glowcap/iroh`).
//
// A companion transport rides its own archive but shares the core's one FFI
// runtime: it loads its symbol table through the same `ffi`, resolves its
// archive through the same `libPath`, and speaks the same `Ptr`/`Symbols`
// vocabulary and ABI constants. ES modules are singletons, so importing this
// from another package binds the *same* adapter instance the core selected,
// one runtime detection, one set of sockets, one archive resolver. The core's
// own `.` export stays free of these low-level names; a companion reaches for
// them here on purpose.

export * from "./internal/ffi/surface.ts";
export { libPath } from "./internal/ffi/load.ts";
