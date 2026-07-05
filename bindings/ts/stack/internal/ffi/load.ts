// Internal: how every archive loader finds its shared library.
//
// pancake ships its C ABI as à-la-carte archives (ADR-0059), one per concern,
// and each loader under this folder opens exactly one of them through the
// runtime FFI seam. This module holds the one piece they all share: resolving a
// built archive's path. Nothing here is public.
//
// Resolution is a cascade, the same one every pancake binding uses:
//   1. `PANCAKE_LIB_DIR` (configure) — an explicit directory wins, the knob for
//      tests, demos, CI, and a packager pointing at a chosen install.
//   2. the repo's `zig-out/lib` (dev fallback) — when running in-tree, the build
//      output the gates exercise.
//   3. a bare library name (find) — otherwise hand the loader the plain name and
//      let the OS dynamic-linker search resolve it (an installed/system lib).
//
// `node:process`/`node:fs` work on all three runtimes (Deno supports the `node:`
// specifiers). A runtime that withholds the permission (Deno without
// `--allow-env`/`--allow-read`) degrades to the next rung instead of failing:
// the env read is permission-queried first so it never prompts (see
// `envOverride`), and the file probe is wrapped so a denied read falls through.

import process from "node:process";
import { existsSync } from "node:fs";
import { ffi } from "./runtime.ts";

// The dynamic library's name is platform-specific: `.dylib` on macOS, `.dll` on
// Windows, `.so` elsewhere. `zig build` emits the right one into zig-out/lib.
export function libFile(stem: string): string {
	const suffix = ffi.libSuffix();
	return suffix === "dll" ? `${stem}.dll` : `lib${stem}.${suffix}`;
}

function envOverride(): string | null {
	// Deno *prompts* (it does not throw) when an env var is read without
	// --allow-env in a TTY, so a bare try/catch leaves an interactive prompt in
	// any ungranted entrypoint or spawned child. Query the permission first —
	// querySync never prompts — and read only when it is already granted, so an
	// ungranted run degrades silently to the dev/find rungs. The same no-prompt
	// guard the rooms web UI uses for ROOMS_TRANSPORT. Node and Bun have no
	// permission system (no `Deno`), so the guard is skipped and the read happens.
	const deno = (globalThis as {
		Deno?: {
			permissions?: {
				querySync(d: { name: "env"; variable: string }): { state: string };
			};
		};
	}).Deno;
	if (
		deno?.permissions?.querySync &&
		deno.permissions.querySync({ name: "env", variable: "PANCAKE_LIB_DIR" })
				.state !== "granted"
	) {
		return null; // env not granted on Deno: no override, no prompt
	}
	try {
		const dir = process.env.PANCAKE_LIB_DIR;
		return dir !== undefined && dir.length > 0 ? dir : null;
	} catch {
		return null; // no env permission: no override
	}
}

// `stack/internal/ffi/load.ts` is five directories below the repository root, so
// the build output sits at `../../../../../zig-out/lib` when running in-tree.
function devDir(): string | null {
	try {
		const dir = new URL("../../../../../zig-out/lib/", import.meta.url).pathname;
		return existsSync(dir) ? dir : null;
	} catch {
		return null; // no read permission, or not in-tree: fall through to find
	}
}

// The directory to load archives from, or null to use a bare name (OS search).
function libDir(): string | null {
	return envOverride() ?? devDir();
}

export function libPath(stem: string): string {
	const file = libFile(stem);
	const dir = libDir();
	if (dir === null) return file; // bare name: the OS dynamic-linker search
	return `${dir.replace(/\/$/, "")}/${file}`;
}
