// Attach signals through the directory the session capability names.

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

const { dirId } = await import("../web/ui/types.ts");
const {
	dropMismatchedWebrtcAttachSignaling,
	webrtcAttachSignalingHeld,
	webrtcAttachSignalingReady,
	webrtcSignalingRoute,
} = await import("../web/ui/net/webrtc_route.ts");
const { assertEquals } = await import("./assert.ts");

function liveTable(
	sessions: { id: string; dir: object; registered?: boolean; home?: boolean }[],
	bootstrapLocator: string | null = null,
) {
	const dirs = new Map(
		sessions.map((session) => [dirId(session.id), {
			id: dirId(session.id),
			dir: session.dir,
			registered: session.registered === true,
			home: session.home === true,
		}]),
	);
	return {
		reachable: {
			signalingDirectory: null as object | null,
			signalingDirectoryLocator: null as string | null,
			stopSignalingDirectory() {
				this.signalingDirectory = null;
				this.signalingDirectoryLocator = null;
			},
		},
		bootstrap: { homeDirectoryLocator: bootstrapLocator },
		live: {
			dirs,
			soleLive: () => dirs.size === 1 ? [...dirs.values()][0] : null,
			dirSession: (id: string) => dirs.get(dirId(id)) ?? null,
		},
		projection: { get: () => ({ homeDir: null as ReturnType<typeof dirId> | null }) },
	};
}

Deno.test("Attach signaling is preferred over a leftover UI directory", () => {
	const attach = { id: "attach" };
	const home = { id: "home" };
	const page = liveTable([{ id: "home", dir: home, home: true, registered: true }]);
	page.reachable.signalingDirectory = attach;
	assertEquals(webrtcSignalingRoute(page as never), attach);
});

Deno.test("ordinary DMs still signal through the one live UI directory", () => {
	const leftover = { id: "leftover" };
	const page = liveTable([{ id: "leftover", dir: leftover, registered: true }]);
	assertEquals(webrtcSignalingRoute(page as never), leftover);
});

Deno.test("a registered leftover directory is not Attach signaling", () => {
	const remote = { id: "remote" };
	const page = liveTable([{ id: "remote", dir: remote, registered: true }]);
	assertEquals(webrtcAttachSignalingReady(page as never), false);
});

Deno.test("a registered store home on another directory is not Attach signaling", () => {
	const home = { id: "home" };
	const remote = { id: "remote" };
	const page = liveTable([
		{ id: "home", dir: home, home: true, registered: false },
		{ id: "remote", dir: remote, registered: true },
	]);
	page.projection = { get: () => ({ homeDir: dirId("remote") }) };
	assertEquals(webrtcAttachSignalingReady(page as never), false);
	assertEquals(webrtcSignalingRoute(page as never), home);
});

Deno.test("this page's registered home membership is Attach signaling", () => {
	const home = { id: "home" };
	const page = liveTable([{ id: "home", dir: home, home: true, registered: true }]);
	assertEquals(webrtcAttachSignalingReady(page as never), true);
	assertEquals(webrtcSignalingRoute(page as never), home);
});

Deno.test("this page's registered home is not Attach signaling for another directory", async () => {
	const { directoryId } = await import("../web/ui/net/bootstrap.ts");
	const pageLocator = "ocapn://abcdefabcdef.iroh";
	const hostLocator = "ocapn://fedcbafedcba.iroh";
	const pageHomeId = directoryId(pageLocator);
	if (pageHomeId == null) throw new Error("test locator must parse as a directory");
	const pageHome = { id: "page-home" };
	const page = liveTable(
		[{ id: pageHomeId, dir: pageHome, registered: true }],
		pageLocator,
	);
	assertEquals(webrtcAttachSignalingReady(page as never, pageLocator), true);
	assertEquals(webrtcAttachSignalingReady(page as never, hostLocator), false);
	assertEquals(webrtcAttachSignalingHeld(page as never, hostLocator), false);
});

Deno.test("a leftover join of the named directory is Attach signaling", async () => {
	const { directoryId } = await import("../web/ui/net/bootstrap.ts");
	const pageLocator = "ocapn://abcdefabcdef.iroh";
	const hostLocator = "ocapn://fedcbafedcba.iroh";
	const pageHomeId = directoryId(pageLocator);
	const hostId = directoryId(hostLocator);
	if (pageHomeId == null || hostId == null) throw new Error("test locator must parse as a directory");
	const pageHome = { id: "page-home" };
	const host = { id: "host" };
	const page = liveTable(
		[
			{ id: pageHomeId, dir: pageHome, registered: true },
			{ id: hostId, dir: host, registered: true },
		],
		pageLocator,
	);
	assertEquals(webrtcAttachSignalingReady(page as never, hostLocator), true);
	assertEquals(webrtcAttachSignalingHeld(page as never, hostLocator), true);
	page.reachable.signalingDirectoryLocator = hostLocator;
	assertEquals(webrtcSignalingRoute(page as never), host);
	page.reachable.signalingDirectoryLocator = null;
	assertEquals(webrtcSignalingRoute(page as never), pageHome);
});

Deno.test("a leftover dedicated membership is not the named directory", async () => {
	const { directoryId } = await import("../web/ui/net/bootstrap.ts");
	const pageLocator = "ocapn://abcdefabcdef.iroh";
	const hostLocator = "ocapn://fedcbafedcba.iroh";
	const hostId = directoryId(hostLocator);
	if (hostId == null) throw new Error("test locator must parse as a directory");
	const attach = { id: "attach" };
	const host = { id: "host" };
	const page = liveTable([{ id: hostId, dir: host, registered: true }]);
	page.reachable.signalingDirectory = attach;
	page.reachable.signalingDirectoryLocator = pageLocator;
	assertEquals(webrtcAttachSignalingReady(page as never, hostLocator), true);
	assertEquals(webrtcSignalingRoute(page as never), attach);
	dropMismatchedWebrtcAttachSignaling(page as never, hostLocator);
	page.reachable.signalingDirectoryLocator = hostLocator;
	assertEquals(page.reachable.signalingDirectory, null);
	assertEquals(webrtcSignalingRoute(page as never), host);
});

Deno.test("a dedicated Attach membership is signaling without a home UI session", () => {
	const attach = { id: "attach" };
	const page = liveTable([]);
	page.reachable.signalingDirectory = attach;
	assertEquals(webrtcAttachSignalingReady(page as never), true);
});

Deno.test("the page locator, not a restored Live.home, is Attach signaling", async () => {
	const { directoryId } = await import("../web/ui/net/bootstrap.ts");
	const locator = "ocapn://abcdefabcdef.iroh";
	const pageHomeId = directoryId(locator);
	if (pageHomeId == null) throw new Error("test locator must parse as a directory");
	const pageHome = { id: "page-home" };
	const restored = { id: "restored" };
	const page = liveTable(
		[
			{ id: pageHomeId, dir: pageHome, registered: true },
			{ id: "restored", dir: restored, home: true, registered: true },
		],
		locator,
	);
	page.projection = { get: () => ({ homeDir: dirId("restored") }) };
	assertEquals(webrtcAttachSignalingReady(page as never), true);
	assertEquals(webrtcSignalingRoute(page as never), pageHome);
});

Deno.test("Attach records the named directory before it would open a second session", async () => {
	const source = await Deno.readTextFile(
		new URL("../web/ui/session/attach_signaling.ts", import.meta.url),
	);
	const ensure = source.slice(source.indexOf("export async function ensureWebrtcAttachSignaling"));
	const hintAt = ensure.indexOf("webrtcSignalingDirectoryHint");
	const dropAt = ensure.indexOf("dropMismatchedWebrtcAttachSignaling(page, locator)");
	const heldAt = ensure.indexOf("webrtcAttachSignalingHeld(page, locator)");
	const connectAt = ensure.indexOf("Directory.connect");
	assertEquals(
		hintAt !== -1 && dropAt !== -1 && heldAt !== -1 && connectAt !== -1 &&
			hintAt < dropAt && dropAt < heldAt && heldAt < connectAt,
		true,
	);
});
