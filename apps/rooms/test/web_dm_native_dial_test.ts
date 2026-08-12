// A native peer direct-messages a browser member by cold-dial rendezvous, end
// to end (ADR-0088 capability 5, the native-dialer row). The browser tab opens
// no listening socket, so it cannot be dialed the ordinary way: it registers
// its durable identity and a held inbound socket at the relay serve.ts runs, and
// advertises a `noise-relay` locator to the room. The native peer — a plain
// Deno process on the dlopen stack, no browser anywhere near its side — joins
// the same room, redeems the room's introduction, and its Host cold-dials the
// browser's identity through the relay's rendezvous leg, configured with
// `Host.setRendezvousUrl`. The keyed OCapN session opens end to end between
// the native process and the tab, the room out of the message path, the relay
// blind to both. The tab answers over that same arriving connection
// (`currentSession`), so a tab that never listens still replies.
//
// This is the general-stranger half `rooms-web-dm-tabs` leaves open: the
// dialer is not a browser, so nothing browser-shaped carries the rendezvous —
// the generic rendezvous plan in the shared stack opens the WebSocket channel
// the dialing Host was configured for, on any runtime. The remaining honest
// scope is unchanged: the locator names the identity, not the relay, so the
// dialer reaches it only through a relay it is already configured for.
//
// The room, the tab, and the native peer all run over plain TCP (no iroh, no
// cargo): the tab reaches the room over `/relay?target=…`, the native peer
// dials the room's TCP locator directly, and the cold-dial bridges through
// `/relay?rendezvous=…`.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives
// (serve.ts's room server and the native peer dlopen them), and a Playwright
// Chromium (the devcontainer image ships one).
// Run: `deno run --allow-all apps/rooms/test/web_dm_native_dial_test.ts`.

import { type Browser, chromium, type Page } from "playwright";
import { formatPeerUri, TRANSPORT_KEYED_RELAY } from "@pancake/stack";
import { dial, roomsHost } from "../lib/locator.ts";
import { enterOrOpen } from "../lib/enter_room.ts";
import { DirectMessage, Directory, Room } from "../lib/room_client.ts";

const WEB = new URL("../web/serve.ts", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;
const ROOM = "lobby";
const DM_TEXT = "hi web-bob, from a native peer that cold-dialed your identity";
const REPLY_TEXT = "got it native-carol, replying over your arriving connection";

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
	fail("serve.ts did not answer with a room locator");
}

async function until(ready: () => boolean, what: string, ms = 30_000): Promise<void> {
	const start = Date.now();
	while (!ready()) {
		if (Date.now() - start > ms) fail(what);
		await new Promise((r) => setTimeout(r, 50));
	}
}

// Join `ROOM` as `nick` in a fresh tab and wait until the composer is live —
// the signal that the room session is up and the tab has begun
// advertising its rendezvous identity.
async function joinAs(browser: Browser, port: number, nick: string): Promise<Page> {
	const tab = await (await browser.newContext()).newPage();
	tab.on("pageerror", (e) => console.error(`  [${nick} page error]`, e.message));
	await tab.goto(`http://127.0.0.1:${port}/`);
	await tab.fill("#nick", nick);
	await tab.fill("#room", ROOM);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 }).catch(async () => {
		const status = await tab.textContent("#status").catch(() => "?");
		fail(`${nick} never joined; status="${status}"`);
	});
	return tab;
}

// Open the direct line to `peer` from the tab's members list. The button is
// there only once `peer` is both in the roster and advertised as DM-able.
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

const deadline = setTimeout(
	() => fail("web-dm-native-dial scenario timed out after 120s"),
	120_000,
);

const httpPort = freePort();
const roomPort = freePort();

// serve.ts serves the page and runs the room + relay over plain TCP (no
// `--transport=iroh`), so the proof needs no cargo.
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

	// The browser member joins first. Joining registers its durable identity at
	// the relay's rendezvous and advertises a `noise-relay` locator to the room,
	// so it appears in the DM-able roster.
	const bob = await joinAs(browser, httpPort, "web-bob");

	// The native peer: one Host whose rendezvous mapping names the relay's
	// bridge leg — deployment configuration, the same fact the page wires for
	// its own tabs. Everything else is the ordinary native rooms client.
	const carolHost = roomsHost();
	carolHost.setRendezvousUrl((id) =>
		`ws://127.0.0.1:${httpPort}/relay?rendezvous=${encodeURIComponent(id)}`
	);
	const roomLocator = (await (await fetch(`http://127.0.0.1:${httpPort}/locator`)).text()).trim();
	const carol = await Directory.connect(roomLocator, (l) => dial(l, carolHost));
	const roomRef = await enterOrOpen(carol, ROOM);
	await Room.subscribe(carol.session, roomRef, "native-carol");
	// Register a key, not an address: the sender never listens, and the reply
	// must ride the connection her DM arrives on.
	await carol.register(
		"native-carol",
		formatPeerUri(TRANSPORT_KEYED_RELAY, carolHost.designator()),
	);

	// Wait until the directory says web-bob is introducible.
	const dmable = new Set<string>();
	await carol.watch((event) => {
		if (event.kind === "registered") dmable.add(event.name.toLowerCase());
	});
	await until(() => dmable.has("web-bob"), "web-bob never became DM-able");

	// Cold-dial: opening the DM redeems the room's introduction, and the Host
	// dials web-bob's identity through the relay rendezvous, off-room. The
	// Noise-sealed session opens native-to-tab; her line lands on the tab's giftable.
	const replies: string[] = [];
	const line = await DirectMessage.open(carol, "web-bob", (text) => replies.push(text));
	await line.say(DM_TEXT);

	// The tab renders it — the message reached a browser that never listens,
	// sent by a peer that is not a browser.
	await openDmTo(bob, "native-carol");
	await awaitBubble(bob, DM_TEXT, "Bob");

	// The tab replies over the very connection the DM arrived on
	// (`currentSession` + the reply capability the sender handed it) — it
	// cannot dial native-carol back, and it never needs to.
	await send(bob, REPLY_TEXT);
	await until(() => replies.includes(REPLY_TEXT), "native-carol never received the reply");

	console.log(
		"PASS: a native peer cold-dialed a browser member by relay rendezvous — the tab " +
			"registered its durable identity, the native Host redeemed a room introduction and " +
			"bridged onto the held socket through its configured rendezvous mapping, the Noise-sealed " +
			"session opened native-to-tab off-room, and the reply rode back over the same " +
			"arriving connection to a sender that never listens",
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
