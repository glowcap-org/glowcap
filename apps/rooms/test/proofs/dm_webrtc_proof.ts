// Two browser tabs direct-message each other over a WebRTC DataChannel, the
// room carrying only the signaling (ADR-0035, the live handoff-redeem proof).
// Each tab joins with `?dm=webrtc`, so it advertises a bare
// `ocapn://<key>.webrtc` locator and files a signaling inbox with the room
// directory. When Alice direct-messages Bob, the room introduces her, and her
// Host redeems the handoff give through the dial executor's `signaling` arm:
// the offer, answer, and ICE candidates ride the directory as ordinary OCapN
// messages (`signalOffer` / `signalAnswer` / `signalCandidate`), the
// DataChannel opens tab-to-tab, and the keyed OCapN session runs over it with
// the room out of the byte path. Bob answers over that same arriving
// connection (`currentSession`), so a tab that never listens still replies.
//
// This is the composition ADR-0035 left open: a `desc:handoff-give` whose
// exporter locator names a `webrtc` designator, redeemed end to end. The
// locator carries no signaling route; the dialing host's authority is the
// directory it already reaches, installed as `webrtc.connector`'s signaling,
// the same configured posture the rendezvous cold dial holds.
//
// The live timeline must name `webrtc` and no keyed-relay session, so relay
// delivery cannot pass for this proof.
//
// Needs deno, the wasm module (`zig build wasm-host`), the installed archives
// (serve.ts's room server is the Rust process), and a Playwright Chromium
// (the devcontainer image ships one).
// Run: `zig build rooms-web-dm-webrtc`.

import { spawnWeb, webAnnouncements, webPort } from "../support/web_front.ts";
import { type Browser, type BrowserContext, chromium, type Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { reapOwned } from "../support/children.ts";
import { acquireTraceCapability, connectTraceViewer } from "../trace/viewer.ts";
import { waitForHttp } from "../support/rooms_server.ts";
import { until } from "../support/wait.ts";
import { fail } from "../support/fail.ts";
import { scenarioDeadline } from "../support/deadline.ts";
import { awaitBubble, openDmTo, pathSaid } from "../page/harness.ts";
import { factDmDirect } from "../../lib/text/conversation.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;
const ROOM = "lobby";
const DM_TEXT = "hi Bob, privately, over a DataChannel the room only signaled";
const REPLY_TEXT = "got it Alice, replying over the same channel";

// Join `ROOM` as `nick` in a fresh, isolated tab, in webrtc DM mode, and wait
// until the composer is live, the signal that the keyed session to the room
// is up and the tab is advertising its `webrtc` identity.
async function joinAs(
	browser: Browser,
	port: number,
	nick: string,
	trace: string,
): Promise<{
	context: BrowserContext;
	tab: Page;
}> {
	const context = await browser.newContext();
	const tab = await context.newPage();
	tab.on("pageerror", (e) => console.error(`  [${nick} page error]`, e.message));
	// Surface the page's own error logs (the UI reports a failed dial or a
	// signaling refusal there), so a red run says why instead of only where.
	tab.on("console", (m) => {
		if (m.type() === "error" || m.type() === "warning") {
			console.error(`  [${nick} console.${m.type()}]`, m.text());
		}
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
	return { context, tab };
}

// Open a direct line to `peer` from `tab` by clicking their direct-line button
// in the members list.
async function send(tab: Page, text: string): Promise<void> {
	await tab.fill("#line", text);
	await tab.press("#line", "Enter");
}

// The run takes about 14 s alone and 17 s with two busy threads per core.
// The build's wrapper stops it at 58 s, so this bound holds on a runner half
// as fast and still leaves room to tear down.
const deadline = scenarioDeadline("web-dm-webrtc", 50);

// serve.ts serves the page and runs the room + relay over plain TCP (no
// `--transport=iroh`); the DM channel itself is WebRTC, so no cargo either.
const web = spawnWeb({
	args: ["--transport=tcp", "0", "0"],
	cwd: ROOT,
	env: { GLOWCAP_ROOMS_CAPABILITIES: "trace", GLOWCAP_ROOMS_TRACE_PORT: "0" },
	stdout: "piped",
	stderr: "piped",
});
const traceRef = webAnnouncements(web).line("ROOMS-TRACE-LISTENING", "rooms-web");
const httpPort = await webPort(web);

let browser: Browser | null = null;
let viewer: { close(): Promise<void> } | null = null;
try {
	deadline.at("starting the page server and its trace");
	await waitForHttp(httpPort);
	const sturdyref = await traceRef;
	let sawWebrtc = false;
	let sawRelay = false;
	viewer = await connectTraceViewer(sturdyref, (record) => {
		if (record.kind !== "ocapn.session-opened") return;
		if (record.transport === "webrtc") sawWebrtc = true;
		if (record.transport === "keyed-relay") sawRelay = true;
	});

	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const trace = sturdyref;

	// Both members advertise `webrtc` identities and file signaling inboxes.
	deadline.at("joining Alice and Bob");
	const alice = await joinAs(browser, httpPort, "web-alice", trace);
	const bob = await joinAs(browser, httpPort, "web-bob", trace);

	// Alice redeems the introduction to Bob: her host's dial executor signals
	// through the directory, the DataChannel opens, and the DM rides it.
	deadline.at("opening Alice's direct line to Bob over WebRTC");
	await openDmTo(alice.tab, "web-bob");
	await pathSaid(alice.tab, factDmDirect, "webrtc");
	await send(alice.tab, DM_TEXT);

	// Bob renders it, the message crossed the DataChannel, with the room's
	// only contribution the signaling exchange.
	deadline.at("waiting for Bob to read Alice's line");
	await openDmTo(bob.tab, "web-alice");
	await awaitBubble(bob.tab, DM_TEXT, "Bob");
	await pathSaid(bob.tab, factDmDirect, "webrtc");

	// Bob replies over the very connection Alice's message arrived on.
	deadline.at("waiting for Alice to read Bob's reply");
	await send(bob.tab, REPLY_TEXT);
	await awaitBubble(alice.tab, REPLY_TEXT, "Alice");

	// Delivery alone is not transport evidence: an accidental relay selection
	// carries the same application message. The live product timeline must have
	// observed the actual browser-to-browser WebRTC session, and no keyed-relay
	// session may have stood in for it.
	deadline.at("waiting for the timeline to show the WebRTC session");
	await until(() => sawWebrtc, "the live timeline to observe a webrtc session after the messages arrived", 5_000);
	if (sawRelay) fail("the WebRTC proof opened a keyed-relay session");

	console.log(
		"PASS: two browser tabs direct-messaged over a WebRTC DataChannel — the give's " +
			"exporter locator named a bare webrtc designator, the redeeming host signaled " +
			"through the room directory (webrtc.connector), the keyed session opened over the " +
			"DataChannel off-room, and the reply rode back over the same arriving connection",
	);
} finally {
	deadline.clear();
	if (browser) await browser.close().catch(() => {});
	if (viewer) await viewer.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
