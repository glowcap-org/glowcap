// A real Spritely Goblins vat holds a direct message with a browser, and the
// live timeline draws it.
//
// The room introduces two members and then carries none of what they say. That
// is OCapN's three-party handoff, and this run stands each corner of it on a
// different implementation: a glowcap room as the gifter, a Goblins vat as the
// exporter, and a browser tab running glowcap's wasm peer as the recipient. What
// makes it worth running is that nothing in Goblins was changed to allow it. The
// vat speaks the OCapN v1.0 baseline over Syrup, the room and the tab speak
// glowcap's own profile to each other, and the give crosses that split.
//
// The run proves six things and asserts all six:
//
//   1. A browser tab direct-messages the vat. The tab asks the room to introduce
//      it, redeems the give by dialing the vat's own netlayer, and the line
//      arrives on the inbox the vat minted for that tab alone.
//   2. The vat answers, over the connection the message arrived on. A browser
//      opens no listener, so this is the only path back to it, and it is the
//      half that makes a direct message a conversation rather than a drop box.
//   3. The vat starts one of its own. A native glowcap member registers, the vat
//      asks the room to introduce it, and Goblins redeems that give by dialing
//      the member directly. The member observes the exact line and then refuses
//      its call; the vat reports that refusal without printing `DM SENT`. This
//      proves both the exporter claim and that terminal narration follows the
//      asynchronous delivery result rather than message submission.
//   4. The conversation reaches the live timeline as a session of its own, from
//      both ends, with the room off its path. The vat publishes what its own
//      netlayer saw, so a viewer draws this wire from inside it.
//   5. Closing the conversation in the browser takes that session off the
//      timeline, reported by the vat's own end.
//   6. Reopening the conversation starts one new session only after both views
//      of the old one closed, rather than stacking it beside a stale session.
//
// `--iroh` runs the same scenario over encrypted QUIC instead of cleartext TCP.
// Which transport the vat is reached over is the locator the room announced,
// because the vat spawns the netlayer that speaks it; nothing else about the
// conversation changes, which is the point. The one thing that does change is
// deployment: a browser's relay dials iroh anywhere and cleartext TCP only where
// an operator names it, so the TCP arm lists the vat in
// `GLOWCAP_RELAY_TCP_PEERS` and the iroh arm lists nothing.
//
// Runs as `zig build goblins-rooms-dm` (and `goblins-rooms-dm-iroh`); needs
// deno, racket with the `goblins` collection, a Playwright Chromium, and — for
// the iroh arm — the iroh sidecar from cargo.

import { type Browser, chromium, type Page } from "playwright";

import type { Argument, Behavior } from "@glowcap/runtime";
import { inboxPublisher } from "../../apps/rooms/lib/dm_inbox.ts";
import { Directory, Room } from "../../apps/rooms/lib/room/client.ts";
import { enterOrOpen } from "../../apps/rooms/lib/enter_room.ts";
import { openRoomsRuntime } from "../../apps/rooms/lib/runtime.ts";
import { DM } from "../../apps/rooms/lib/protocol.ts";
import { dial, loopbackTcpDesignator, roomsHost, roomsListen } from "../../apps/rooms/lib/locator.ts";
import {
	connectTraceViewer,
	scrapeTraceSturdyref,
	traceMemorySeed,
	traceUrlOf,
} from "../../apps/rooms/test/trace/viewer.ts";
import { freePort } from "../../apps/rooms/test/support/rooms_server.ts";
import { confirmTitleLeave } from "../../apps/rooms/test/page/harness.ts";
import { until as untilWithin } from "../../apps/rooms/test/support/wait.ts";
import { establishLocalSession } from "../../apps/rooms/test/support/session_setup.ts";

const IROH = Deno.args.includes("--iroh");
const GATE = IROH ? "goblins-rooms-dm-iroh" : "goblins-rooms-dm";
const ROOT = new URL("../../", import.meta.url).pathname;
import { WEB } from "../../apps/rooms/test/support/paths.ts";
const VAT = new URL("../../conformance/goblins-peer/racket/rooms-dm-member.rkt", import.meta.url)
	.pathname;
const RACKET_DIR = new URL("../../conformance/goblins-peer/racket/", import.meta.url).pathname;

const ROOM = "lobby";
const TAB_NICK = "web-alice";
const VAT_NICK = "goblins-carol";
const TO_VAT = "hello carol, privately, from a browser";
const REPLY_PREFIX = "got your DM: ";
const FROM_VAT = `${REPLY_PREFIX}${TO_VAT}`;
const TO_VAT_AGAIN = "hello again on a new direct line";

/** The native glowcap member the vat direct-messages, and the line it sends. */
const NATIVE_NICK = "native-bob";
const TO_NATIVE = "hello bob, privately, from a goblins vat";

/** The word the vat's own trace publisher says it runs, which is how a record
 * from the vat is told from one the room or the tab produced. */
const GOBLINS_PROFILE = "goblins";

/** Every diagnostic wait expires before the build's 30-second process owner. */
const WAIT_MS = 20_000;

/** The shared wait, on this harness's own clock. */
const until = (ready: () => boolean, what: string, ms = WAIT_MS) => untilWithin(ready, what, ms);

/** How long an iroh endpoint may take to learn a direct address of its own.
 * Shorter than `WAIT_MS`, because nothing here is starting up cold. */
const IROH_DIRECT_ADDRESSES_MS = 20_000;

function fail(message: string): never {
	throw new Error(message);
}

async function waitForLocator(port: number): Promise<string> {
	const deadline = Date.now() + WAIT_MS;
	while (Date.now() < deadline) {
		try {
			const res = await fetch(`http://127.0.0.1:${port}/locator`);
			const text = (await res.text()).trim();
			if (res.status === 200 && text.length > 0) return text;
		} catch {
			// the front is not up, or the room has not announced yet
		}
		await new Promise((r) => setTimeout(r, 50));
	}
	fail("serve.ts did not answer with a room locator");
}

/** Every line the vat has printed. It narrates what it hears one line at a time,
 * so its stdout is where this harness reads what a Goblins vat actually saw. */
const vatLines: string[] = [];
const vatErrors: string[] = [];
function vatSaid(pattern: RegExp): boolean {
	return vatLines.some((line) => pattern.test(line));
}

function rejectInvalidHandoff(): void {
	if (vatErrors.some((line) => line.includes("invalid-handoff-cert"))) {
		fail("the Goblins vat rejected the reopened conversation's handoff certificate");
	}
}

function expectWireProvenance(
	record: Record<string, unknown>,
	label: string,
	provenance: "authenticated-transport" | "unauthenticated",
): void {
	const transport = IROH ? "iroh" : "tcp";
	if (record.transport !== transport || record.provenance !== provenance) {
		fail(
			`${label} reported ${record.transport}/${record.provenance}, wanted ${transport}/${provenance}`,
		);
	}
}

/** Every line the native glowcap member has been sent directly.
 *
 * It records and then refuses. That gives the vat a completed negative delivery
 * result: the line demonstrably arrived, while `DM SENT` must remain absent. */
const nativeInbox: string[] = [];
const recordOnlyDm: Behavior = (verb: string, args: Argument[]): never => {
	if (verb !== DM) throw new Error(`dm has no method ${verb}`);
	nativeInbox.push(String(args[0]));
	throw new Error("the native inbox refused after observing the line");
};

/** Stand the native glowcap member up where the vat can dial it, and hand back
 * the locator it registers under.
 *
 * Over TCP that locator is a loopback address. Over iroh it is the member's
 * endpoint key together with the direct addresses a dialer needs, which an iroh
 * endpoint only knows once it has learned them, so this waits for them.
 * `@glowcap/iroh` is imported here rather than at the top of the file so the TCP
 * arm never loads the sidecar it does not use. */
async function startNativeMember() {
	if (!IROH) {
		const host = roomsHost();
		const listener = await roomsListen("127.0.0.1", 0, host);
		const port = listener.port;
		return { host, listener, locator: loopbackTcpDesignator(port) };
	}
	const { listen, Reachability } = await import("@glowcap/iroh");
	const seed = crypto.getRandomValues(new Uint8Array(32));
	const host = roomsHost(seed);
	const listener = await listen({ reachability: Reachability.Direct }, { host });
	await until(
		() => listener.directAddresses.length > 0,
		"the native member's iroh direct addresses",
		IROH_DIRECT_ADDRESSES_MS,
	);
	return { host, listener, locator: listener.uri };
}

/** A viewer on the live timeline endpoint, exactly as ocapnviz connects.
 *
 * Records arrive through a capability the endpoint hands this viewer's inbox,
 * after enlivening the sturdyref the server announced. `trace_viewer.ts` is the
 * one place that connection is made, so this harness and the browser proofs
 * read the endpoint through the same shape. */
type Rec = Record<string, unknown>;
async function watchTimeline(sturdyref: string): Promise<{ seen: Rec[]; close: () => Promise<void> }> {
	const seen: Rec[] = [];
	const viewer = await connectTraceViewer(sturdyref, (record) => {
		seen.push(record);
	});
	return { seen, close: () => viewer.close() };
}

const httpPort = freePort();
const roomPort = freePort();
const tracePort = freePort();
const vatPort = freePort();

let browser: Browser | null = null;
let web: Deno.ChildProcess | null = null;
let vat: Deno.ChildProcess | null = null;
let nativeListener: { close: () => void } | null = null;
let nativeDir: Directory | null = null;
let nativeRuntime: Awaited<ReturnType<typeof openRoomsRuntime>> | null = null;
let closeViewer: (() => Promise<void>) | null = null;

try {
	// The web front: the page, the byte relay a tab reaches everything through,
	// and the room server as its child. The TCP arm names the vat's address as a
	// cleartext peer the relay may dial; the iroh arm names nothing, because an
	// iroh destination has to be a peer holding a key.
	const env: Record<string, string> = { GLOWCAP_ROOMS_TRACE: "1", GLOWCAP_ROOMS_TRACE_PORT: String(tracePort) };
	if (!IROH) env.GLOWCAP_RELAY_TCP_PEERS = loopbackTcpDesignator(vatPort);
	web = new Deno.Command(WEB, {
		args: [
			"--transport=tcp",
			...(IROH ? ["--transport=iroh"] : []),
			String(httpPort),
			String(roomPort),
		],
		cwd: ROOT,
		env,
		// Discarded rather than piped: the locator comes from `/locator` over
		// HTTP, so nothing here reads this stream, and a pipe nobody drains is a
		// process that eventually blocks on its own output. Its stderr is read
		// rather than inherited, because the trace capability is announced there
		// and a viewer needs it; `scrapeTraceSturdyref` tees the stream onward, so
		// nothing the server says is lost by reading it here.
		stdout: "null",
		stderr: "piped",
	}).spawn();

	const traceRef = await scrapeTraceSturdyref(web.stderr);
	const roomLocator = await waitForLocator(httpPort);
	const viewer = await watchTimeline(traceRef);
	closeViewer = viewer.close;
	const timeline = viewer.seen;

	// The Goblins vat. It reads the transport off the room's locator and spawns
	// the netlayer that speaks it, so the same command line covers both arms; an
	// iroh locator refuses a local port, since an iroh vat is reached by its
	// endpoint key rather than an address.
	vat = new Deno.Command("racket", {
		args: [
			"-y",
			VAT,
			"--reply-prefix",
			REPLY_PREFIX,
			// The other direction, (3): the vat waits for this member to register
			// and then asks the room to introduce it.
			"--dm",
			NATIVE_NICK,
			"--dm-text",
			TO_NATIVE,
			...(IROH ? [] : ["--local-port", String(vatPort)]),
			roomLocator,
			ROOM,
			VAT_NICK,
		],
		cwd: RACKET_DIR,
		env: { GLOWCAP_ROOMS_TRACE_URL: traceUrlOf(traceRef) },
		stdout: "piped",
		stderr: "piped",
	}).spawn();

	(async () => {
		const decoder = new TextDecoder();
		let buf = "";
		for await (const chunk of vat!.stdout) {
			buf += decoder.decode(chunk);
			const lines = buf.split("\n");
			buf = lines.pop() ?? "";
			for (const line of lines) {
				vatLines.push(line);
				console.log(`  [vat] ${line}`);
			}
		}
	})();
	(async () => {
		const decoder = new TextDecoder();
		let buf = "";
		for await (const chunk of vat!.stderr) {
			buf += decoder.decode(chunk);
			const lines = buf.split("\n");
			buf = lines.pop() ?? "";
			for (const line of lines) {
				vatErrors.push(line);
				console.error(`  [vat stderr] ${line}`);
			}
		}
	})();

	await until(() => vatSaid(/^DM READY /), "the Goblins vat to join the room and claim its name");

	// (3) begins here, and runs while the tab holds its own conversation below.
	// The vat is already watching the directory, so this member registering is
	// what sets the vat's own introduction going.
	{
		const native = await startNativeMember();
		nativeListener = native.listener;
		nativeRuntime = await openRoomsRuntime({
			host: native.host,
			iroh: IROH ? { reachability: (await import("@glowcap/iroh")).Reachability.Direct } : undefined,
		});
		(async () => {
			for await (const session of native.listener) session.serve().catch(() => {});
		})();
		nativeDir = await Directory.connect(roomLocator, (l) => dial(l, nativeRuntime!));
		const nativeRoom = await enterOrOpen(nativeDir, ROOM);
		await Room.subscribe(nativeDir.session, nativeRoom, NATIVE_NICK);
		// The inbox the room hands the vat when it asks to be introduced. It is
		// minted on demand, so the vat's first `introduce` is refused pending and its
		// second one carries this.
		const nativeOfferer = inboxPublisher(native.host).offerer({
			dir: () => nativeDir,
			behaviorFor: () => recordOnlyDm,
			skip: (peer) => peer.toLowerCase() === NATIVE_NICK,
			// Narrated rather than swallowed. An inbox this member fails to offer
			// leaves the vat's introduction pending forever, and a pending
			// introduction is silent on both sides.
			onError: (peer, err) => console.error(`  [native] no inbox for ${peer}:`, err),
		});
		// The locator registered here is what the room stamps as this member's
		// exporter location, and therefore what the vat's give has to name.
		await nativeDir.register(NATIVE_NICK, native.locator, {
			onMintInboxFor: (peer, registrationId) => {
				console.log(`  [native] the room asked for an inbox for ${peer}`);
				nativeOfferer.offer(peer, registrationId);
			},
		});
		console.log(`  [native] registered as ${NATIVE_NICK} at ${native.locator}`);
	}

	// The browser tab.
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	const context = await browser.newContext();
	await context.addInitScript(
		({ key, value }) => localStorage.setItem(key, value),
		traceMemorySeed(httpPort, traceRef),
	);
	const tab: Page = await context.newPage();
	tab.on("console", (message) => {
		if (message.type() === "error" || message.type() === "warning") {
			console.error(`  [page ${message.type()}] ${message.text()}`);
		}
	});
	tab.on("pageerror", (e) => console.error("  [page error]", e.message));
	await tab.goto(`http://127.0.0.1:${httpPort}/`);
	await establishLocalSession(tab);
	await tab.waitForSelector("#joinBtn", { timeout: 10_000 }).catch(async (error) => {
		console.error(`  [page url] ${tab.url()}`);
		console.error(`  [page body] ${JSON.stringify((await tab.locator("body").innerText()).slice(0, 2_000))}`);
		throw error;
	});
	await tab.fill("#nick", TAB_NICK);
	await tab.fill("#room", ROOM);
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: WAIT_MS }).catch(async () => {
		const status = await tab.textContent("#status").catch(() => "?");
		fail(`the tab never joined the room; status="${status}"`);
	});

	// (1) The tab direct-messages the vat. The button appears once the directory
	// has told the tab that this member can be introduced.
	const dmButton = tab.locator(`#members li:has-text("${VAT_NICK}") button.dm-btn`);
	await dmButton.waitFor({ state: "visible", timeout: WAIT_MS });
	await dmButton.click();
	await tab.waitForSelector("#line:not([disabled])", { timeout: WAIT_MS });
	await tab.fill("#line", TO_VAT);
	await tab.press("#line", "Enter");

	await until(
		() => vatSaid(new RegExp(`^DM FROM ${TAB_NICK}: ${TO_VAT}$`)),
		"the Goblins vat to receive the browser's direct message",
	);

	// (2) And the vat's answer, back over the connection that message arrived on,
	// painted in the tab's own thread.
	await tab.waitForFunction(
		(text) => [...document.querySelectorAll(".bubble")].some((b) => b.textContent?.includes(text)),
		FROM_VAT,
		{ timeout: WAIT_MS },
	).catch(() => fail(`the tab never rendered the vat's reply "${FROM_VAT}"`));

	// (3) The vat's own direct message, to a native glowcap member.
	//
	// This is the corner the other three do not reach. Here the give names a
	// *glowcap* exporter and a Goblins recipient redeems it, so the location the
	// room embedded has to be one the member will claim when the vat's dial lands,
	// not merely an address that reaches it: Goblins files each open session under
	// the location its partner claimed and looks a give's exporter location up in
	// that table by exact match. The room stamps the member's listen address,
	// which is dialable and is not what the member claimed on the room's own
	// connection, so the gifter composes the two.
	{
		await until(
			() => nativeInbox.includes(TO_NATIVE),
			"the native glowcap member to receive the vat's direct message",
		);
		await until(
			() => vatSaid(new RegExp(`^! could not direct message to ${NATIVE_NICK}:`)),
			"the Goblins vat to report the native member's asynchronous refusal",
		);
		if (vatSaid(new RegExp(`^DM SENT ${NATIVE_NICK}$`))) {
			fail("the vat narrated a refused direct message as sent");
		}
	}

	// (4) The conversation between the tab and the vat, on the live timeline.
	//
	// The vat reports what its netlayer can see at the wire, which is a session
	// opening and a session ending; per-message records are glowcap's own tap and
	// the vat has none. That is enough for the picture, because the two ends name
	// the session the same way: neither is ever told the name, and each derives it
	// from the two session keys the handshake exchanged. So the claim here is that
	// the direct conversation arrives from both ends under one session id.
	const opensNow = () => timeline.filter((r) => r.kind === "ocapn.session-opened");
	const sessionIdOf = (session: string): string | undefined =>
		opensNow().find((r) => r.session === session)?.session_id as string | undefined;
	/** The tab's own view of its direct line: the sessions it published a `dm` on.
	 * The room server carries none of a direct message, so a `dm` verb can only
	 * have come from a member's own tap. */
	const tabDmSessions = () =>
		new Set(
			timeline
				.filter((r) => r.kind === "ocapn.message-decoded" && r.op === "dm")
				.map((r) => r.session as string),
		);
	/** The same conversation as the vat reports it: a session the vat opened whose
	 * id matches one the tab is carrying a direct message on. */
	const vatSideOf = (wanted: Set<string>): string | undefined => {
		const ids = new Set([...wanted].map(sessionIdOf).filter((id) => id !== undefined));
		return opensNow().find((r) => r.a_profile === GOBLINS_PROFILE && ids.has(r.session_id as string))?.session as
			| string
			| undefined;
	};
	await until(
		() => tabDmSessions().size > 0 && vatSideOf(tabDmSessions()) !== undefined,
		"the tab's direct conversation with the vat to reach the timeline from both ends",
	);
	const tabSide = [...tabDmSessions()].find((s) => sessionIdOf(s) !== undefined);
	if (tabSide === undefined) fail("the tab's direct session reached the timeline with no open");
	const vatSide = vatSideOf(tabDmSessions());
	if (vatSide === undefined) fail("the vat published no end of the direct conversation");
	if (tabSide === vatSide) {
		fail(
			"both views of the direct conversation arrived under one scoped session, so the " +
				"endpoint did not keep the two producers apart",
		);
	}
	const sharedId = sessionIdOf(vatSide);
	if (typeof sharedId !== "string" || !/^[0-9a-f]{64}$/.test(sharedId)) {
		fail(`the direct session reached the timeline with no session id: ${sharedId}`);
	}

	// And the room is off its path. The vat holds two sessions — one to the room,
	// one to the tab — and this is the other one: its far end is not the room's
	// designator. That is the headline of a direct message stated in the picture
	// rather than only in the delivery.
	const roomDesignator = roomLocator.includes("://")
		? roomLocator.slice("ocapn://".length).split(".")[0]
		: roomLocator;
	const vatSessions = opensNow().filter((r) => r.a_profile === GOBLINS_PROFILE);
	if (!vatSessions.some((r) => r.b === roomDesignator)) {
		fail(
			`the vat published no session to the room itself (${roomDesignator}), so there is ` +
				`nothing to tell its direct line apart from: ${JSON.stringify(vatSessions.map((r) => r.b))}`,
		);
	}
	const vatSideOpen = opensNow().find((r) => r.session === vatSide);
	const tabSideOpen = opensNow().find((r) => r.session === tabSide);
	if (tabSideOpen === undefined || vatSideOpen === undefined) {
		fail("the direct conversation lost one opened-session provenance record");
	}
	// The browser's configured relay reports the exact iroh target it dialed, and
	// the far CapTP hello must claim that same key before the browser accepts its
	// testimony. The vat sees the relay's QUIC endpoint rather than the browser
	// Host, so that opposite view has no matching durable-peer proof.
	expectWireProvenance(
		tabSideOpen,
		"the browser's direct wire",
		IROH ? "authenticated-transport" : "unauthenticated",
	);
	expectWireProvenance(vatSideOpen, "the vat's direct wire", "unauthenticated");
	if (vatSideOpen.b === roomDesignator) {
		fail("the direct conversation was drawn on the vat's session to the room");
	}
	const vatRoomOpen = vatSessions.find((r) => r.b === roomDesignator);
	if (vatRoomOpen === undefined) fail("the vat's room session lost its provenance record");
	expectWireProvenance(
		vatRoomOpen,
		"the vat's room wire",
		IROH ? "authenticated-transport" : "unauthenticated",
	);

	// (5) Closing the conversation in the browser takes its session off the
	// timeline. The vat's own end is what says so, because a session ends when
	// its bytes do, and the vat is the end still standing after the tab hangs up.
	const closed = () =>
		new Set(
			timeline
				.filter((r) => r.kind === "ocapn.session-closed")
				.map((r) => r.session as string),
		);
	if (closed().has(vatSide)) fail("the direct conversation was already closed before the test");
	await confirmTitleLeave(tab);
	await until(
		() => closed().has(vatSide) && closed().has(tabSide),
		"both observations of the closed conversation to leave the live timeline",
	);

	// (6) Opening the same person's conversation again must mint a new session,
	// not leave the old one standing and add another edge beside it. The first
	// message forces lazy redemption of the fresh introduction; delivery and the
	// reply prove the replacement is usable, not merely connected.
	const opensBeforeReopen = opensNow().length;
	await dmButton.click();
	await tab.waitForSelector("#line:not([disabled])", { timeout: WAIT_MS });
	await tab.fill("#line", TO_VAT_AGAIN);
	await tab.press("#line", "Enter");
	await until(
		() => {
			rejectInvalidHandoff();
			return vatSaid(new RegExp(`^DM FROM ${TAB_NICK}: ${TO_VAT_AGAIN}$`));
		},
		"the Goblins vat to receive the reopened conversation's first message",
	);
	await tab.waitForFunction(
		(text) => [...document.querySelectorAll(".bubble")].some((b) => b.textContent?.includes(text)),
		`${REPLY_PREFIX}${TO_VAT_AGAIN}`,
		{ timeout: WAIT_MS },
	).catch(() => fail("the reopened conversation did not carry the Goblins vat's reply"));
	rejectInvalidHandoff();

	let reopened: Record<string, unknown>[] | undefined;
	await until(
		() => {
			const fresh = opensNow().slice(opensBeforeReopen);
			const byId = new Map<string, Record<string, unknown>[]>();
			for (const record of fresh) {
				const id = record.session_id;
				if (typeof id !== "string" || id === sharedId) continue;
				const records = byId.get(id) ?? [];
				records.push(record);
				byId.set(id, records);
			}
			reopened = [...byId.values()].find((records) =>
				records.length === 2 &&
				records.some((record) => record.a_profile === GOBLINS_PROFILE)
			);
			return reopened !== undefined;
		},
		"the reopened conversation to publish one new session from both ends",
	);
	const reopenedId = reopened![0].session_id as string;
	const reopenedSides = reopened!.map((record) => record.session as string);
	await confirmTitleLeave(tab);
	await until(
		() => reopenedSides.every((session) => closed().has(session)),
		"both observations of the reopened conversation to close",
	);

	console.log(
		`PASS (${GATE}): a browser held a direct message with a Spritely Goblins vat over ` +
			`${IROH ? "encrypted iroh QUIC" : "cleartext TCP"}. The tab redeemed a room ` +
			`introduction and reached the vat off-room; the vat answered over that same ` +
			`connection, which is the only way back to a tab that never listens; ` +
			`the vat started a direct message of its own, redeeming a give that named a ` +
			`glowcap member as its exporter, and reported that member's deliberate refusal without ` +
			`claiming the line was sent; the tab's conversation reached the live timeline from ` +
			`both ends under session id ${sharedId.slice(0, 12)}…, on a wire the room is not ` +
			`on; closing it retired both observations; and reopening started a distinct ` +
			`two-ended session ${reopenedId.slice(0, 12)}… only after the first had closed, ` +
			`then carried a new message and reply before closing cleanly`,
	);
} finally {
	if (closeViewer) await closeViewer().catch(() => {});
	if (browser) await browser.close().catch(() => {});
	if (nativeDir) await nativeDir.close().catch(() => {});
	if (nativeListener) nativeListener.close();
	if (nativeRuntime) await nativeRuntime.close().catch(() => {});
	for (const child of [vat, web]) {
		if (!child) continue;
		try {
			child.kill();
		} catch {
			// already gone
		}
		await child.status;
	}
}
Deno.exit(0);
