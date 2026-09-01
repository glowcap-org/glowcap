// A hosted session names the same locator DMs already advertise.

/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
Object.defineProperty(globalThis, "location", {
	configurable: true,
	value: {
		search: "",
		href: "http://rooms.test/",
		protocol: "http:",
		host: "rooms.test",
		pathname: "/",
		reload() {},
	},
});
Object.defineProperty(globalThis, "localStorage", {
	configurable: true,
	value: {
		getItem: () => null,
		setItem() {},
		removeItem() {},
	},
});

const { formatLocatorUri, formatPeerUri, TRANSPORT_NOISE_RELAY, TRANSPORT_WEBRTC } = await import(
	"@pancake/runtime"
);
const { RoomsPage } = await import("../web/ui/page.ts");
const { selfLocator, sessionHostLocator } = await import("../web/ui/net/reachable.ts");
const { assertEquals } = await import("./assert.ts");

const DESIGNATOR = "aabbccddeeff00112233445566778899";

function pageWithInboxAndRendezvous() {
	const page = new RoomsPage();
	page.reachable.inboxOwner = {
		host: { designator: () => DESIGNATOR } as import("@pancake/runtime").Host,
		publisher: {} as import("../lib/dm_inbox.ts").InboxPublisher,
		iceServers: () => Promise.resolve([]),
	};
	const locator = {
		transport: TRANSPORT_NOISE_RELAY,
		designator: DESIGNATOR,
		hints: new Map(),
		hintWireForm: "map" as const,
	};
	page.reachable.rendezvous = {
		locator,
		ready: () => Promise.resolve(),
		stop: () => Promise.resolve(),
		drain: () => Promise.resolve(),
		[Symbol.asyncDispose]: () => Promise.resolve(),
	};
	return { page, locator };
}

Deno.test("a hosted session locator is the WebRTC DM locator even when rendezvous is registered", () => {
	const { page } = pageWithInboxAndRendezvous();
	assertEquals(selfLocator(page), formatPeerUri(TRANSPORT_WEBRTC, DESIGNATOR));
	assertEquals(sessionHostLocator(page), selfLocator(page));
});

Deno.test("a hosted WebRTC session locator names this page's directory for Attach signaling", async () => {
	const { WEBRTC_SIGNALING_DIRECTORY_HINT, webrtcSignalingDirectoryHint, roomsLocator } = await import(
		"../lib/locator.ts"
	);
	const { page } = pageWithInboxAndRendezvous();
	const directory = "ocapn://abcdefabcdef.iroh";
	page.bootstrap.homeDirectoryLocator = directory;
	const advertised = sessionHostLocator(page);
	if (advertised == null) throw new Error("a hosted locator must be advertised");
	assertEquals(advertised === selfLocator(page), false);
	assertEquals(webrtcSignalingDirectoryHint(roomsLocator(advertised)), directory);
	assertEquals(roomsLocator(advertised).hints.get(WEBRTC_SIGNALING_DIRECTORY_HINT), directory);
});

Deno.test("a hosted session locator is the noise-relay DM locator when DMs use relay", () => {
	const location = globalThis.location as { search: string };
	const prior = location.search;
	location.search = "?dm=relay";
	try {
		const { page, locator } = pageWithInboxAndRendezvous();
		assertEquals(sessionHostLocator(page), formatLocatorUri(locator));
		assertEquals(sessionHostLocator(page), selfLocator(page));
	} finally {
		location.search = prior;
	}
});
