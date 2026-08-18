// The address a directory is shared at.
//
// The store keys a directory by its bare authority, so one directory stays one
// directory across address changes; but what lands on a clipboard or inside a
// room link is for somebody else to dial, and routing hints are part of what
// makes an address dialable. `dirAddress` is the one answer every sharing
// surface gives — the card's copy field, a room link, the directory listing —
// and these tests pin its two arms so a surface reverting to the bare key
// fails here rather than on somebody's failed dial.

/// <reference lib="dom" />

// The store's chrome module asks the window about itself at import time, and
// this suite runs where there is no window; the same shim store_test.ts uses.
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({
		matches: false,
		addEventListener() {},
		removeEventListener() {},
	}),
});

const { dirAddress, directoryLocators } = await import("../web/ui/net/live.ts");
const { dirId } = await import("../web/ui/types.ts");

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

Deno.test("a shared directory address keeps the route's hints", () => {
	const id = dirId("ocapn://abcdefabcdef.iroh");
	const route = "ocapn://abcdefabcdef.iroh?direct-addresses=192.0.2.7:9045";
	directoryLocators.set(id, route);
	try {
		assert(dirAddress(id) === route, "the shared address dropped the routing hints this tab dialed with");
	} finally {
		directoryLocators.delete(id);
	}
});

Deno.test("a directory with no recorded route shares its bare authority", () => {
	const id = dirId("ocapn://bareauthority.iroh");
	assert(dirAddress(id) === "ocapn://bareauthority.iroh", "the fallback changed the authority");
});
