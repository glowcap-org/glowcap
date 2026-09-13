// Starting a direct message from somebody else's room.
//
// A reader who pastes another directory's locator into the join card ends up
// holding two: the one their own page serves, opened at boot to fill the rail,
// and the one they went to. Both are ordinary directories and the room works
// either way — but a `webrtc` locator names a designator and nothing else, so
// when that reader redeems an introduction, the connector dialing it has to ask
// the page which directory to signal through, and the page used to answer with
// whichever it had opened first. That is always its own. The offer went to a
// room that had never heard of the person being written to, which meant a
// visitor could receive direct messages from the room's own members and never
// start one — the failure looked like a direction, and was really about whose
// room it was.
//
// So this drives the half the same-directory proofs cannot see. Two room
// servers, and the member who starts the conversation is a visitor:
//
//   ada  is at her own page, in her own room.
//   bo   is at a different page, and joins ada's room by its locator.
//   bo   starts the direct message.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives
// (serve.ts's room server is native), and a Playwright Chromium.
// Run: `deno run --allow-all apps/rooms/test/web/dm_foreign_room_test.ts`.

import { type Browser, type BrowserContext, chromium, type Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { reapOwned, spawnOwned } from "../support/children.ts";
import { freePort } from "../support/rooms_server.ts";
import { awaitBubble, fail, openDmTo, reachDirectoryOnCard } from "../page/harness.ts";

import { WEB } from "../support/paths.ts";
const ROOT = new URL("../../../../", import.meta.url).pathname;
const ROOM = "lobby";
const DM_TEXT = "hi ada, I am writing from a page that is not yours";
const REPLY_TEXT = "got it bo, replying from mine";

// One page server with its own room and relay behind it. `reaches` is the room
// address this page's relay may dial besides its own: a relay dials iroh
// anywhere and cleartext TCP only where it is told, and the visitor's page is
// the one that has to reach the room it is visiting.
function serveRooms(httpPort: number, roomPort: number, reaches?: number): Deno.ChildProcess {
	return spawnOwned(WEB, {
		env: reaches === undefined ? {} : { GLOWCAP_RELAY_TCP_PEERS: `127.0.0.1:${reaches}` },
		args: [
			"--transport=tcp",
			String(httpPort),
			String(roomPort),
		],
		cwd: ROOT,
		stdout: "null",
		stderr: "inherit",
	});
}

// The directory locator a page is serving, once it has one — which is also how
// the page proves both halves are up.
async function roomLocator(port: number, who: string): Promise<string> {
	for (let i = 0; i < 400; i++) {
		try {
			const res = await fetch(`http://127.0.0.1:${port}/locator`);
			const said = (await res.text()).trim();
			if (res.status === 200 && said.length > 0) return said;
		} catch {
			// not up / room not ready yet
		}
		await new Promise((r) => setTimeout(r, 50));
	}
	fail(`${who} did not answer with a room locator`);
}

// Join `ROOM` as `nick` in a fresh, isolated tab. `directory` is the locator to
// paste into the join card, or null for the page's own — the difference this
// whole proof is about.
async function joinAs(
	browser: Browser,
	port: number,
	nick: string,
	directory: string | null,
): Promise<{ context: BrowserContext; tab: Page }> {
	const context = await browser.newContext();
	const tab = await context.newPage();
	tab.on("pageerror", (e) => console.error(`  [${nick} page error]`, e.message));
	tab.on("console", (m) => {
		if (m.type() === "error" || m.type() === "warning") {
			console.error(`  [${nick} console.${m.type()}]`, m.text());
		}
	});
	await tab.goto(`http://127.0.0.1:${port}/?dm=webrtc`);
	await establishLocalSession(tab);
	if (directory !== null) await tab.fill("#locator", directory);
	await tab.fill("#nick", nick);
	await reachDirectoryOnCard(tab);
	await tab.fill("#room", ROOM);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 }).catch(async () => {
		const status = await tab.textContent("#status").catch(() => "?");
		fail(`${nick} never joined; status="${status}"`);
	});
	return { context, tab };
}

async function send(tab: Page, text: string): Promise<void> {
	await tab.fill("#line", text);
	await tab.press("#line", "Enter");
}

const deadline = setTimeout(() => fail("web-dm-foreign-room scenario timed out after 180s"), 180_000);

const hostHttp = freePort();
const hostRoom = freePort();
const visitorHttp = freePort();
const visitorRoom = freePort();

serveRooms(hostHttp, hostRoom);
serveRooms(visitorHttp, visitorRoom, hostRoom);

let browser: Browser | null = null;
try {
	const hostDirectory = await roomLocator(hostHttp, "ada's page");
	await roomLocator(visitorHttp, "bo's page");

	browser = await chromium.launch({ args: ["--no-sandbox"] });

	// ada is at home: one directory, the one she is in.
	const ada = await joinAs(browser, hostHttp, "web-ada", null);
	// bo is a visitor: his own page's directory is open, and he joins ada's.
	const bo = await joinAs(browser, visitorHttp, "web-bo", hostDirectory);

	// The room they now share is ada's, so bo has to be in her members list for
	// this to be about direct messages at all.
	await bo.tab.locator(`#members li:has-text("web-ada")`).waitFor({ state: "visible", timeout: 60_000 })
		.catch(() => fail("bo joined ada's room but never saw her in it"));

	// And the precondition this proof exists for: bo is holding two directories,
	// his own page's and ada's. Holding one would make this the scenario the
	// sibling proofs already run, and a green result here would mean nothing.
	// The rail says so on its own: a row names the directory it is on only while
	// a tab holds more than one, since with one there is nothing to tell apart.
	await bo.tab.locator("#roomList .rwhere").first().waitFor({ state: "attached", timeout: 30_000 })
		.catch(async () => {
			const rail = (await bo.tab.textContent("#roomList").catch(() => "?")) ?? "?";
			fail(`bo is holding one directory, so he is not a visitor; the rail says ${JSON.stringify(rail)}`);
		});

	// The half that was broken: the visitor starts it. His redeem signals
	// through the directory that introduced ada, not through his own page's.
	await openDmTo(bo.tab, "web-ada");
	await send(bo.tab, DM_TEXT);

	await openDmTo(ada.tab, "web-bo");
	await awaitBubble(ada.tab, DM_TEXT, "ada");

	// And the direction that always worked still does, over the same channel.
	await send(ada.tab, REPLY_TEXT);
	await awaitBubble(bo.tab, REPLY_TEXT, "bo");

	console.log(
		"PASS: a visitor holding two directories started a direct message in the room " +
			"he had joined — the redeem signaled through the directory that introduced the " +
			"member rather than through his own page's, the DataChannel opened, and the " +
			"reply rode back over it",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
