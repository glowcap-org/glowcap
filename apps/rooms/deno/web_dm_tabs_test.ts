// Two browser tabs direct-message each other by cold-dial rendezvous, end to
// end (ADR-0088 capability 5). Neither tab opens a listening socket, so neither
// can be dialed the ordinary way. Instead each registers its keyed identity and
// a held inbound socket at the relay web.ts runs, and advertises a `keyed-relay`
// locator to the room. When Alice direct-messages Bob, the room introduces her,
// her Host redeems the handoff give by *cold-dialing* Bob's identity through the
// relay's rendezvous leg, and the keyed OCapN session opens end to end between
// the two tabs through two byte-transparent relay legs — the room out of the
// message path, the relay blind to both. Bob answers over that same arriving
// connection (`currentSession`), so a tab that never listens still replies.
//
// This is the browser-to-browser cold-dial on a shared relay. It is not a
// general stranger cold-dial: the dialer is itself a browser (only a browser
// carries a `connectRendezvous` adapter today), and the `keyed-relay` locator
// names the identity, not the relay, so the redeemer reaches it only through the
// same relay it is already configured for. That honest scope is ADR-0088's.
//
// The room and both tabs run over plain TCP-through-relay (no iroh, no cargo):
// the tabs reach the room over `/relay?target=…` and reach each other over the
// relay's rendezvous WebSocket, so this whole proof is deno-only.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives
// (web.ts's room server is native), and a Playwright Chromium
// (`npx playwright install chromium && sudo npx playwright install-deps`).
// Run: `deno run --allow-all apps/rooms/deno/web_dm_tabs_test.ts`.

import { type Browser, type BrowserContext, chromium, type Page } from "playwright";

const WEB = new URL("./web.ts", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;
const ROOM = "lobby";
const DM_TEXT = "hi Bob, privately, from one browser tab to another";
const REPLY_TEXT = "got it Alice, replying over the same connection";

function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

function freePort(): number {
	const l = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (l.addr as Deno.NetAddr).port;
	l.close();
	return port;
}

async function waitForHttp(port: number): Promise<void> {
	for (let i = 0; i < 400; i++) {
		try {
			const res = await fetch(`http://127.0.0.1:${port}/locator`);
			await res.body?.cancel();
			if (res.status === 200) return;
		} catch {
			// not up / room not ready yet
		}
		await new Promise((r) => setTimeout(r, 50));
	}
	fail("web.ts did not answer with a room locator");
}

// Open a fresh, isolated tab (its own storage, so the two peers never share a
// nick or room in localStorage), join `ROOM` as `nick`, and wait until the
// composer is live — the signal that the keyed session to the room is up.
async function joinAs(browser: Browser, port: number, nick: string): Promise<{
	context: BrowserContext;
	tab: Page;
}> {
	const context = await browser.newContext();
	const tab = await context.newPage();
	tab.on("pageerror", (e) => console.error(`  [${nick} page error]`, e.message));
	await tab.goto(`http://127.0.0.1:${port}/`);
	await tab.fill("#nick", nick);
	await tab.fill("#room", ROOM);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 }).catch(async () => {
		const status = await tab.textContent("#status").catch(() => "?");
		fail(`${nick} never joined; status="${status}"`);
	});
	return { context, tab };
}

// Open a direct line to `peer` from `tab` by clicking their Message button in
// the members list — which appears only once `peer` is both in the room roster
// and advertised as DM-able (their `keyed-relay` registration landed).
async function openDmTo(tab: Page, peer: string): Promise<void> {
	const button = tab.locator(`#members li:has-text("${peer}") button.dm-btn`);
	await button.waitFor({ state: "visible", timeout: 60_000 });
	await button.click();
	await tab.waitForSelector("#line:not([disabled])", { timeout: 10_000 });
}

async function send(tab: Page, text: string): Promise<void> {
	await tab.fill("#line", text);
	await tab.press("#line", "Enter");
}

// Wait until a bubble carrying `text` is on screen in the active conversation.
async function awaitBubble(tab: Page, text: string, who: string): Promise<void> {
	await tab.waitForFunction(
		(t) => [...document.querySelectorAll(".bubble")].some((b) => b.textContent?.includes(t)),
		text,
		{ timeout: 30_000 },
	).catch(async () => {
		const log = (await tab.textContent("#log").catch(() => "?")) ?? "?";
		console.error(`  [${who} #log] ${JSON.stringify(log)}`);
		fail(`${who} never rendered "${text}"`);
	});
}

const deadline = setTimeout(() => fail("web-dm-tabs scenario timed out after 120s"), 120_000);

const httpPort = freePort();
const roomPort = freePort();

// web.ts serves the page and runs the room + relay over plain TCP (no
// `--transport=iroh`), so the whole proof is deno-only.
const web = new Deno.Command("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-net",
		"--allow-env",
		"--allow-run",
		WEB,
		String(httpPort),
		String(roomPort),
	],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
}).spawn();

let browser: Browser | null = null;
try {
	await waitForHttp(httpPort);

	browser = await chromium.launch({ args: ["--no-sandbox"] });

	// Alice joins first and opens the room; Bob joins it. Both register their
	// keyed identity at the relay and advertise a `keyed-relay` locator, so each
	// appears in the other's DM-able roster.
	const alice = await joinAs(browser, httpPort, "web-alice");
	const bob = await joinAs(browser, httpPort, "web-bob");

	// Alice cold-dials Bob: opening the DM redeems the room's introduction and
	// dials Bob's identity through the relay's rendezvous, off-room. The keyed
	// session opens tab-to-tab, and her line lands on Bob's giftable `dm`.
	await openDmTo(alice.tab, "web-bob");
	await send(alice.tab, DM_TEXT);

	// Bob renders it — the direct message reached a browser that never listens,
	// through the rendezvous, with the room off the message path.
	await openDmTo(bob.tab, "web-alice");
	await awaitBubble(bob.tab, DM_TEXT, "Bob");

	// Bob replies over the very connection Alice's message arrived on
	// (`currentSession` + the reply capability she handed over), never dialing
	// her back. His DM thread with Alice is already open, so the composer sends
	// on the back-channel.
	await send(bob.tab, REPLY_TEXT);

	// Alice renders Bob's reply in her DM thread with him — the bidirectional
	// completion of a cold-dial between two peers that both refuse a listener.
	await awaitBubble(alice.tab, REPLY_TEXT, "Alice");

	console.log(
		"PASS: two browser tabs direct-messaged each other by cold-dial rendezvous — one " +
			"registered its identity at the relay, the other redeemed a room introduction by " +
			"cold-dialing it, the keyed session opened tab-to-tab through the relay off-room, and " +
			"the reply rode back over the same arriving connection to a tab that never listens",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	try {
		web.kill();
	} catch {
		// already gone
	}
	await web.status;
}
Deno.exit(0);
