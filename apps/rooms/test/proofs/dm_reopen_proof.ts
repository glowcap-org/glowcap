// Closing a direct message and starting another one with the same person opens
// a second connection, and the second one carries.
//
// This is the step the other direct-message proofs skip. `dm_tabs_proof.ts`
// closes a conversation and reopens it, but it only asks whether the message
// arrived; `trace_lifecycle_proof.ts` watches a reopen on the timeline, but the
// tab that closes there is the one that was *dialed*, not the one that dialed.
// Neither asks the question a reader asks when a reopened conversation goes
// quiet: did anything actually reconnect? A reopen that quietly resolves to the
// connection the close was supposed to end looks exactly like a working one
// until the first message fails, and nothing in the tree would have noticed.
//
// So this proof watches the live timeline while it drives the tabs, and asks
// both halves of the question. The message has to arrive, and the wire it
// arrived on has to be a different wire: the first conversation's session must
// be gone from the feed, and the second one's must be a session id nobody had
// seen before. The reply then has to come back over that new one, because a
// direct line is only reopened if it is reopened in both directions.
//
// It runs the same scenario twice against one room, once for each way a browser
// tab can be reached directly. One pair of tabs advertises a `webrtc` locator
// (`?dm=webrtc`), so their line is a DataChannel the room only signals; the
// other pair advertises `noise-relay` (`?dm=relay`), so their line is a sealed
// cold dial through the relay's rendezvous. Both are direct lines between two tabs with the room off
// the message path, and a defect in reopening one of them is not a defect in
// reopening the other — running both is what makes "is this specific to
// WebRTC?" a question this file answers rather than one a reader has to ask.
//
// What a green run means here is what it was measured against. Two defects were
// injected into a healthy tree and both were caught, each by name rather than by
// running out of time: a close that hands nothing back (the page forgets the
// conversation and leaves its line open) failed as "closing the conversation
// left its connection open", and a close that ends the byte channel while the
// Host keeps the row naming that session failed as "reopening the conversation
// opened no second connection", with the timeline holding no direct line at all.
// The second is the shape a reader reports as "it just does not send, and
// nothing appears on the timeline", which is why it is worth naming.
//
// Needs deno, the wasm module (`zig build wasm-driver`), the native archives
// (serve.ts's room server is native), and a Playwright Chromium
// (the devcontainer image ships one).
// Run: `deno run --allow-all apps/rooms/test/web/dm_reopen_proof.ts`.

import { type Browser, chromium, type Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { connectTraceViewer, scrapeTraceSturdyref, traceMemorySeed } from "../trace/viewer.ts";
import { reapOwned, spawnOwned } from "../support/children.ts";
import { freePort, waitForHttp } from "../support/rooms_server.ts";
import { confirmTitleLeave, fail, openDmTo } from "../page/harness.ts";

import { WEB } from "../support/paths.ts";
const ROOT = new URL("../../../../", import.meta.url).pathname;
const ROOM = "lobby";

/** The two ways a tab advertises itself for direct messages, and the transport
 * each one's line rides. The room itself runs over plain TCP, so a session on
 * either of these transports is a direct line and nothing else. */
const MODES = [
	{ name: "webrtc", query: "?dm=webrtc", transport: "webrtc", first: "alice", second: "bob" },
	{ name: "noise-relay", query: "?dm=relay", transport: "noise-relay", first: "carol", second: "dave" },
] as const;

// ── The timeline, as a viewer sees it ────────────────────────────────────────

/** The live sessions on the feed, by the wire name both ends agree on.
 *
 * A record names its session twice: `session` is the producer's own local name,
 * which two tabs can spell identically for different wires, and `session_id` is
 * the name derived from the connection itself, which both ends of one wire
 * report. Openings carry both and closings carry only the local one, so the
 * local name is what a close is matched on and the wire name is what a claim
 * about "a different connection" is made in. */
class Timeline {
	/** Producer-scoped name to the wire name it opened with. */
	readonly #wireOf = new Map<string, string>();
	/** The wire name of every session still open, by transport. */
	readonly live = new Map<string, Set<string>>();

	apply(record: Record<string, unknown>): void {
		const kind = String(record.kind ?? "");
		const local = String(record.session ?? "");
		if (kind === "ocapn.session-opened") {
			const wire = String(record.session_id ?? "");
			const transport = String(record.transport ?? "");
			if (local === "" || wire === "") return;
			this.#wireOf.set(local, wire);

			const on = this.live.get(transport) ?? new Set<string>();
			on.add(wire);
			this.live.set(transport, on);
			return;
		}
		if (kind === "ocapn.session-closed" || kind === "ocapn.session-unobserved") {
			const wire = this.#wireOf.get(local);
			if (wire === undefined) return;
			this.#wireOf.delete(local);
			// A session is one wire between two ends, so one end reporting it
			// closed is enough to say it is gone. Waiting for both would let a
			// close that ended the connection but left a stale route behind read
			// as an unfinished close, which is the wrong complaint: the wire did
			// end, and what is wrong is what the next dial resolves to.
			for (const on of this.live.values()) on.delete(wire);
		}
	}

	/** The wire names of the direct lines currently open on `transport`. */
	on(transport: string): Set<string> {
		return this.live.get(transport) ?? new Set<string>();
	}
}

/** Watch the endpoint the way ocapnviz does: the WebSocket is only the byte
 * channel, and records arrive through an inbox capability after enlivening
 * the sturdyref the server announced. */
async function watch(sturdyref: string): Promise<Timeline> {
	const timeline = new Timeline();
	await connectTraceViewer(sturdyref, (record) => timeline.apply(record));
	return timeline;
}

/** Wait until the timeline says `want`, or fail with what it held instead. Every
 * hop of the feed is asynchronous, so each of these is a wait rather than a
 * sleep followed by a guess. */
async function settles(
	timeline: Timeline,
	transport: string,
	what: string,
	want: (live: Set<string>) => boolean,
	timeoutMs = 30_000,
): Promise<void> {
	const until = Date.now() + timeoutMs;
	while (Date.now() < until) {
		if (want(timeline.on(transport))) return;
		await new Promise((r) => setTimeout(r, 100));
	}
	fail(`${what}; the timeline held ${[...timeline.on(transport)].join(", ") || "no session"}`);
}

// ── The tabs ─────────────────────────────────────────────────────────────────

async function joinAs(
	browser: Browser,
	port: number,
	query: string,
	nick: string,
	seed: { key: string; value: string },
): Promise<Page> {
	const context = await browser.newContext();
	// The endpoint admits only capability-presenting sockets; the tab holds
	// the swiss the way a reader's "Remember on this device" would have.
	await context.addInitScript(({ key, value }) => localStorage.setItem(key, value), seed);
	const tab = await context.newPage();
	tab.on("pageerror", (e) => console.error(`  [${nick} page error]`, e.message));
	tab.on("console", (m) => {
		if (m.type() === "error") console.error(`  [${nick} console.error]`, m.text());
	});
	await tab.goto(`http://127.0.0.1:${port}/${query}`);
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

async function say(tab: Page, text: string): Promise<void> {
	await tab.fill("#line", text);
	await tab.press("#line", "Enter");
}

async function sees(tab: Page, text: string, who: string): Promise<void> {
	await tab.waitForFunction(
		(t) => [...document.querySelectorAll(".bubble")].some((b) => b.textContent?.includes(t)),
		text,
		{ timeout: 30_000 },
	).catch(async () => {
		const log = (await tab.textContent("#log").catch(() => "?")) ?? "?";
		console.error(`  [${who} #log] ${JSON.stringify(log)}`);
		fail(`${who} never saw "${text}"`);
	});
}

const deadline = setTimeout(() => fail("web-dm-reopen timed out after 300s"), 300_000);

const httpPort = freePort();
const roomPort = freePort();
const tracePort = freePort();

// The room server carries the live timeline endpoint, and serve.ts hands its own
// environment to it, so each tab finds the endpoint by asking `/trace`.
const web = spawnOwned(WEB, {
	args: ["--transport=tcp", String(httpPort), String(roomPort)],
	cwd: ROOT,
	env: { GLOWCAP_ROOMS_TRACE: "1", GLOWCAP_ROOMS_TRACE_PORT: String(tracePort) },
	stdout: "inherit",
	stderr: "piped",
});
// The trace sturdyref rides the server's stderr; the scraper tees the stream
// through so the run stays observable.
const traceRef = scrapeTraceSturdyref(web.stderr);

let browser: Browser | null = null;
try {
	await waitForHttp(httpPort);
	const timeline = await watch(await traceRef);
	const seed = traceMemorySeed(httpPort, await traceRef);
	browser = await chromium.launch({ args: ["--no-sandbox"] });

	for (const mode of MODES) {
		const opener = await joinAs(browser, httpPort, mode.query, mode.first, seed);
		const other = await joinAs(browser, httpPort, mode.query, mode.second, seed);

		// The first conversation: the opener redeems the room's introduction, the
		// line opens, and both directions carry.
		await openDmTo(opener, mode.second);
		await say(opener, `${mode.name}: first line`);
		await openDmTo(other, mode.first);
		await sees(other, `${mode.name}: first line`, mode.second);
		await say(other, `${mode.name}: first reply`);
		await sees(opener, `${mode.name}: first reply`, mode.first);
		await settles(
			timeline,
			mode.transport,
			`the ${mode.name} direct line never reached the timeline`,
			(live) => live.size === 1,
		);
		const [firstLine] = [...timeline.on(mode.transport)];

		// The opener ends the conversation with the mark in its title. The
		// connection is the conversation's, so it goes with it, and the timeline is
		// where that claim is checkable.
		await confirmTitleLeave(opener);
		await settles(
			timeline,
			mode.transport,
			`closing the ${mode.name} conversation left its connection open`,
			(live) => !live.has(firstLine),
		);

		// Now the whole point. Take the same person's line again from the members
		// list and send. The connection is asked about before the message is,
		// because it is the sharper fact: a reopen that opened nothing is a reopen
		// that resolved to something already there, and saying so beats waiting
		// out a message that was never going to arrive.
		await openDmTo(opener, mode.second);
		await say(opener, `${mode.name}: second line`);
		await settles(
			timeline,
			mode.transport,
			`reopening the ${mode.name} conversation opened no second connection`,
			(live) => live.size === 1 && !live.has(firstLine),
		);
		const [secondLine] = [...timeline.on(mode.transport)];
		if (secondLine === firstLine) {
			fail(`the reopened ${mode.name} conversation ran on the connection its close ended`);
		}
		await sees(other, `${mode.name}: second line`, mode.second);

		// The second line is not a one-way pipe: the reply has to come back over it.
		// That return proves the far tab replaced its own route.
		await say(other, `${mode.name}: second reply`);
		await sees(opener, `${mode.name}: second reply`, mode.first);

		// Then each side reopens in turn. Closing a borrowed reciprocal route
		// leaves the other side's connection alive; the newly offered reply
		// must replace that route. Reuse of the same connection is valid; a
		// superseded connection must close once no route uses it.
		for (
			const [sender, receiver, nick] of [
				[other, opener, mode.second],
				[opener, other, mode.first],
			] as const
		) {
			await confirmTitleLeave(sender);
			await sender.waitForFunction(() => document.querySelectorAll("#dmList .dm-open").length === 0, undefined, {
				timeout: 20_000,
			});
			await openDmTo(sender, sender === other ? mode.first : mode.second);
			const message = `${mode.name}: ${nick} reopened`;
			await say(sender, message);
			await sees(receiver, message, "the receiving peer");
			await settles(
				timeline,
				mode.transport,
				`reopening the ${mode.name} route left extra connections alive`,
				(live) => live.size === 1,
			);
			await say(receiver, `${message}: reply`);
			await sees(sender, `${message}: reply`, nick);
		}

		console.log(
			`  ok: ${mode.name} — closing the conversation ended its connection, ` +
				`both directions carried, and alternating reopens refreshed inboxes without leaking connections`,
		);

		await opener.context().close();
		await other.context().close();
	}

	console.log(
		"PASS: a browser tab that closes a direct message and starts another with the same " +
			"person gets a genuinely new connection, over a WebRTC DataChannel and over a " +
			"relay rendezvous cold dial alike — the closed line left the timeline, the reopened " +
			"one arrived on a session nobody had seen, and messages crossed it both ways",
	);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
