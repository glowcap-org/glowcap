// What a reader of the website's viewer is told when the page cannot reach a
// trace: once, without a retry, for a trace at any address but this
// computer's own, and with the browser's permission named when it may be what
// stands between the page and this computer.
import { assert, assertEquals } from "@std/assert";
import { LiveFeed, type LivePeer } from "../connection.ts";
import { TraceOutOfReach } from "../reach.ts";
import type { EngineError } from "../../errors.ts";
import type { GlowcapWebModule } from "../glowcap-web-api.ts";

const browserWasm = new URL("../../../../../../zig-out/wasm/glowcap_host.wasm", import.meta.url);
let browserWasmExists = true;
try {
	await Deno.stat(browserWasm);
} catch (error) {
	if (error instanceof Deno.errors.NotFound) browserWasmExists = false;
	else throw error;
}

const TRACE_ELSEWHERE = "ocapn://trace.example%3A9300.tcp/s/c3dpc3M";
const TRACE_HERE = "ocapn://127.0.0.1%3A9300.tcp/s/c3dpc3M";

/** Run `body` as the website's page: loaded over https from another machine,
 * in a browser whose local network permission answers `permission`. Each
 * permission question the page asks is added to `asked`. */
async function asWebsitePage(permission: string, body: () => Promise<void>, asked: string[] = []): Promise<void> {
	const stand = {
		document: {
			location: { protocol: "https:", hostname: "viewer.example" },
			baseURI: "https://viewer.example/ocapnviz/",
		},
		navigator: {
			permissions: {
				query: ({ name }: { name: string }) => {
					asked.push(name);
					return Promise.resolve({ state: permission });
				},
			},
		},
	};
	const prior = new Map<string, PropertyDescriptor | undefined>();
	for (const [name, value] of Object.entries(stand)) {
		prior.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
		Object.defineProperty(globalThis, name, { configurable: true, value });
	}
	try {
		await body();
	} finally {
		for (const [name, descriptor] of prior) {
			if (descriptor == null) Reflect.deleteProperty(globalThis, name);
			else Object.defineProperty(globalThis, name, descriptor);
		}
	}
}

/** Run `body` with every timer request recorded and none started. */
async function withTimersHeld(body: (scheduled: unknown[][]) => Promise<void>): Promise<void> {
	const scheduled: unknown[][] = [];
	const setTimeout = globalThis.setTimeout;
	globalThis.setTimeout = (...args: unknown[]) => {
		scheduled.push(args);
		return 0;
	};
	try {
		await body(scheduled);
	} finally {
		globalThis.setTimeout = setTimeout;
	}
}

/** A feed whose every dial fails with `failure`, and what it reported. */
function failingFeed(sturdyref: string, failure: Error) {
	const seen: { dials: number; reports: EngineError[]; states: string[] } = { dials: 0, reports: [], states: [] };
	const feed = new LiveFeed(sturdyref, (): Promise<LivePeer> => {
		seen.dials += 1;
		return Promise.reject(failure);
	});
	feed.onError((error) => seen.reports.push(error));
	feed.onConnectionChange((state) => seen.states.push(state));
	return { feed, seen };
}

/** Let the rejected dial and the permission answer both land. */
async function settled(): Promise<void> {
	for (let turn = 0; turn < 8; turn += 1) await Promise.resolve();
}

Deno.test({
	name: "the browser runtime carries the refusal of a trace at another address to the reader",
	ignore: !browserWasmExists,
	fn: async () => {
		const wasmObjectUrl = URL.createObjectURL(
			new Blob([await Deno.readFile(browserWasm)], { type: "application/wasm" }),
		);
		globalThis.__OCV_GLOWCAP_WASM_URL = wasmObjectUrl;
		const webModuleName: string = "@glowcap/web";
		globalThis.__OCV_GLOWCAP_WEB_LOADER = (): Promise<GlowcapWebModule> => import(webModuleName);
		const feed = new LiveFeed(TRACE_ELSEWHERE);
		const states: string[] = [];
		feed.onConnectionChange((state) => states.push(state));
		try {
			await asWebsitePage("granted", async () => {
				const reported = new Promise<EngineError>((resolve) => feed.onError(resolve));
				feed.connect();
				const error = await reported;
				assertEquals(error.title, "This page cannot reach that trace");
				assertEquals(error.code, "validation");
				assert(error.detail.includes("trace.example"), error.detail);
				assert(error.recovery?.includes("zig build ocapnviz-dev"), error.recovery);
				assertEquals(states, ["refused"]);
			});
		} finally {
			feed.disconnect();
			globalThis.__OCV_GLOWCAP_WEB_LOADER = undefined;
			globalThis.__OCV_GLOWCAP_WASM_URL = undefined;
			URL.revokeObjectURL(wasmObjectUrl);
		}
	},
});

Deno.test("a trace out of reach is refused once and never redialed", async () => {
	await withTimersHeld(async (scheduled) => {
		const { feed, seen } = failingFeed(
			TRACE_ELSEWHERE,
			new Error("dial failed", { cause: new TraceOutOfReach("trace.example") }),
		);
		try {
			feed.connect();
			await settled();
			assertEquals(seen.dials, 1);
			assertEquals(seen.reports.map((error) => error.title), ["This page cannot reach that trace"]);
			assertEquals(scheduled, [], "a host the browser forbids is not redialed");
			assertEquals(seen.states, ["refused"]);
		} finally {
			feed.disconnect();
		}
	});
});

Deno.test("a link that is no sturdyref is refused, not left connecting", () => {
	const { feed, seen } = failingFeed("w", new Error("never dialed"));
	feed.connect();
	assertEquals(seen.dials, 0);
	assertEquals(seen.states, ["refused"]);
	assertEquals(seen.reports.map((error) => error.title), ["Live capability invalid"]);
	feed.disconnect();
});

/** Dial a trace on this computer from the website and let it fail. */
async function failedDialFromWebsite(permission: string, during: (feed: LiveFeed) => void = () => {}) {
	const failure = new Error("WebSocket connect failed");
	const { feed, seen } = failingFeed(TRACE_HERE, failure);
	const timers: unknown[][] = [];
	const asked: string[] = [];
	await withTimersHeld(async (scheduled) => {
		try {
			await asWebsitePage(permission, async () => {
				feed.connect();
				during(feed);
				await settled();
			}, asked);
			timers.push(...scheduled);
		} finally {
			feed.disconnect();
		}
	});
	return { failure, seen, timers, asked };
}

Deno.test("a dial the browser denied names the permission and keeps retrying", async () => {
	const { failure, seen, timers } = await failedDialFromWebsite("denied");
	assertEquals(seen.reports.map((error) => error.title), ["The browser is keeping this page from your computer"]);
	assert(seen.reports[0]?.recovery?.includes("site settings"), seen.reports[0]?.recovery);
	assertEquals(seen.reports[0]?.cause, failure);
	assertEquals(seen.states, ["connecting"]);
	assertEquals(timers.length, 1, "allowing the permission lets the next dial through");
});

Deno.test("a dial that fails while the browser is unanswered names the server and the permission", async () => {
	const { seen, timers } = await failedDialFromWebsite("prompt");
	assertEquals(seen.reports.map((error) => error.title), ["Live capability unreachable"]);
	const recovery = seen.reports[0]?.recovery ?? "";
	assert(recovery.includes("rooms server"), recovery);
	assert(recovery.includes("If the browser asks"), recovery);
	assertEquals(timers.length, 1);
});

Deno.test("a dial that fails with the permission granted is the server's failure", async () => {
	const { seen, timers } = await failedDialFromWebsite("granted");
	assertEquals(seen.reports.map((error) => error.title), ["Live capability unreachable"]);
	assertEquals(seen.reports[0]?.recovery, "Check the sturdyref and the rooms server, then wait for reconnect.");
	assertEquals(timers.length, 1);
});

Deno.test("a feed closed before the browser answers reports nothing", async () => {
	// The dial's rejection lands one turn after connect, and the browser's
	// answer one turn after that. The close falls between them.
	const { seen, asked } = await failedDialFromWebsite("denied", (feed) => {
		void Promise.resolve().then(() => feed.disconnect());
	});
	assertEquals(asked, ["loopback-network"], "the dial failed and the browser was asked before the close");
	assertEquals(seen.reports, []);
});
