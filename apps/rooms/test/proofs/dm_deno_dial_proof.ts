import { spawnWeb } from "../support/web_front.ts";
// A Deno peer direct-messages a browser member by cold-dial rendezvous, end
// to end (ADR-0088 capability 5, the Deno-dialer row). The browser tab opens
// no listening socket, so it cannot be dialed the ordinary way: it registers
// its durable identity and a held inbound socket at the relay serve.ts runs, and
// advertises a `noise-relay` locator to the room. The Deno peer, a plain
// Deno process on the dlopen runtime, no browser anywhere near its side, joins
// the same room, redeems the room's introduction, and its Host cold-dials the
// browser's identity through the explicitly composed relay provider. The
// Noise-sealed OCapN session opens end to end between
// the Deno process and the tab, the room out of the message path, the relay
// blind to both. The tab answers over that same arriving connection
// (`currentSession`), so a tab that never listens still replies.
//
// This is the general-stranger half `rooms-web-dm-tabs` leaves open: the
// dialer is not a browser, so nothing browser-shaped carries the rendezvous,
// the generic rendezvous plan in the shared runtime opens the WebSocket channel
// the dialing Host was configured for, on any runtime. The remaining honest
// scope is unchanged: the locator names the identity, not the relay, so the
// dialer reaches it only through a relay it is already configured for.
//
// The room, the tab, and the Deno peer all run over plain TCP (no iroh, no
// cargo): the tab reaches the room over `/relay?target=…`, the Deno peer
// dials the room's TCP locator directly, and the cold-dial bridges through
// `/relay?rendezvous=…`.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the built archives
// (serve.ts's room server and the Deno peer dlopen them), and a Playwright
// Chromium (the devcontainer image ships one).
// Run: `deno run --allow-all apps/rooms/test/web/dm_deno_dial_proof.ts`.

import { type Browser, chromium, type Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { formatPeerUri, Runtime, TRANSPORT_NOISE_RELAY } from "@glowcap/runtime";
import * as relay from "@glowcap/relay";
import * as tcp from "@glowcap/tcp";
import { dial, roomsHost } from "../../lib/locator.ts";
import { enterOrOpen } from "../../lib/enter_room.ts";
import { DirectMessage, Directory, Room } from "../../lib/room/client.ts";
import { reapOwned } from "../support/children.ts";
import { freePort, waitForHttp } from "../support/rooms_server.ts";
import { awaitBubble, fail, openDmTo, until } from "../page/harness.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;
const ROOM = "lobby";
const DM_TEXT = "hi web-bob, from a Deno peer that cold-dialed your identity";
const REPLY_TEXT = "got it deno-carol, replying over your arriving connection";

// Join `ROOM` as `nick` in a fresh tab and wait until the composer is live,
// the signal that the room session is up and the tab has begun
// advertising its rendezvous identity.
async function joinAs(browser: Browser, port: number, nick: string): Promise<Page> {
	const tab = await (await browser.newContext()).newPage();
	tab.on("pageerror", (e) => console.error(`  [${nick} page error]`, e.message));
	await tab.goto(`http://127.0.0.1:${port}/?dm=relay`);
	await establishLocalSession(tab);
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
async function send(tab: Page, text: string): Promise<void> {
	await tab.fill("#line", text);
	await tab.press("#line", "Enter");
}

// Wait until a bubble carrying `text` is on screen in the active conversation.
const deadline = setTimeout(
	() => fail("web-dm-deno-dial scenario timed out after 120s"),
	120_000,
);

const httpPort = freePort();
const roomPort = freePort();

// serve.ts serves the page and runs the room + relay over plain TCP (no
// `--transport=iroh`), so the proof needs no cargo.
spawnWeb({
	args: ["--transport=tcp", String(httpPort), String(roomPort)],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
});

let browser: Browser | null = null;
let carolDirectory: Directory | null = null;
let carolRuntime: Runtime | null = null;
try {
	await waitForHttp(httpPort);

	browser = await chromium.launch({ args: ["--no-sandbox"] });

	// The browser member joins first. Joining registers its durable identity at
	// the relay's rendezvous and advertises a `noise-relay` locator to the room,
	// so it appears in the DM-able roster.
	const bob = await joinAs(browser, httpPort, "web-bob");

	// The Deno peer composes TCP for the room and noise-relay for direct dials.
	const carolHost = roomsHost();
	const runtime = await Runtime.open({
		adoptHost: carolHost,
		providers: [
			tcp.provider(),
			relay.provider({ relayUrl: `ws://127.0.0.1:${httpPort}/relay` }),
		],
	});
	carolRuntime = runtime;
	const roomLocator = (await (await fetch(`http://127.0.0.1:${httpPort}/locator`)).text()).trim();
	const carol = await Directory.connect(roomLocator, (locator) => dial(locator, runtime));
	carolDirectory = carol;
	const roomRef = await enterOrOpen(carol, ROOM);
	await Room.subscribe(carol.session, roomRef, "deno-carol");
	// Register a key, not an address: the sender never listens, and the reply
	// must ride the connection her DM arrives on.
	await carol.register(
		"deno-carol",
		formatPeerUri(TRANSPORT_NOISE_RELAY, carolHost.designator()),
	);

	// Wait until the directory says web-bob is introducible.
	const dmable = new Set<string>();
	await carol.watch((event) => {
		if (event.kind === "registered") dmable.add(event.name.toLowerCase());
	});
	await until(() => dmable.has("web-bob"), "web-bob never became DM-able");

	// Cold-dial: opening the DM redeems the room's introduction, and the Host
	// dials web-bob's identity through the relay rendezvous, off-room. The
	// noise-relay session opens Deno-to-tab; her line lands on the tab's Host publication.
	const replies: string[] = [];
	const line = await DirectMessage.open(carol, "web-bob", {
		ready: (session, reply) => session.release(reply),
		message: (text) => {
			replies.push(text);
			return null;
		},
	});
	await line.say(DM_TEXT);

	// The tab renders it, the message reached a browser that never listens,
	// sent by a peer that is not a browser.
	await openDmTo(bob, "deno-carol");
	await awaitBubble(bob, DM_TEXT, "Bob");

	// The tab replies over the very connection the DM arrived on
	// (`currentSession` + the reply capability the sender handed it), it
	// cannot dial deno-carol back, and it never needs to.
	await send(bob, REPLY_TEXT);
	await until(() => replies.includes(REPLY_TEXT), "deno-carol never received the reply");

	console.log(
		"PASS: a Deno peer cold-dialed a browser member by relay rendezvous — the tab " +
			"registered its durable identity, the Deno Host redeemed a room introduction and " +
			"bridged onto the held socket through its configured relay provider, the noise-relay " +
			"session opened sealed Deno-to-tab off-room, and the reply rode back over the same " +
			"arriving connection to a sender that never listens",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	await carolDirectory?.close().catch(() => {});
	await carolRuntime?.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
