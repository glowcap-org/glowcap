// The rooms page sends a direct message, end to end, from a real browser. A
// headless Chromium loads the shipped page, joins a room, and messages a member
// privately — the three-party handoff `demo-rooms-dm-iroh` proves, now with the
// browser as the recipient. The browser asks the room to introduce it, redeems
// the handoff-give by dialing the member through web.ts's `/relay` iroh path,
// and its message lands on the member's own endpoint, never through the room.
//
// The member (Bob) is a native iroh peer in this process, so its inbox is a
// local array we can assert on. web.ts runs the room + relay over iroh
// (`--transport=iroh`), so the relay can dial Bob's iroh node.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives and
// the iroh sidecar (`cargo`), and a Playwright Chromium. Run:
//   deno run --allow-all apps/rooms/deno/web_dm_test.ts

import { chromium } from "playwright";
import { Host } from "@pancake/stack";
import { recordingReplyDm } from "../lib/dm_reply.ts";
import { listenIroh, Reachability } from "@pancake/iroh";
import { Directory, Room } from "../lib/room_client.ts";
import { enterOrOpen } from "./lib/enter_room.ts";
import { dial } from "./lib/locator.ts";

const WEB = new URL("./web.ts", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;
const ROOM = "lobby";
const DM_TEXT = "hi Bob, privately, from a browser";
const REPLY_TEXT = `got your DM: ${DM_TEXT}`;

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

async function until(ready: () => boolean, what: string, ms = 30_000): Promise<void> {
	const deadline = Date.now() + ms;
	while (!ready()) {
		if (Date.now() > deadline) fail(`timed out waiting for ${what}`);
		await new Promise((r) => setTimeout(r, 50));
	}
}

async function locatorFrom(port: number): Promise<string> {
	for (let i = 0; i < 400; i++) {
		try {
			const res = await fetch(`http://127.0.0.1:${port}/locator`);
			const text = (await res.text()).trim();
			if (res.status === 200 && text.length > 0) return text;
		} catch {
			// not up yet
		}
		await new Promise((r) => setTimeout(r, 50));
	}
	fail("web.ts did not answer with a room locator");
}

const deadline = setTimeout(() => fail("web-dm scenario timed out after 120s"), 120_000);
const httpPort = freePort();

// web.ts hosts the page and an iroh room + relay; its room server picks its own
// iroh endpoint (no port to pin).
const web = new Deno.Command("deno", {
	args: [
		"run",
		"--allow-ffi",
		"--allow-read",
		"--allow-net",
		"--allow-env",
		"--allow-run",
		WEB,
		"--transport=iroh",
		String(httpPort),
	],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
}).spawn();

// Bob: a native iroh member in this process. Publishes `dm` giftably (served on
// his own iroh endpoint, the redeem target), joins the room, and registers his
// iroh locator so the directory can introduce him.
const bobInbox: string[] = [];
const bobSeed = crypto.getRandomValues(new Uint8Array(32));
const bobHost = new Host(bobSeed);
// Bob is a host-wide giftable, so it answers the browser over the connection the
// DM arrived on (`currentSession()`), sending to the reply inbox the browser
// hosts on that same connection. Bob never dials the browser, which cannot be
// dialed — the shared `recordingReplyDm` owns that receiver primitive.
const dmBehavior = recordingReplyDm(bobInbox, "bob", (text) => `got your DM: ${text}`);
bobHost.publishGiftable("dm", dmBehavior);
const bobEndpoint = listenIroh(Reachability.Direct, bobSeed, bobHost);
(async () => {
	for await (const session of bobEndpoint) session.serve().catch(() => {});
})();

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
try {
	const roomUri = await locatorFrom(httpPort);

	await until(() => bobEndpoint.directAddresses.length > 0, "Bob's iroh direct addresses");
	const bobLocator = bobEndpoint.uri;

	// Bob joins the room and registers for direct messages, over iroh, keyed to
	// his own Host so `register` can fetch his `dm` on the room session.
	const bobDir = await Directory.connect(roomUri, (l) => dial(l, bobHost));
	bobDir.session.publish("dm", dmBehavior);
	const bobRoomRef = await enterOrOpen(bobDir, ROOM);
	await Room.subscribe(bobDir.session, bobRoomRef, "bob");
	await bobDir.register("bob", bobLocator);

	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const tab = await browser.newPage();
	tab.on("pageerror", (e) => console.error("  [page error]", e.message));

	await tab.goto(`http://127.0.0.1:${httpPort}/`);
	await tab.fill("#nick", "web-alice");
	await tab.fill("#room", ROOM);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 }).catch(async () => {
		const status = await tab.textContent("#status").catch(() => "?");
		fail(`join never completed; status="${status}"`);
	});

	// The member pane shows Bob with a Message button once the directory's
	// replayed `registered` delta marks him DM-able. Click it to open a direct line.
	const bobMessage = tab.locator('#members li:has-text("bob") button.dm-btn');
	await bobMessage.waitFor({ state: "visible", timeout: 30_000 });
	await bobMessage.click();

	// Send the DM: this redeems the introduction and dials Bob's iroh endpoint
	// through the relay, straight to him.
	await tab.waitForSelector("#line:not([disabled])", { timeout: 10_000 });
	await tab.fill("#line", DM_TEXT);
	await tab.press("#line", "Enter");

	// Bob receives it on his own endpoint — the room never carried it.
	await until(() => bobInbox.includes(DM_TEXT), "Bob to receive the browser's direct message");

	// Bob replies over the same direct connection to the reply inbox the browser
	// hosts on it, and the page paints it in the DM thread — the member reached a
	// browser that never listens, the bidirectional completion of the handoff.
	const replyDeadline = Date.now() + 20_000;
	while (!((await tab.textContent("#log").catch(() => "")) ?? "").includes(REPLY_TEXT)) {
		if (Date.now() > replyDeadline) {
			fail(`the browser never rendered Bob's reply "${REPLY_TEXT}"`);
		}
		await new Promise((r) => setTimeout(r, 100));
	}

	console.log(
		"PASS: the rooms page sent a direct message from a real browser and rendered the member's " +
			"reply — introduced by the room, redeemed by dialing the member's iroh endpoint through " +
			"/relay off-room, and the member answered back over that same connection to a browser " +
			"that never listens",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	bobEndpoint.close();
	try {
		web.kill();
	} catch {
		// already gone
	}
	await web.status;
}
Deno.exit(0);
