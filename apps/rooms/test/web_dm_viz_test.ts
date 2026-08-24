// A direct message between two browser tabs appears on the live timeline.
//
// This is the whole point of the publishing half of the feed. A DM is a session
// between two members, formed by three-party introduction and held on the
// members' own hosts; the room server never carries a byte of it, so the room's
// own trace can never show it. Each tab publishes its own trace to the shared
// endpoint instead, on a socket that only goes one way — telemetry converges,
// the conversation stays direct.
//
// What this proves, watching the endpoint as a viewer would:
//
//   - the tabs' DM session reaches the feed at all, with the room off its path;
//   - the two producers' identical local session ids stay apart, because the
//     endpoint scopes each by the connection it arrived on;
//   - both tabs report the same session id for the DM, and the same tag on each
//     of its messages, which is what lets a viewer draw the conversation once
//     from the two ends watching it;
//   - the room's own session and the tabs' sessions arrive on one feed;
//   - what a tab publishes is telemetry and not contents: its message records
//     carry the verb, the byte count, and the tag that folds the two ends
//     together, and none of them carries the bytes. A DM's other end never
//     agreed to appear on a shared timeline, so this tab does not put their
//     words there.
//
// The DM itself is `web_dm_tabs_test.ts`'s scenario, run here for its
// telemetry; that test owns the claim that the message arrives.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives,
// and a Playwright Chromium (the devcontainer image ships one).
// Run: `deno run --allow-all apps/rooms/test/web_dm_viz_test.ts`.

import { type Browser, chromium, type Page } from "playwright";
import { connectVizViewer, scrapeVizSturdyref, vizMemorySeed } from "./viz_viewer.ts";
import { reapOwned, spawnOwned } from "./support/children.ts";

const WEB = new URL("../web/serve.ts", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;
const ROOM = "lobby";
const DM_TEXT = "hello over the direct line, and onto the timeline";

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

/** A viewer on the endpoint, exactly as ocapnviz connects: the WebSocket is
 * only the byte channel, and records arrive through an inbox capability after
 * enlivening the sturdyref the server announced. */
type Record_ = Record<string, unknown>;
async function watch(sturdyref: string): Promise<Record_[]> {
	const seen: Record_[] = [];
	await connectVizViewer(sturdyref, (record) => seen.push(record));
	return seen;
}

async function joinAs(
	browser: Browser,
	port: number,
	nick: string,
	seed: { key: string; value: string },
): Promise<Page> {
	const context = await browser.newContext();
	// The endpoint admits only capability-presenting sockets; the tab holds
	// the swiss the way a reader's "Remember on this device" would have.
	await context.addInitScript(({ key, value }) => localStorage.setItem(key, value), seed);
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
	return tab;
}

async function openDmTo(tab: Page, peer: string): Promise<void> {
	const button = tab.locator(`#members li:has-text("${peer}") button.dm-btn`);
	await button.waitFor({ state: "visible", timeout: 60_000 });
	await button.click();
	await tab.waitForSelector("#line:not([disabled])", { timeout: 10_000 });
}

const deadline = setTimeout(() => fail("web-dm-viz scenario timed out after 150s"), 150_000);

const httpPort = freePort();
const roomPort = freePort();
const vizPort = freePort();

// The room server serves the live timeline endpoint; serve.ts passes its own
// environment to the child and answers `/viz` with the port, which is how each
// tab finds it without being told.
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
	stdout: "inherit",
	stderr: "piped",
});
// The viz sturdyref rides the server's stderr; the scraper tees the stream
// through so the run stays observable.
const vizRef = scrapeVizSturdyref(web.stderr);

let browser: Browser | null = null;
try {
	await waitForHttp(httpPort);

	const served = await fetch(`http://127.0.0.1:${httpPort}/viz`);
	const servedPort = (await served.text()).trim();
	if (servedPort !== String(vizPort)) {
		fail(`the page is told the endpoint is on ${servedPort}, not ${vizPort}`);
	}

	const seen = await watch(await vizRef);
	const seed = vizMemorySeed(httpPort, await vizRef);

	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const alice = await joinAs(browser, httpPort, "web-alice", seed);
	const bob = await joinAs(browser, httpPort, "web-bob", seed);

	// Alice cold-dials Bob off-room and sends. Bob renders it, which is when the
	// direct session has certainly carried traffic on both sides.
	await openDmTo(alice, "web-bob");
	await alice.fill("#line", DM_TEXT);
	await alice.press("#line", "Enter");
	await openDmTo(bob, "web-alice");
	await bob.waitForFunction(
		(t) => [...document.querySelectorAll(".bubble")].some((b) => b.textContent?.includes(t)),
		DM_TEXT,
		{ timeout: 30_000 },
	).catch(() => fail("Bob never received the direct message, so there was no DM to trace"));

	// Give the tabs' publishers a moment to reach the endpoint.
	await new Promise((r) => setTimeout(r, 1_500));

	const opens = seen.filter((r) => r.kind === "ocapn.session-opened");
	if (opens.length === 0) fail("no sessions reached the live timeline endpoint at all");

	// The room's own producer and both tabs' producers are on one feed, and the
	// endpoint has kept their session ids apart: every id is scoped by the
	// connection it arrived on, and both tabs number their own sessions from one.
	const scopes = new Set(opens.map((r) => (r.session as string).split("/")[0]));
	if (scopes.size < 2) {
		fail(
			`every session on the feed came from one producer scope (${[...scopes]}), so the ` +
				"tabs published nothing",
		);
	}
	const ids = opens.map((r) => r.session as string);
	if (new Set(ids).size !== ids.length) fail(`two sessions collided on one id: ${ids}`);

	// The room server labels itself, a tab does not, so a tab's sessions are the
	// unlabelled ones. Among all of them the direct session is unmistakable: it
	// is the one carrying the `dm` verb.
	const dmTraffic = seen.filter(
		(r) => r.kind === "ocapn.message-decoded" && r.op === "dm",
	);
	if (dmTraffic.length === 0) {
		fail(
			"no direct message reached the timeline: " +
				JSON.stringify(
					opens.map((r) => ({ id: r.session, a_label: r.a_label, b: r.b })),
				),
		);
	}
	// Telemetry, not contents. The trace tap can forward each frame's bytes,
	// and these records are exactly the ones that would carry a direct
	// message's text. What survives the cap is what a timeline needs: the
	// verb, the true byte count, and the tag both ends derive from the same
	// frame, which is what draws one conversation out of two sightings.
	for (const record of dmTraffic) {
		if (record.bytes_b64 !== undefined || record.summary !== undefined) {
			fail("a tab published a direct message's own bytes to the shared timeline");
		}
		if (typeof record.digest !== "string" || record.digest === "") {
			fail(`a message record arrived with no tag to fold the two ends on: ${JSON.stringify(record)}`);
		}
		if (typeof record.len !== "number" || record.len <= 0) {
			fail(`a message record arrived with no byte count: ${JSON.stringify(record)}`);
		}
	}

	const dmSessionIds = [...new Set(dmTraffic.map((r) => r.session as string))];

	// Both tabs hold this session and both trace it, and both views arrive:
	// choosing between them is the viewer's decision, and the endpoint is the
	// transport. What makes one conversation out of two views is here — the
	// same session id on both opens, and the same tag on each message, derived
	// by each end from the bytes it holds.
	const dmOpens = dmSessionIds.map((id) => opens.find((r) => r.session === id));
	for (const [i, open] of dmOpens.entries()) {
		if (open === undefined) {
			fail(`the direct session ${dmSessionIds[i]} carried traffic with no open`);
		}
	}
	const dmSessionIdsSeen = new Set(dmOpens.map((r) => r?.session_id as string));
	if (dmSessionIdsSeen.size !== 1) {
		fail(
			`the ends of one direct conversation reported ${dmSessionIdsSeen.size} ` +
				`session ids: ${[...dmSessionIdsSeen]}`,
		);
	}
	if (dmSessionIds.length === 2) {
		const perEnd = dmSessionIds.map((id) =>
			new Set(
				dmTraffic.filter((r) => r.session === id).map((r) => r.digest as string),
			)
		);
		const shared = [...perEnd[0]].filter((d) => perEnd[1].has(d));
		if (shared.length === 0) {
			fail(
				"the two ends of the direct conversation shared no message tag, so a viewer could not fold them",
			);
		}
	}
	const dmId = dmSessionIds[0];
	const dm = dmOpens[0];
	if (dm === undefined) fail(`the direct session ${dmId} carried traffic with no open`);

	// It came from a browser tab, not from the room. The room server cannot
	// report this session at all — it carries none of it — so a `dm` verb on a
	// room-produced session would mean the DM had been routed through the room.
	if (dm.a_label !== undefined) {
		fail(`the direct message was drawn on the room's own session (${dm.a_label})`);
	}
	if (typeof dm.session_id !== "string" || !/^[0-9a-f]{64}$/.test(dm.session_id)) {
		fail(`the direct session carried no session id: ${JSON.stringify(dm)}`);
	}

	// And a human can read who it is with: each end names its partner, and both
	// namings reach the feed now that neither view is dropped.
	const named = seen.some(
		(r) =>
			r.kind === "ocapn.session-meta" &&
			dmSessionIds.includes(r.session as string) &&
			typeof (r.meta as { label?: string } | undefined)?.label === "string",
	);
	if (!named) fail("the direct session reached the timeline with no partner name on it");

	console.log(
		`PASS: a browser-to-browser direct message reached the live timeline — ${opens.length} ` +
			`sessions from ${scopes.size} producers on one feed, the room out of the DM's path, ` +
			`the direct conversation carried from ${dmSessionIds.length} end(s) under one ` +
			`session id ${dm.session_id.slice(0, 12)}… with ${dmTraffic.length} message records on it`,
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
