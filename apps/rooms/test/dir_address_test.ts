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

const { directoryId } = await import("../web/ui/net/bootstrap.ts");
const { dirAddress } = await import("../web/ui/net/live.ts");
const { RoomsPage } = await import("../web/ui/page.ts");
const { dirId } = await import("../web/ui/types.ts");
const store = await import("../web/ui/store.ts");

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

Deno.test("a shared directory address keeps the route's hints", () => {
	const page = new RoomsPage();
	const id = dirId("ocapn://abcdefabcdef.iroh");
	const route = "ocapn://abcdefabcdef.iroh?direct-addresses=192.0.2.7:9045";
	page.live.directoryLocators.set(id, route);
	assert(dirAddress(page, id) === route, "the shared address dropped the routing hints this tab dialed with");
});

Deno.test("a restored directory falls back to its route, not its authority", () => {
	const page = new RoomsPage();
	const id = dirId("ocapn://bareauthority.iroh");
	store.openDir(page.projection, id, "ocapn://routekey.iroh");
	assert(dirAddress(page, id) === "ocapn://routekey.iroh", "the fallback laundered the authority into an address");
});

Deno.test("identity-proving room routes file one Host as one directory", () => {
	const key = "abcdefabcdef";
	const iroh = directoryId(`ocapn://${key}.iroh`);
	const noise = directoryId(`ocapn://${key}.noise-tcp`);
	const identity = directoryId(`ocapn://${key}.id?via=ocapn%3A%2F%2F${key}.iroh`);
	assert(iroh !== null && iroh === noise && noise === identity, "one Host key split into several directories");
	assert(
		directoryId(`${key}:9099`) !== identity,
		"an unauthenticated TCP address was merged into a Host identity route",
	);
});

Deno.test("two pages do not share directory sessions", () => {
	const first = new RoomsPage();
	const second = new RoomsPage();
	const id = dirId("ocapn://abcdefabcdef.iroh");
	const session = { page: first, id } as import("../web/ui/net/live.ts").Live;
	first.live.dirs.set(id, session);
	assert(first.live.dirSession(id) === session, "the page that seated the session cannot find it");
	assert(second.live.dirSession(id) === null, "a second page saw another page's directory session");
});

Deno.test("two pages do not share direct-message back-channels", () => {
	const first = new RoomsPage();
	const second = new RoomsPage();
	first.directs.saidIgnoredDm.add("dm:peer");
	assert(second.directs.saidIgnoredDm.size === 0, "a second page saw another page's ignored-DM notes");
});

Deno.test("two pages do not share inbox offerers", () => {
	const first = new RoomsPage();
	const second = new RoomsPage();
	first.reachable.saidRendezvousTrouble = true;
	assert(second.reachable.saidRendezvousTrouble === false, "a second page saw another page's rendezvous latch");
});

Deno.test("two pages do not share workspace working copies", () => {
	const first = new RoomsPage();
	const second = new RoomsPage();
	first.workspace.retained.dmMode = "relay";
	assert(second.workspace.retained.dmMode === "webrtc", "a second page saw another page's workspace working copy");
});

Deno.test("two pages do not share history recorder queues", () => {
	const first = new RoomsPage();
	const second = new RoomsPage();
	first.recorder.keepHistory = false;
	assert(second.recorder.keepHistory === true, "a second page saw another page's history retention");
});
