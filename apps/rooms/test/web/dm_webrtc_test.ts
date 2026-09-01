// Two browser tabs direct-message each other over a WebRTC DataChannel, the
// room carrying only the signaling (ADR-0089, the live handoff-redeem proof).
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
// This is the composition ADR-0089 left open: a `desc:handoff-give` whose
// exporter locator names a `webrtc` designator, redeemed end to end. The
// locator carries no signaling route; the dialing host's authority is the
// directory it already reaches, installed as `webrtc.connector`'s signaling,
// the same configured posture the rendezvous cold dial holds.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives
// (serve.ts's room server is native), and a Playwright Chromium
// (the devcontainer image ships one).
// Run: `deno run --allow-all apps/rooms/test/web/dm_webrtc_test.ts`.

import { type Browser, type BrowserContext, chromium, type Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { reapOwned, spawnOwned } from "../support/children.ts";
import { connectVizViewer, scrapeVizSturdyref, vizMemorySeed } from "../viz/viewer.ts";
import { freePort, waitForHttp } from "../support/rooms_server.ts";
import { awaitBubble, fail, openDmTo } from "../support/page.ts";

const WEB = new URL("../../web/serve.ts", import.meta.url).pathname;
const ROOT = new URL("../../../../", import.meta.url).pathname;
const ROOM = "lobby";
const DM_TEXT = "hi Bob, privately, over a DataChannel the room only signaled";
const REPLY_TEXT = "got it Alice, replying over the same channel";

// Join `ROOM` as `nick` in a fresh, isolated tab, in webrtc DM mode, and wait
// until the composer is live — the signal that the keyed session to the room
// is up and the tab is advertising its `webrtc` identity.
async function joinAs(
	browser: Browser,
	port: number,
	nick: string,
	vizSeed: { key: string; value: string },
): Promise<{
	context: BrowserContext;
	tab: Page;
}> {
	const context = await browser.newContext();
	await context.addInitScript(({ key, value }) => localStorage.setItem(key, value), vizSeed);
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

// Wait until a bubble carrying `text` is on screen in the active conversation.
const deadline = setTimeout(() => fail("web-dm-webrtc scenario timed out after 28s"), 28_000);

const httpPort = freePort();
const roomPort = freePort();
const vizPort = freePort();

// serve.ts serves the page and runs the room + relay over plain TCP (no
// `--transport=iroh`); the DM channel itself is WebRTC, so no cargo either.
const web = spawnOwned("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-write",
		"--allow-net",
		"--allow-env",
		"--allow-run",
		WEB,
		String(httpPort),
		String(roomPort),
	],
	cwd: ROOT,
	env: { PANCAKE_ROOMS_VIZ: "1", PANCAKE_ROOMS_VIZ_PORT: String(vizPort) },
	stdout: "piped",
	stderr: "piped",
});
const vizRef = scrapeVizSturdyref(web.stderr);

let browser: Browser | null = null;
let viewer: { close(): Promise<void> } | null = null;
try {
	await waitForHttp(httpPort);
	const sturdyref = await vizRef;
	let sawWebrtc = false;
	let sawRelay = false;
	viewer = await connectVizViewer(sturdyref, (record) => {
		if (record.kind !== "ocapn.session-opened") return;
		if (record.transport === "webrtc") sawWebrtc = true;
		if (record.transport === "keyed-relay") sawRelay = true;
	});

	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const vizSeed = vizMemorySeed(httpPort, sturdyref);

	// Both members advertise `webrtc` identities and file signaling inboxes.
	const alice = await joinAs(browser, httpPort, "web-alice", vizSeed);
	const bob = await joinAs(browser, httpPort, "web-bob", vizSeed);

	// Alice redeems the introduction to Bob: her host's dial executor signals
	// through the directory, the DataChannel opens, and the DM rides it.
	await openDmTo(alice.tab, "web-bob");
	await send(alice.tab, DM_TEXT);

	// Bob renders it — the message crossed the DataChannel, with the room's
	// only contribution the signaling exchange.
	await openDmTo(bob.tab, "web-alice");
	await awaitBubble(bob.tab, DM_TEXT, "Bob");

	// Bob replies over the very connection Alice's message arrived on.
	await send(bob.tab, REPLY_TEXT);
	await awaitBubble(alice.tab, REPLY_TEXT, "Alice");

	// Delivery alone is not transport evidence: an accidental relay selection
	// carries the same application message. The live product timeline must have
	// observed the actual browser-to-browser WebRTC session, and no keyed-relay
	// session may have stood in for it.
	const until = Date.now() + 5_000;
	while (!sawWebrtc && Date.now() < until) {
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
	if (!sawWebrtc) fail("the messages arrived but the live timeline observed no webrtc session");
	if (sawRelay) fail("the WebRTC proof opened a keyed-relay session");

	console.log(
		"PASS: two browser tabs direct-messaged over a WebRTC DataChannel — the give's " +
			"exporter locator named a bare webrtc designator, the redeeming host signaled " +
			"through the room directory (webrtc.connector), the keyed session opened over the " +
			"DataChannel off-room, and the reply rode back over the same arriving connection",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	if (viewer) await viewer.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
