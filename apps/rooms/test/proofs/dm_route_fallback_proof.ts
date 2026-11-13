import { spawnWeb, webAnnouncements, webPort } from "../support/web_front.ts";
// A browser member in the default direct-message mode advertises WebRTC as
// its route and the Rooms server's sealed relay as the fallback the Host
// tries after the direct attempt fails (ADR-0036). A network that blocks
// WebRTC rarely reports that: with no candidates at all Chromium keeps the
// connection in its first state and never says it failed. The offerer's
// connect bound (`SIGNAL_CONNECT_TIMEOUT_MS`) is what reports the failure,
// so the fallback must open the line within that bound plus a relay dial,
// well inside the introduction's own request budget.
//
// Chromium runs with every non-proxied UDP route disabled, so ICE gathers no
// candidates and the DataChannel never opens. The two tabs still join with
// `?dm=webrtc`, Alice opens a line to Bob, and the proof reads the live
// timeline: the line that carries the message is a noise-relay session, no
// webrtc session opened, and the open took less than the bound allows. Both
// conversation cards' Path fact then names the server, not the saved choice,
// and Bob's answering side, which the directory tells nothing when Alice
// moves on, waits out its own exchange budget and ends quietly, with no
// failure under **Browser trouble** for a line that opened.
//
// Needs deno, the wasm module (`zig build wasm-host`), the installed archives
// (serve.ts's room server is the Rust process), and a Playwright Chromium
// (the devcontainer image ships one).
// Run: `zig build rooms-web-dm-fallback`.

import { type Browser, chromium, type Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { reapOwned } from "../support/children.ts";
import { acquireTraceCapability, connectTraceViewer } from "../trace/viewer.ts";
import { waitForHttp } from "../support/rooms_server.ts";
import { until } from "../support/wait.ts";
import { fail } from "../support/fail.ts";
import { awaitBubble, directOpened, openDmTo, pathSaid } from "../page/harness.ts";
import { takeCapability } from "../page/capability_set.ts";
import { roomsLocator } from "../../lib/locator.ts";
import { formatRoomsSturdyref } from "../support/sturdyref.ts";
import { SIGNAL_CONNECT_TIMEOUT_MS, SIGNAL_EXCHANGE_TIMEOUT_MS } from "../../lib/limits.ts";
import { factDmRelay } from "../../lib/text/conversation.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;
const ROOM = "lobby";
const DM_TEXT = "hi Bob, over the server because WebRTC found no route";
const REPLY_TEXT = "got it Alice, same sealed session back";
// The relay dial after the direct attempt gives up: a local rendezvous
// through the page's own server, generous for a loaded CI host.
const RELAY_DIAL_ALLOWANCE_MS = 5_000;

async function joinAs(browser: Browser, port: number, nick: string, trace: string): Promise<Page> {
	const tab = await (await browser.newContext()).newPage();
	tab.on("pageerror", (e) => console.error(`  [${nick} page error]`, e.message));
	tab.on("console", (m) => {
		if (m.type() === "error") console.error(`  [${nick} console.error]`, m.text());
	});
	await tab.goto(`http://127.0.0.1:${port}/?dm=webrtc`);
	await establishLocalSession(tab);
	await acquireTraceCapability(tab, trace);
	await tab.fill("#nick", nick);
	await tab.fill("#room", ROOM);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 }).catch(async () => {
		const status = await tab.textContent("#status").catch(() => "?");
		fail(`${nick} never joined; status="${status}"`);
	});
	return tab;
}

async function send(tab: Page, text: string): Promise<void> {
	await tab.fill("#line", text);
	await tab.press("#line", "Enter");
}

// The page's **Browser trouble** rows: wasm failures with no surface of their
// own, read under Operations by a member holding the operator capability. The
// operator pane draws the rows from the page's own store in the same render
// as the panel, and draws no section while there are none, so a present panel
// with no rows is the state and not an unread one. Against the unbounded
// answerer this read returned the signaling timeout.
async function pageTrouble(tab: Page, operator: string): Promise<string[]> {
	await tab.click("#settingsBtn");
	await tab.click("#holdingsTab");
	await takeCapability(tab, "#opsOperatorToggle", operator);
	await tab.click("#opsBtn");
	await tab.click("#operatorOpsLink");
	await tab.waitForSelector("#operatorOpsPanel");
	return await tab.$$eval("#pageTrouble li", (rows) => rows.map((row) => row.textContent ?? ""));
}

const deadline = setTimeout(() => fail("web-dm-fallback scenario timed out after 55s"), 55_000);

const state = await Deno.makeTempDir({ prefix: "rooms-dm-fallback-" });
let browser: Browser | null = null;
let viewer: { close(): Promise<void> } | null = null;
try {
	const web = spawnWeb({
		args: ["--transport=tcp", "0", "0"],
		cwd: ROOT,
		env: {
			GLOWCAP_ROOMS_STATE: state,
			GLOWCAP_ROOMS_CAPABILITIES: "trace,operator",
			GLOWCAP_ROOMS_TRACE_PORT: "0",
		},
		stdout: "piped",
		stderr: "piped",
	});
	const traceRef = webAnnouncements(web).line("ROOMS-TRACE-LISTENING", "rooms-web");
	const httpPort = await webPort(web);
	await waitForHttp(httpPort);
	const sturdyref = await traceRef;
	const transports = new Set<string>();
	viewer = await connectTraceViewer(sturdyref, (record) => {
		if (record.kind !== "ocapn.session-opened") return;
		transports.add(String(record.transport ?? ""));
	});

	// No non-proxied UDP: ICE gathers nothing, and the peer connection never
	// reports failure on its own.
	browser = await chromium.launch({
		args: ["--no-sandbox", "--force-webrtc-ip-handling-policy=disable_non_proxied_udp"],
	});

	const alice = await joinAs(browser, httpPort, "web-alice", sturdyref);
	const bob = await joinAs(browser, httpPort, "web-bob", sturdyref);

	// Alice's Host tries WebRTC first, gives up at the connect bound, and
	// dials Bob's sealed relay rendezvous next.
	const started = Date.now();
	await alice.locator('#members li:has-text("web-bob") button.dm-btn').click();
	const allowance = SIGNAL_CONNECT_TIMEOUT_MS + RELAY_DIAL_ALLOWANCE_MS;
	await directOpened(alice, "web-bob", allowance).catch(() =>
		fail(`the direct line did not fall back to the server within ${allowance} ms`)
	);
	const elapsed = Date.now() - started;
	await pathSaid(alice, factDmRelay, "noise-relay");
	await send(alice, DM_TEXT);

	await openDmTo(bob, "web-alice");
	await awaitBubble(bob, DM_TEXT, "Bob");
	await pathSaid(bob, factDmRelay, "noise-relay");
	await send(bob, REPLY_TEXT);
	await awaitBubble(alice, REPLY_TEXT, "Alice");

	// Bob's answering side ends quietly when its exchange budget, started at
	// the offer, runs out. An attempt that reported that end would put a
	// signaling failure under Bob's **Browser trouble** for a line that opened.
	await until(
		() => Date.now() - started > SIGNAL_EXCHANGE_TIMEOUT_MS + 3_000,
		"the signaling exchange budget to pass",
		SIGNAL_EXCHANGE_TIMEOUT_MS + 4_000,
	);
	const locator = await (await fetch(`http://127.0.0.1:${httpPort}/locator`)).text();
	const operator = formatRoomsSturdyref(
		roomsLocator(locator.trim()),
		(await Deno.readTextFile(`${state}/operator`)).trim(),
	);
	const signaling = (await pageTrouble(bob, operator)).filter((row) => /signaling/i.test(row));
	if (signaling.length > 0) {
		fail(`Bob's Browser trouble reports a signaling failure for a line that opened: ${signaling.join(" | ")}`);
	}

	await until(() => transports.has("noise-relay"), "the live timeline to observe the noise-relay session", 5_000);
	if (transports.has("webrtc")) fail("a webrtc session opened although ICE had no route");

	console.log(
		`PASS: with WebRTC unable to find a route, the direct line opened through the Rooms server's ` +
			`sealed relay in ${elapsed} ms (bound ${allowance} ms), both cards said so, the message went both ` +
			`ways, no webrtc session stood in for it, and Bob's Browser trouble holds no signaling failure`,
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	if (viewer) await viewer.close().catch(() => {});
	await reapOwned();
	await Deno.remove(state, { recursive: true }).catch(() => {});
}
Deno.exit(0);
