// Internal: the runtime-neutral half of `@glowcap/runtime/ffi`.
//
// FFI programs pair this surface with `load.ts`; browser programs pair it
// with `@glowcap/web`'s stem-only resolver. Keeping the split here means the
// browser module graph never has to import a filesystem/archive cascade merely
// to reach the shared symbol-table and marshalling seams.

export {
	type ArchiveFingerprint,
	ffi,
	lazySymbols,
	NULL,
	type Ptr,
	requireArchiveFingerprint,
	type Symbols,
} from "./runtime.ts";
import { ffi } from "./runtime.ts";

/** Name one platform shared library without resolving where it lives. */
export function libFile(stem: string): string {
	const suffix = ffi.libSuffix();
	return suffix === "dll" ? `${stem}.dll` : `lib${stem}.${suffix}`;
}

export * from "../constants.ts";
// The binding-internal seam (`../../internal/seam.ts`): the pointer and
// error-slot helpers a companion transport marshals through. The public `.`
// entry never exports these.
export { ab, outPointer, readErrorSlot } from "../seam.ts";
export { FfiDiagnostic } from "../../transport/diagnostic.ts";
