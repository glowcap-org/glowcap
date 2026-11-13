import { spawnWeb, webAnnouncements, webPort } from "../support/web_front.ts";
/// <reference lib="dom" />
// What the visualizer draws, all the way through a member's life in a room.
//
// This is the whole-picture proof. Every other trace test checks one fact about
// one hop; this one drives two real browser tabs through joining a room,
// direct-messaging each other, leaving, closing, reopening, and going away, and
// after each step asks the question a person watching ocapnviz asks: how many
// peers are on screen, how many sessions, and which peers are on the ends of
// each one.
//
// It answers with ocapnviz's OWN converter, imported and run over the endpoint's
// feed exactly as the viewer runs it. Counting the raw records instead would
// prove the feed carries something; running the converter proves the picture is
// right, and it is the picture the request was about.
//
// The shape it holds:
//
//   - two members in a room are THREE peers, not five. A tab publishes its own
//     trace and names itself by its key designator, and the room reports the
//     same tab from the other end of the same wire. Those two views join on the
//     name both ends of a CapTP session derive, so one tab is one node.
//   - a direct message is a session between the two tabs, with the room off its
//     path, and it draws once, from two ends reporting it, because each message
//     carries a tag over its own wire bytes.
//   - room lines travel on the room sessions and direct lines on the direct one.
//   - leaving a room does NOT close the session to the room server: the
//     connection is still there, and what changes is that the room stops
//     knowing it by a nickname.
//   - closing the side that opened a direct message closes its session. The
//     adopted side releases its conversation without closing the shared
//     incoming session out from under other capabilities.
//   - a tab going away takes its peer and every session it held.
//
// Needs deno, the wasm module (`zig build wasm-host`), the installed archives,
// and a Playwright Chromium (the devcontainer image ships one).
// Run: `zig build rooms-web-trace-lifecycle`.

import { type Browser, chromium } from "playwright";
import { TYPING_CLEAR_MS } from "../../lib/limits.ts";
import { connectTraceViewer } from "../trace/viewer.ts";
import { endConversation, openConv } from "../trace/drive.ts";
import { endpointPeer, type StageEvent, statesOnlyWhatHappened, str } from "../trace/timeline.ts";
import { fail } from "../support/fail.ts";
import { joinAs } from "../support/join.ts";
import { awaitBubble, openDmTo, say } from "../page/harness.ts";
import { reapOwned } from "../support/children.ts";
import { waitForHttp } from "../support/rooms_server.ts";
import { until } from "../support/wait.ts";
/** One record off the endpoint, as the converter takes it. An open record:
 * this file states no structure of its own for it. */
type FeedRecord = Record<string, unknown>;

// ocapnviz is its own Deno scope, the root `deno.json` excludes it, so its
// converter is reached by URL rather than by a specifier the root scope's
// type-checker would follow into imports it cannot resolve. What runs is the
// real one: the picture below is ocapnviz's own projection rather than a
// second copy of it, so a merge this proof accepts is a merge the viewer
// makes.
//
// The schema comes with it, and that is what makes the arrangement safe. A
// dynamic import is untyped, so a structural copy of `TimelineEvent` declared
// here would be an assertion nothing checks, and it drifted exactly that way
// once, leaving three assertions reading fields and kinds the viewer had
// stopped emitting while the run still said PASS. So there is no copy. Every
// converted event is parsed by `Observation`, ocapnviz's own definition of what
// its timeline events are, and every kind this file switches on is confirmed to
// be one the schema still declares before the browsers start.
const { makeBaseEventConverter } = await import(
	new URL("../../../ocapnviz/src/engine/live/feed.ts", import.meta.url).href
) as { makeBaseEventConverter: () => (ev: FeedRecord) => unknown[] };
const { Observation } = await import(
	new URL("../../../ocapnviz/src/engine/temporal/recording.ts", import.meta.url).href
) as {
	Observation: { parse(value: unknown): StageEvent; options?: unknown };
};

/** Every event kind this proof reads. Checked against the schema below, so a
 * kind the viewer renames stops this run instead of quietly turning one of the
 * assertions into a branch nothing takes. */
const HANDLED_KINDS = [
	"peer-joined",
	"peer-updated",
	"peer-left",
	"peer-unobserved",
	"session-opened",
	"session-endpoint-attributed",
	"session-closed",
	"session-unobserved",
	"message-sent",
] as const;

/** The kinds ocapnviz's `Observation` declares. It is a zod discriminated
 * union, so the kinds are its members' `kind` literals. Anything else here is
 * this reader having gone stale against zod itself, which fails loudly rather
 * than answering an empty set. */
function schemaKinds(): Set<string> {
	const options = (Observation as { options?: unknown }).options;
	if (!Array.isArray(options)) {
		fail("ocapnviz's Observation is no longer a union this proof can read its kinds from");
	}
	const kinds = new Set<string>();
	for (const option of options) {
		const literal = (option as { shape?: { kind?: { value?: unknown } } }).shape?.kind?.value;
		if (typeof literal !== "string") {
			fail(
				"an Observation member has no readable `kind` literal; update this proof's reader",
			);
		}
		kinds.add(literal);
	}
	return kinds;
}

const ROOT = new URL("../../../../", import.meta.url).pathname;
const ROOM = "general";
const NICK1 = "nick1";
const NICK2 = "nick2";

// ── The picture ──────────────────────────────────────────────────────────────

/** One session on stage, by the two peers on its ends. An end is null while it
 * is loose: drawn, but attached to no peer yet. */
type Edge = { a: string | null; b: string | null };

/** What a viewer has on screen: the live peers with the names they answer to,
 * the live sessions with their endpoints, and every message drawn so far. This
 * is the projection ocapnviz's renderer reads, folded to the parts the request
 * asked about. */
class Picture {
	#convert = makeBaseEventConverter();
	labels = new Map<string, string>();
	edges = new Map<string, Edge>();
	messages: { session: string; from: string; to: string; op: string | undefined }[] = [];
	/** Every event the converter produced, in order. The counts above say what
	 * is on screen. This says what the timeline CLAIMS happened, and the two
	 * are different questions. A blip that opens and closes between two polls
	 * leaves the counts untouched and this record damning. */
	journal: StageEvent[] = [];

	apply(record: FeedRecord): void {
		for (const raw of this.#convert(record)) {
			// The boundary check: an event the viewer's own schema will not accept
			// is a converter this proof does not understand, and it stops here
			// rather than being read field by field on a guess.
			const ev = Observation.parse(raw);
			this.journal.push(ev);
			const peerId = str(ev, "peerId") ?? "";
			const sessionId = str(ev, "sessionId") ?? "";
			switch (str(ev, "kind")) {
				case "peer-joined":
					this.labels.set(peerId, str(ev, "label") ?? peerId);
					break;
				case "peer-updated": {
					const label = str(ev, "label");
					if (label !== undefined) this.labels.set(peerId, label);
					break;
				}
				case "peer-left":
				// The viewer stopped being able to see it. The row ends either way;
				// what differs is whether the timeline claims the network did it.
				case "peer-unobserved":
					this.labels.delete(peerId);
					break;
				case "session-opened":
					this.edges.set(sessionId, {
						a: endpointPeer(ev, "a"),
						b: endpointPeer(ev, "b"),
					});
					break;
				// The viewer learned who is on one end of a session it had already
				// drawn. The session keeps its identity, because on the wire nothing
				// happened: an end that was only a claim becomes attached to a peer.
				case "session-endpoint-attributed": {
					const edge = this.edges.get(sessionId);
					const side = str(ev, "side");
					if (edge !== undefined && (side === "a" || side === "b")) {
						edge[side] = peerId;
					}
					break;
				}
				case "session-closed":
				case "session-unobserved":
					this.edges.delete(sessionId);
					break;
				case "message-sent":
					this.messages.push({
						session: sessionId,
						from: str(ev, "from") ?? "",
						to: str(ev, "to") ?? "",
						op: str(ev, "label"),
					});
					break;
			}
		}
	}

	/** The stage id of the one peer answering to `label`, or null. */
	peerNamed(label: string): string | null {
		for (const [id, name] of this.labels) if (name === label) return id;
		return null;
	}

	/** True when a live session joins the two peers answering to these names. */
	joins(one: string, two: string): boolean {
		return this.edgeBetween(one, two) !== null;
	}

	edgeBetween(one: string, two: string): string | null {
		const a = this.peerNamed(one);
		const b = this.peerNamed(two);
		if (a === null || b === null) return null;
		return this.edgeBetweenIds(a, b);
	}

	/** The live session joining these two stage peers, by id. Assertions past
	 * the opening one use this: a peer's name changes as the room's claim about
	 * it changes, and its IDENTITY is the thing that must not. */
	edgeBetweenIds(a: string, b: string): string | null {
		for (const [id, edge] of this.edges) {
			if ((edge.a === a && edge.b === b) || (edge.a === b && edge.b === a)) return id;
		}
		return null;
	}

	describe(): string {
		const peers = [...this.labels.values()].sort().join(", ");
		const name = (end: string | null) => end === null ? "?" : this.labels.get(end) ?? end;
		const edges = [...this.edges.values()]
			.map((e) => `${name(e.a)}–${name(e.b)}`)
			.sort()
			.join(", ");
		return `peers {${peers}} sessions {${edges}}`;
	}
}

/** Watch the endpoint the way ocapnviz does, keeping the projected picture up
 * to date as records arrive: the WebSocket is only the byte channel, and
 * records arrive through an inbox capability after enlivening the sturdyref
 * the server announced. */
async function watch(sturdyref: string): Promise<Picture> {
	const picture = new Picture();
	await connectTraceViewer(sturdyref, (record) => picture.apply(record as FeedRecord));
	return picture;
}

/** Wait until the picture satisfies `want`, or fail saying what it held. The
 * feed is asynchronous at every hop, so every assertion below is a wait: a
 * fixed sleep would be a race dressed as a delay. */
async function settles(
	picture: Picture,
	what: string,
	want: (p: Picture) => boolean,
	timeoutMs = 30_000,
): Promise<void> {
	await until(() => want(picture), what, timeoutMs).catch(() =>
		fail(`${what}; the picture held ${picture.describe()}`)
	);
	console.log(`  ok: ${what} — ${picture.describe()}`);
}

/** Give a step that should change NOTHING a moment to prove it. */
function pause(ms = 2_500): Promise<void> {
	return new Promise((r) => setTimeout(r, ms));
}

// Before anything is launched: every kind the reader above switches on is one
// the viewer's schema still declares. This is the check that would have caught
// the drift this file once carried, where two of its cases named kinds ocapnviz
// had renamed and the run kept saying PASS.
{
	const declared = schemaKinds();
	const gone = HANDLED_KINDS.filter((kind) => !declared.has(kind));
	if (gone.length > 0) {
		fail(
			`this proof reads ${gone.join(", ")}, which ocapnviz's Observation schema no longer ` +
				`declares. It declares ${[...declared].sort().join(", ")}.`,
		);
	}
}

const deadline = setTimeout(() => fail("web-trace-lifecycle timed out after 300s"), 300_000);

const web = spawnWeb({
	args: ["--transport=tcp", "0", "0"],
	cwd: ROOT,
	env: { GLOWCAP_ROOMS_CAPABILITIES: "trace", GLOWCAP_ROOMS_TRACE_PORT: "0" },
	stdout: "piped",
	stderr: "piped",
});
const traceRef = webAnnouncements(web).line("ROOMS-TRACE-LISTENING", "rooms-web");
const httpPort = await webPort(web);

let browser: Browser | null = null;
try {
	await waitForHttp(httpPort);
	const picture = await watch(await traceRef);
	// The endpoint admits only capability-presenting sockets, so each tab is
	// seeded with the remembered trace swiss a reader would have kept.
	const trace = await traceRef;
	browser = await chromium.launch({ args: ["--no-sandbox"] });

	// ── Two members in one room: three peers, two sessions ──
	const tab1 = await joinAs(browser, httpPort, NICK1, { room: ROOM, trace });
	const tab2 = await joinAs(browser, httpPort, NICK2, { room: ROOM, trace });
	await settles(
		picture,
		"two members in a room are three peers and two sessions",
		(p) =>
			p.labels.size === 3 &&
			p.edges.size === 2 &&
			p.peerNamed("rooms") !== null &&
			p.joins("rooms", NICK1) &&
			p.joins("rooms", NICK2),
	);

	// The three nodes, by identity. Every assertion below is against these
	// rather than against names: what the room calls a member changes as its
	// membership does, and the node underneath must not.
	const roomsPeer = picture.peerNamed("rooms");
	const peer1 = picture.peerNamed(NICK1);
	const peer2 = picture.peerNamed(NICK2);
	if (roomsPeer === null || peer1 === null || peer2 === null) {
		fail("the three peers were counted but could not be named");
	}
	const roomEdge1 = picture.edgeBetweenIds(roomsPeer, peer1);
	const roomEdge2 = picture.edgeBetweenIds(roomsPeer, peer2);
	if (roomEdge1 === null || roomEdge2 === null) fail("a room session vanished");

	// The capture opens a session every six seconds.
	// Observe two full periods, including opens that close between samples.
	const beforeIdle = picture.journal.length;
	await pause(13_000);
	const idleChanges = picture.journal.slice(beforeIdle).filter((event) => {
		const kind = str(event, "kind");
		return kind === "session-opened" || kind === "session-closed" || kind === "session-unobserved";
	});
	if (idleChanges.length !== 0) {
		fail(`idle room sessions churned: ${JSON.stringify(idleChanges)}`);
	}
	console.log("  ok: idle room sessions stay open without transient replacements");

	// ── A direct message: a third session, between the two members ──
	// Everything the timeline says while this is happening is recorded, because
	// the count-based assertion below cannot see a session that opens and ends
	// between two polls, and an invented ending is exactly what this step used
	// to produce.
	const duringDm = picture.journal.length;
	await openDmTo(tab1, NICK2);
	await say(tab1, "first direct line");
	await openDmTo(tab2, NICK1);
	await awaitBubble(tab2, "first direct line", NICK2);
	await settles(
		picture,
		"a direct message adds a session between the two members, room untouched",
		(p) =>
			p.labels.size === 3 &&
			p.edges.size === 3 &&
			p.edgeBetweenIds(peer1, peer2) !== null &&
			p.edges.has(roomEdge1) &&
			p.edges.has(roomEdge2),
	);
	const dmEdge = picture.edgeBetweenIds(peer1, peer2);
	if (dmEdge === null) fail("the direct session vanished between assertions");
	statesOnlyWhatHappened(
		picture.journal.slice(duringDm),
		"opening a direct message opened one session and closed nothing",
	);
	console.log("  ok: opening a direct message stated nothing that did not happen");

	// ── A second viewer sees the same picture and never had to learn it ──
	// Stopping a recording and starting another builds a fresh converter and
	// asks the endpoint for the topology again. Every live session's open comes
	// back, and one wire is TWO of those, because both its ends report it. Fed
	// one at a time that would re-run the whole learning sequence, which is
	// honest live and a fabrication here: both ends are in the batch before
	// anything is drawn, so there was never a moment the viewer did not know.
	// The negative below says a viewer handed the whole topology at once learns
	// nothing. That is only worth stating if learning is a thing this feed does,
	// so the live viewer is asked first: it drew ends before it knew them, and
	// said so. Without this the negative passes on a kind nobody emits.
	if (!picture.journal.some((e) => str(e, "kind") === "session-endpoint-attributed")) {
		fail(
			"the live viewer never attributed a session end, so it learned nothing to compare against",
		);
	}

	const rejoined = await watch(await traceRef);
	await settles(
		rejoined,
		"a viewer joining now sees the room and the direct message already there",
		(p) =>
			p.labels.size === 3 &&
			p.edges.size === 3 &&
			p.peerNamed("rooms") !== null &&
			p.joins("rooms", NICK1) &&
			p.joins("rooms", NICK2) &&
			p.edgeBetween(NICK1, NICK2) !== null,
	);
	const learned = rejoined.journal.filter((e) => str(e, "kind") === "session-endpoint-attributed");
	if (learned.length > 0) {
		fail(
			`a viewer handed the whole topology at once reported learning ${learned.length} thing(s) it was told outright: ` +
				learned.map((e) => str(e, "sessionId")).join(", "),
		);
	}
	// The same claim from the other side: a session drawn from a batch holding
	// both its ends has nothing left to attribute, so neither end may be loose.
	const loose = rejoined.journal.filter((e) =>
		str(e, "kind") === "session-opened" &&
		(endpointPeer(e, "a") === null || endpointPeer(e, "b") === null)
	);
	if (loose.length > 0) {
		fail(`a resolved snapshot drew ${loose.length} session end(s) it could have named`);
	}
	console.log("  ok: a second viewer was told the picture rather than learning it");

	// ── Direct lines travel on the direct session ──
	const before = picture.messages.length;
	await say(tab2, "and one back");
	await awaitBubble(tab1, "and one back", NICK1);
	await settles(
		picture,
		"the direct line travelled on the direct session",
		(p) => p.messages.slice(before).some((m) => m.session === dmEdge && m.op === "dm"),
	);
	const strays = picture.messages.slice(before).filter((m) => m.op === "dm" && m.session !== dmEdge);
	if (strays.length > 0) {
		fail(`a direct message was drawn on ${strays.length} session(s) other than the direct one`);
	}

	// ── Room lines travel on the room sessions ──
	// Both tabs look at the room again: a line only renders in the conversation
	// on screen, and this step is about where it TRAVELS.
	await openConv(tab1, `.room-open:has-text("${ROOM}")`);
	await openConv(tab2, `.room-open:has-text("${ROOM}")`);
	const beforeRoom = picture.messages.length;
	// Typed a key at a time, the way a person writes it, so the line is
	// preceded by a typing start the other member is shown.
	const composer = tab1.locator("#line:not(:disabled):not([inert] *)");
	const fromSender = (from: number) => picture.messages.slice(from).filter((m) => m.from === peer1).map((m) => m.op);
	const shownTyping = () =>
		tab2.waitForFunction(
			(name) => {
				const said = document.getElementById("typing");
				return said?.classList.contains("show") === true && (said.textContent ?? "").includes(name);
			},
			NICK1,
			{ timeout: 30_000 },
		).catch(() => fail("the other member was not shown that the first is typing"));
	// The watch starts before the first key, so it sees the indicator
	// however long this host takes to draw it.
	const shown = shownTyping();
	await composer.pressSequentially("hello the roo", { delay: 20 });
	await shown;
	// The last key keeps the level on, so the line and not a pause ends it.
	await composer.press("m");
	await shownTyping();
	const beforeSend = picture.messages.length;
	// Sent with the button, the one way a phone sends, and it keeps the caret.
	await tab1.locator("#sendBtn:not(:disabled):not([inert] *)").click();
	if (!await composer.evaluate((field) => document.activeElement === field)) fail("Send took the caret away");
	await awaitBubble(tab2, "hello the room", NICK2);
	// The line itself ends the indicator, well inside the wait a reader gives
	// a flag nobody renewed.
	await tab2.waitForFunction(
		() => document.getElementById("typing")?.classList.contains("show") !== true,
		undefined,
		{ timeout: TYPING_CLEAR_MS / 3 },
	).catch(() => fail("the line arrived and its author was still shown as typing"));
	await settles(
		picture,
		"the room line travelled on the room sessions",
		(p) => {
			const since = p.messages.slice(beforeRoom);
			return since.some((m) => m.op === "postCorrelated" && m.session === roomEdge1) &&
				since.some((m) => m.op === "notify" && m.session === roomEdge2);
		},
	);
	// Sending asks the room for the line and nothing else: the line is its
	// own typing stop. A changed draft is no reason to ask the directory about
	// this tab's registration, so at most one such question falls in the
	// span, when the directory's last answer had grown old.
	await pause();
	const typing = fromSender(beforeRoom);
	const sending = fromSender(beforeSend).filter((op) => op !== "signalCheck");
	if (
		typing.filter((op) => op === "signalCheck").length > 1 || sending.length !== 1 ||
		sending[0] !== "postCorrelated"
	) {
		fail(`a typed room line asked for more than its typing and the line: ${typing.join(", ")}`);
	}
	console.log(`  ok: the sender asked the room for ${typing.join(", ")}`);

	// A line sent the moment it is written can leave while its typing start
	// is still on its way. The start reaches the room ahead of the line, so
	// the line is the last thing its sender asks. A typing call behind it is
	// a start nothing ends or a stop the line already made.
	const beforeFilled = picture.messages.length;
	await say(tab1, "sent as written");
	await awaitBubble(tab2, "sent as written", NICK2);
	await pause();
	const filled = fromSender(beforeFilled).filter((op) => op !== "signalCheck").join(", ");
	if (filled !== "typing, postCorrelated" && filled !== "postCorrelated") {
		fail(`a line sent as it was written was not the last thing its sender asked: ${filled}`);
	}
	console.log(`  ok: a line sent as it was written asked the room for ${filled}`);

	// Directory registration and room membership have independent lifetimes.
	// Leaving the room keeps the registered name and both held connections.
	await endConversation(tab2, `.room-open:has-text("${ROOM}")`);
	await settles(
		picture,
		"leaving the room kept its directory registration and both connections",
		(p) =>
			p.labels.size === 3 &&
			p.edges.size === 3 &&
			p.labels.get(peer2) === NICK2 &&
			p.labels.has(peer2) &&
			p.edges.has(roomEdge2) &&
			p.edges.has(dmEdge),
	);

	// Either member can end the direct conversation. Its final local user closes
	// the connection, while both independent directory registrations stay held.
	await endConversation(tab2, `.dm-open:has-text("${NICK1}")`);
	await settles(
		picture,
		"closing the received direct conversation left only the directory connections",
		(p) =>
			p.labels.size === 3 && p.edges.size === 2 && !p.edges.has(dmEdge) &&
			p.edges.has(roomEdge1) && p.edges.has(roomEdge2),
	);
	// Put the receiving member back in the room before the opener releases its closed row.
	// The still-held directory registration supplies the same nickname.
	await tab2.fill("#nick", NICK2);
	await tab2.fill("#room", ROOM);
	await tab2.click("#joinBtn");
	await tab2.waitForSelector(`.room-open:has-text("${ROOM}")`, { state: "visible", timeout: 30_000 });
	await tab2.waitForSelector("#line:not([disabled])", { timeout: 30_000 });
	await settles(
		picture,
		"the receiving member rejoined through its retained directory connection",
		(p) => p.labels.get(peer2) === NICK2 && p.edges.has(roomEdge2) && !p.edges.has(dmEdge),
	);
	await endConversation(tab1, `.dm-open:has-text("${NICK2}")`);
	await settles(
		picture,
		"releasing the opener's closed row preserved three peers and the two directory sessions",
		(p) => p.labels.size === 3 && p.edges.size === 2 && !p.edges.has(dmEdge),
	);

	// ── Reopening it opens a new one, between the same two peers ──
	await openDmTo(tab1, NICK2);
	await say(tab1, "back again");
	await settles(
		picture,
		"reopening the direct message drew a second session between the same two members",
		(p) => {
			const again = p.edgeBetweenIds(peer1, peer2);
			return p.labels.size === 3 && p.edges.size === 3 && again !== null && again !== dmEdge;
		},
	);

	// ── A tab going away takes its peer and its sessions ──
	await tab2.context().close();
	await settles(
		picture,
		"the closed tab's peer and both its sessions left, leaving two peers and one session",
		(p) =>
			p.labels.size === 2 &&
			p.edges.size === 1 &&
			!p.labels.has(peer2) &&
			p.edgeBetweenIds(roomsPeer, peer1) !== null,
		60_000,
	);
	// And it stays settled rather than flickering back.
	await pause();
	if (picture.labels.size !== 2 || picture.edges.size !== 1) {
		fail(`the picture would not settle: ${picture.describe()}`);
	}

	console.log(`PASS: ${picture.describe()}`);
} finally {
	clearTimeout(deadline);
	if (browser) await browser.close().catch(() => {});
	await reapOwned();
}
Deno.exit(0);
