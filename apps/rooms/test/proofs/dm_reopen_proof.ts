import { Announcements } from "../support/announce.ts";
import { spawnWeb, webPort } from "../support/web_front.ts";
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
// tab can be reached directly. One pair prefers WebRTC (`?dm=webrtc`). The
// server offers relay fallback, so the proof requires the message and reply
// on the replacement DataChannel. The other pair uses only the sealed
// relay (`?dm=relay`). Both lines run between tabs, outside the room's
// conversation.
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
// Needs deno, the wasm module (`zig build wasm-host`), the installed archives
// (serve.ts's room server is the Rust process), and a Playwright Chromium
// (the devcontainer image ships one).
// Run: `zig build rooms-web-dm-reopen`.

import { type Browser, chromium, type Page } from "playwright";
import { Buffer } from "node:buffer";
import { establishLocalSession } from "../support/session_setup.ts";
import { acquireTraceCapability, connectTraceViewer } from "../trace/viewer.ts";
import { reapOwned } from "../support/children.ts";
import { waitForHttp } from "../support/rooms_server.ts";
import { until } from "../support/wait.ts";
import { fail } from "../support/fail.ts";
import { fromPlaywright, ReopenCapture } from "../support/reopen_capture.ts";
import { PAGE_CAPTURE_KEY, type PageSnapshot } from "../support/reopen_capture_page.ts";
import { reportReopenJournals } from "../support/reopen_journal.ts";
import { confirmTitleLeave, openDmTo } from "../page/harness.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;
const ROOM = "lobby";

/** What a failing run reports. Written to only through `capture`. */
const capture = new ReopenCapture();

/** The two ways a tab advertises itself for direct messages, and the transport
 * each one's line rides. The room itself runs over plain TCP, so a session on
 * either of these transports is a direct line and nothing else. */
const MODES = [
	{ name: "webrtc", query: "?dm=webrtc", transport: "webrtc", first: "alice", second: "bob" },
	{ name: "noise-relay", query: "?dm=relay", transport: "noise-relay", first: "carol", second: "dave" },
] as const;

type Mode = typeof MODES[number];

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
	/** The sender and receiver of each `dm` frame, matched by wire and digest. */
	readonly #dmByWire = new Map<string, Map<string, { sent?: string; received?: string }>>();
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
		if (kind === "ocapn.message-decoded" && record.op === "dm") {
			const wire = this.#wireOf.get(local);
			const { digest, outbound } = record;
			if (wire == null || typeof digest !== "string" || digest === "" || typeof outbound !== "boolean") return;
			let frames = this.#dmByWire.get(wire);
			if (frames == null) {
				frames = new Map();
				this.#dmByWire.set(wire, frames);
			}
			const ends = frames.get(digest) ?? {};
			ends[outbound ? "sent" : "received"] = local;
			frames.set(digest, ends);
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

	/** Two different frames crossed between the same producer-scoped ends. */
	carriedDmRoundTrip(wire: string): boolean {
		const frames = this.#dmByWire.get(wire);
		if (frames == null) return false;
		const deliveredTo = new Map<string, string>();
		for (const { sent, received } of frames.values()) {
			if (sent == null || received == null || sent.split("/", 1)[0] === received.split("/", 1)[0]) continue;
			if (deliveredTo.get(received) === sent) return true;
			deliveredTo.set(sent, received);
		}
		return false;
	}

	/** The wire names of the direct lines open on `transport`. */
	on(transport: string): Set<string> {
		return this.live.get(transport) ?? new Set<string>();
	}

	/** What a failed wait names: the direct lines open on `transport`, and how
	 * many are open on each other mode's. A dial that fell back to the relay
	 * shows there. */
	held(transport: string): string {
		const own = `${[...this.on(transport)].join(", ") || "no session"} on ${transport}`;
		const elsewhere = MODES.map((mode) => mode.transport)
			.filter((other) => other !== transport && this.on(other).size > 0)
			.map((other) => `${this.on(other).size} open on ${other}`);
		return [own, ...elsewhere].join(" and ");
	}
}

/** Watch the endpoint the way ocapnviz does: the WebSocket is only the byte
 * channel, and records arrive through an inbox capability after enlivening
 * the sturdyref the server announced. */
async function watch(sturdyref: string): Promise<Timeline> {
	const timeline = new Timeline();
	const viewer = await connectTraceViewer(sturdyref, (record) => {
		capture.viewer(record);
		timeline.apply(record);
	});
	capture.observeClosed(viewer.closed);
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
	await capture.phase(
		"settles",
		transport,
		() =>
			until(() => want(timeline.on(transport)), what, timeoutMs).catch(() =>
				fail(`${what}; the timeline held ${timeline.held(transport)}`)
			),
		what,
	);
}

// ── The tabs ─────────────────────────────────────────────────────────────────

async function joinAs(
	browser: Browser,
	port: number,
	mode: Mode,
	nick: string,
	trace: string,
): Promise<Page> {
	const query = mode.query;
	const context = await browser.newContext();
	// Only the tabs whose line is a DataChannel have one to observe.
	const instrumented = mode.name === "webrtc";
	if (instrumented) await capture.instrument(context);
	const tab = await context.newPage();
	capture.register(tab, nick, mode.name, instrumented, fromPlaywright(tab));
	tab.on("pageerror", (e) => console.error(`  [${nick} page error]`, e.message));
	tab.on("console", (m) => {
		if (m.type() === "error") console.error(`  [${nick} console.error]`, m.text());
	});
	await tab.goto(`http://127.0.0.1:${port}/${query}`);
	await establishLocalSession(tab);
	await acquireTraceCapability(tab, trace);
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
	await capture.phase("say", capture.who(tab), async () => {
		await tab.fill("#line", text);
		await tab.press("#line", "Enter");
	});
}

/** `openDmTo`, marked for the failure capture. */
const openDm = (tab: Page, peer: string): Promise<void> =>
	capture.phase("openDmTo", capture.who(tab), () => openDmTo(tab, peer), peer);

/** `confirmTitleLeave`, marked for the failure capture. */
const leaveDm = (tab: Page): Promise<void> =>
	capture.phase("confirmTitleLeave", capture.who(tab), () => confirmTitleLeave(tab));

async function sees(tab: Page, text: string, who: string): Promise<void> {
	await capture.phase("sees", capture.who(tab), () =>
		tab.waitForFunction(
			(t) => [...document.querySelectorAll(".bubble")].some((b) => b.textContent?.includes(t)),
			text,
			{ timeout: 30_000 },
		).catch(async () => {
			const log = (await tab.textContent("#log").catch(() => "?")) ?? "?";
			console.error(`  [${who} #log] ${JSON.stringify(log)}`);
			fail(`${who} never saw "${text}"`);
		}).then(() => {}));
}

/** The live sessions the timeline held, per transport, for the failure report. */
const describe = (timeline: Timeline): string => MODES.map((m) => timeline.held(m.transport)).join("; ");

const deadline = setTimeout(() => fail("web-dm-reopen timed out after 300s"), 300_000);

// The room server carries the live timeline endpoint, and serve.ts hands its own
// environment to it, so each tab finds the endpoint by asking `/trace`.
const web = spawnWeb({
	args: ["--transport=tcp", "0", "0"],
	cwd: ROOT,
	env: { GLOWCAP_ROOMS_CAPABILITIES: "trace,operator", GLOWCAP_ROOMS_TRACE_PORT: "0" },
	stdout: "piped",
	stderr: "piped",
});
// Its operator announcement belongs to the disposable server and never goes in the log.
const announcements = new Announcements(web.stdout, false);
const httpPort = await webPort(web, announcements);
const traceRef = announcements.line("ROOMS-TRACE-LISTENING", "rooms-web");

let browser: Browser | null = null;
let watched: Timeline | null = null;
try {
	await waitForHttp(httpPort);
	const timeline = await watch(await traceRef);
	watched = timeline;
	const trace = await traceRef;
	browser = await chromium.launch({ args: ["--no-sandbox"] });

	for (const mode of MODES) {
		const opener = await joinAs(browser, httpPort, mode, mode.first, trace);
		const other = await joinAs(browser, httpPort, mode, mode.second, trace);

		// The first conversation: the opener redeems the room's introduction, the
		// line opens, and both directions carry.
		await openDm(opener, mode.second);
		await say(opener, `${mode.name}: first line`);
		await openDm(other, mode.first);
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
		await leaveDm(opener);
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
		await openDm(opener, mode.second);
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
		await settles(
			timeline,
			mode.transport,
			`the second ${mode.name} connection did not carry the message and reply on the same wire`,
			() => timeline.carriedDmRoundTrip(secondLine),
		);

		// Then each side reopens in turn. Closing its final local route ends
		// the connection. The peer may retain a closed conversation for history;
		// the newly offered reply must establish the replacement live route.
		for (
			const [sender, receiver, nick] of [
				[other, opener, mode.second],
				[opener, other, mode.first],
			] as const
		) {
			await leaveDm(sender);
			await sender.waitForFunction(
				() => document.querySelectorAll("#dmList li:not(.closed) .dm-open").length === 0,
				undefined,
				{
					timeout: 20_000,
				},
			);
			await openDm(sender, sender === other ? mode.first : mode.second);
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

		if (mode.name === "webrtc") {
			for (const tab of [opener, other]) {
				const [peers, certified] = await tab.evaluate((key) => {
					const capture = Reflect.get(globalThis, key) as { snapshot(): PageSnapshot };
					const { peers, peersWithCertificate } = capture.snapshot();
					return [peers, peersWithCertificate];
				}, PAGE_CAPTURE_KEY);
				if (peers < 4 || certified !== peers) {
					const who = capture.who(tab);
					fail(`${who} supplied a DTLS certificate to ${certified} of ${peers} peers across the reopens`);
				}
			}
		}

		// A fresh page Host cannot restore a previous live DM route. Its saved
		// row stays closed until an explicit reconnect to the same registration.
		const rows = await opener.locator("#dmList .dm-open").count();
		await opener.fill("#line", `${mode.name}: saved reload draft`);
		// Export reads accepted session state. Establish draft commitment before
		// killing the Host, instead of racing a keystroke against page unload.
		await opener.click("#settingsBtn");
		await opener.click("#sessionTab");
		await opener.click("#sessionDataOpen");
		const downloaded = opener.waitForEvent("download", { timeout: 20_000 });
		await opener.click("#stateDownload");
		const savedPath = await (await downloaded).path();
		if (savedPath == null) fail("draft commitment export was unavailable");
		const saved = JSON.parse(await Deno.readTextFile(savedPath!));
		if (!saved.conversations.some((row: { draft: string }) => row.draft === `${mode.name}: saved reload draft`)) {
			fail("the accepted workspace did not contain the saved direct draft");
		}
		await opener.goto(`http://127.0.0.1:${httpPort}/ops/nope${mode.query}`);
		await opener.waitForSelector("#opsNotFound", { timeout: 20_000 });
		await opener.locator("#dmList .dm-open").last().click();
		await opener.waitForSelector("#dmReconnect", { timeout: 20_000 });
		if (!await opener.locator("#line").isDisabled()) fail("a cold direct route presented a sendable composer");
		if (await opener.inputValue("#line") !== `${mode.name}: saved reload draft`) {
			fail("reload lost the direct draft");
		}
		await opener.click("#dmReconnect");
		await opener.waitForSelector("#line:not([disabled])", { timeout: 20_000 });
		if (await opener.locator("#dmList .dm-open").count() !== rows) {
			fail("reconnect duplicated the saved conversation");
		}
		if (await opener.inputValue("#line") !== `${mode.name}: saved reload draft`) {
			fail("reconnect replaced the saved draft");
		}
		await say(opener, `${mode.name}: after reload`);
		// Submit a file while the text receipt can still be settling. The next
		// gesture owns its source independently of the previous draft clear.
		await opener.setInputFiles("#filePick", {
			name: "reconnect-file.txt",
			mimeType: "text/plain",
			buffer: Buffer.from("reconnect attachment bytes"),
		});
		await opener.click("#sendBtn");
		// The reloaded sender has a fresh directory registration. Its peer must
		// select that new identity, keeping the old sender's history separate.
		await other.locator(`#dmList li:not(.closed) .dm-open:has(.rname:text-is("${mode.first}"))`).click({
			timeout: 20_000,
		});
		await other.waitForSelector("#line:not([disabled])", { timeout: 20_000 });
		await sees(other, `${mode.name}: after reload`, mode.second);
		await other.waitForSelector('.attach-file:has(.name:text-is("reconnect-file.txt"))', { timeout: 20_000 });
		if (await other.locator(`.bubble:has-text("${mode.name}: first line")`).count() !== 0) {
			fail("a replacement sender registration inherited the previous sender's history");
		}
		await say(other, `${mode.name}: reload reply`);
		await sees(opener, `${mode.name}: reload reply`, mode.first);
		// Closing a saved entry is dismissal, not another close of its dead wire.
		await opener.reload();
		await opener.waitForSelector("#boot", { state: "detached", timeout: 20_000 });
		const closedRow = opener.locator("#dmList li.closed").last();
		await closedRow.waitFor({ timeout: 20_000 });
		await closedRow.hover();
		await closedRow.locator(".room-leave").click();
		await opener.waitForFunction(
			(count) => document.querySelectorAll("#dmList .dm-open").length === count - 1,
			rows,
			{ timeout: 20_000 },
		);
		// The receiver holds separate conversations for the sender's old and
		// replacement registrations, even though both rows wear the same name.
		// Every saved closed entry can be dismissed independently and stays gone.
		await other.reload();
		await other.waitForSelector("#boot", { state: "detached", timeout: 20_000 });
		const savedRows = await other.locator("#dmList li.closed").count();
		if (savedRows < 2) fail("the receiver did not retain the separate sender registrations");
		for (let remaining = savedRows; remaining > 0; remaining--) {
			const savedRow = other.locator("#dmList li.closed").first();
			await savedRow.hover();
			await savedRow.locator(".room-leave").click();
			await other.waitForFunction(
				(count) => document.querySelectorAll("#dmList .dm-open").length === count,
				remaining - 1,
				{ timeout: 20_000 },
			);
		}
		await other.reload();
		await other.waitForSelector("#boot", { state: "detached", timeout: 20_000 });
		if (await other.locator("#dmList .dm-open").count() !== 0) {
			fail("dismissed closed entries returned after reload");
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
} catch (error) {
	// Disarm the whole-run deadline first: it throws from a timer, and an
	// awaited snapshot must not be raced by it into replacing this failure.
	clearTimeout(deadline);
	const snapshot = await capture.report(error, watched === null ? "not watching yet" : describe(watched));
	if (snapshot && browser) {
		try {
			await reportReopenJournals(
				snapshot,
				`http://127.0.0.1:${httpPort}`,
				browser.contexts().flatMap((context) => context.pages()).map((page) => [capture.who(page), page]),
				(ms) => announcements.line("ROOMS-OPERATOR", "rooms-web", ms),
			);
		} catch {
			// tolerant: even a failed journal write must preserve the original exception.
		}
	}
	throw error;
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
