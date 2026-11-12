// What library resolution settles for reaches the failure journal and the
// load that follows.

import { takeRuntimeFailures } from "../failure_journal.ts";
import { ffi } from "../internal/ffi/runtime.ts";
import { noteResolution, resolveNoting } from "../internal/ffi/resolution_notes.ts";
import { assert, assertEquals } from "../../test/assert.ts";

/** A path no library is at: its directory does not exist. */
const missing = () => `/glowcap-absent-${crypto.randomUUID()}/libglowcap_absent.so`;

Deno.test("a resolution note is a library-resolution event", () => {
	takeRuntimeFailures();
	resolveNoting(() => {
		noteResolution("download failed: https://example.invalid/x.tar.gz (soft-fail)");
		return missing();
	});
	const events = takeRuntimeFailures();
	assertEquals(events.length, 1);
	assertEquals(events[0].layer, "binding");
	assertEquals(events[0].operation, "library-resolution");
	assertEquals(events[0].primaryMessage, "download failed: https://example.invalid/x.tar.gz (soft-fail)");
});

Deno.test("a load that fails names what its resolution noted, with the open's error as cause", () => {
	const path = resolveNoting(() => {
		noteResolution("loading bare libglowcap_absent.so via the OS search path");
		return missing();
	});
	takeRuntimeFailures();
	let thrown: unknown = null;
	try {
		ffi.dlopen(path, {});
	} catch (error) {
		thrown = error;
	}
	assert(thrown instanceof Error, "the missing library loaded");
	assert(thrown.message.includes("loading bare libglowcap_absent.so via the OS search path"), thrown.message);
	assert(thrown.cause instanceof Error, "the open's own error was dropped");
});

Deno.test("a clean resolution of the same path leaves its load error as it was", () => {
	const path = missing();
	resolveNoting(() => {
		noteResolution("timed out waiting for cache lock (soft-fail)");
		return path;
	});
	resolveNoting(() => path);
	takeRuntimeFailures();
	let thrown: unknown = null;
	try {
		ffi.dlopen(path, {});
	} catch (error) {
		thrown = error;
	}
	assert(thrown instanceof Error, "the missing library loaded");
	assert(!thrown.message.includes("library resolution noted"), "a stale note reached a clean resolution's load");
});
