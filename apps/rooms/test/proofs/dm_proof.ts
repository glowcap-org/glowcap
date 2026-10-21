import { spawnWeb } from "../support/web_front.ts";
// The rooms page sends a direct message, end to end, from a real browser. A
// headless Chromium loads the shipped page, joins a room, and messages a member
// privately, the three-party handoff `demo-rooms-dm-iroh` proves, with the
// browser as the recipient. The browser asks the room to introduce it, redeems
// the handoff-give by dialing the member through serve.ts's `/relay` iroh path,
// and its message lands on the member's own endpoint, never through the room.
//
// The member (Bob) is a host iroh peer in this process, so its inbox is a
// local array we can assert on. serve.ts runs the room + relay over iroh
// (`--transport=iroh`), so the relay can dial Bob's iroh node.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the installed archives and
// the iroh sidecar (`cargo`), and a Playwright Chromium. Run:
//   deno run --allow-all apps/rooms/test/web/dm_test.ts

import { chromium } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { type Session, TRANSPORT_IROH } from "@glowcap/runtime";

import { recordingReplyDm } from "../../lib/dm_reply.ts";
import { inboxPublisher } from "../../lib/dm_inbox.ts";
import * as iroh from "@glowcap/iroh";
import { Directory, Room } from "../../lib/room/client.ts";
import { enterOrOpen } from "../../lib/enter_room.ts";
import { dial, roomsHost } from "../../lib/locator.ts";
import { openRoomsRuntime } from "../../lib/runtime.ts";
import { reapOwned } from "../support/children.ts";
import { freePort } from "../support/rooms_server.ts";
import { fail, until } from "../page/harness.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;
const ROOM = "lobby";
const DM_TEXT = "hi Bob, privately, from a browser";
const REPLY_TEXT = `got your DM: ${DM_TEXT}`;

async function locatorFrom(port: number): Promise<string> {
	for (let i = 0; i < 400; i++) {
		try {
			const res = await fetch(`http://127.0.0.1:${port}/locator`);
			const text = (await res.text()).trim();
			if (res.status === 200 && text.length > 0) return text;
		} catch {
			// not up yet status-allow: pending state or quoted runtime label
		}
		await new Promise((r) => setTimeout(r, 50));
	}
	fail("serve.ts did not answer with a room locator");
}

const deadline = setTimeout(() => fail("web-dm scenario timed out after 120s"), 120_000);
const httpPort = freePort();

// serve.ts hosts the page and an iroh room + relay; its room server picks its own
// iroh endpoint (no port to pin).
spawnWeb({
	args: ["--transport=tcp", "--transport=iroh", "--reachability=direct", String(httpPort)],
	cwd: ROOT,
	stdout: "piped",
	stderr: "inherit",
});

// Bob: a host iroh member in this process. He mints one Host publication inbox per peer
// the directory asks him for, served on his own iroh endpoint (the redeem
// target), joins the room, and registers his iroh locator.
const bobInbox: string[] = [];
const bobSeed = crypto.getRandomValues(new Uint8Array(32));
const bobHost = roomsHost(bobSeed);
// A Host publication answers the browser over the connection the DM arrived on
// (`currentSession()`), sending to the reply inbox the browser hosts on that same
// connection. Bob never dials the browser, which cannot be dialed, the shared
// `recordingReplyDm` owns that receiver primitive.
const dmFor = (_peer: string) => recordingReplyDm(bobInbox, (text) => `got your DM: ${text}`);
const bobEndpoint = await iroh.listen(
	{ reachability: iroh.Reachability.Direct },
	{ host: bobHost },
);
const bobRuntime = await openRoomsRuntime({
	host: bobHost,
	installedTransport: TRANSPORT_IROH,
	iroh: { reachability: iroh.Reachability.Direct },
});
const bobAccepted = new Map<Session, Promise<void>>();
const bobAccepting = (async () => {
	for await (const session of bobEndpoint) {
		// A settled serve loop does not release its Session wrapper. Keep every
		// accepted owner until teardown closes it explicitly, or the shared driver
		// loop reaches sidecar release with a live host session still registered.
		const serving = session.serve().catch(() => {});
		bobAccepted.set(session, serving);
	}
})();
void bobAccepting.catch(() => {});

let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
let bobDirectory: Directory | null = null;
try {
	const roomUri = await locatorFrom(httpPort);

	await until(() => bobEndpoint.directAddresses.length > 0, "Bob's iroh direct addresses");
	const bobLocator = bobEndpoint.uri;

	// Bob joins the room and registers for direct messages, over iroh, keyed to
	// his own Host so the inbox he publishes giftably is the one a redeem
	// withdraws.
	const bobDir = await Directory.connect(roomUri, (locator) => dial(locator, bobRuntime)).catch((error) =>
		fail(
			`Bob could not dial the room at ${JSON.stringify(roomUri)} with direct addresses ` +
				`${JSON.stringify(bobEndpoint.directAddresses)}: ${
					error instanceof Error ? error.message : String(error)
				}`,
		)
	);
	bobDirectory = bobDir;
	const bobRoomRef = await enterOrOpen(bobDir, ROOM);
	await Room.subscribe(bobDir.session, bobRoomRef, "bob");
	const bobOfferer = inboxPublisher(bobHost).offerer({ dir: () => bobDir, behaviorFor: dmFor });
	await bobDir.register("bob", bobLocator, { onMintInboxFor: bobOfferer.offer });

	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const tab = await browser.newPage();
	tab.on("pageerror", (e) => console.error("  [page error]", e.message));

	await tab.goto(`http://127.0.0.1:${httpPort}/`);
	await establishLocalSession(tab);
	await tab.fill("#nick", "web-alice");
	await tab.fill("#room", ROOM);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 }).catch(async () => {
		const status = await tab.textContent("#status").catch(() => "?");
		fail(`join never completed; status="${status}"`);
	});

	// The member pane gives Bob a direct-line button once the directory's replayed
	// `registered` delta marks him DM-able. Click it to open a direct line.
	const bobMessage = tab.locator('#members li:has-text("bob") button.dm-btn');
	await bobMessage.waitFor({ state: "visible", timeout: 30_000 });
	await bobMessage.click();

	// Send the DM: this redeems the introduction and dials Bob's iroh endpoint
	// through the relay, straight to him.
	await tab.waitForFunction(
		() =>
			(document.getElementById("roomName")?.textContent ?? "").trim() === "bob" &&
			(document.getElementById("line") as HTMLTextAreaElement | null)?.disabled === false,
		null,
		{ timeout: 30_000 },
	);
	await tab.fill("#line", DM_TEXT);
	await tab.press("#line", "Enter");

	// Bob receives it on his own endpoint, the room never carried it.
	await until(() => bobInbox.includes(DM_TEXT), "Bob to receive the browser's direct message");

	// Bob replies over the same direct connection to the reply inbox the browser
	// hosts on it, and the page paints it in the DM thread, the member reached a
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
	await bobDirectory?.close();
	await bobEndpoint.close();
	await bobAccepting.catch(() => {});
	const accepted = [...bobAccepted.entries()];
	await Promise.all(accepted.map(([session]) => session.close()));
	await Promise.all(accepted.map(([, serving]) => serving));
	await bobRuntime.close();
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
