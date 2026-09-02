// Browser selection of `@glowcap/runtime/ffi`.
//
// The wasm adapter resolves every symbol from one WebAssembly instance, so a
// library pathname has no meaning here. Browser bundle configs map the FFI
// subpath to this file at build time; the native archive resolver therefore
// stays out of the browser module graph instead of arriving behind Node stubs.

export * from "../runtime/internal/ffi/surface.ts";

/** The wasm adapter ignores paths and resolves this archive stem directly. */
export function libPath(stem: string): string {
	return stem;
}
