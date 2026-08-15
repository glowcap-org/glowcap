// A real Spritely Goblins vat joins the pancake rooms chat, and the room holds
// both profiles at once.
//
// Every peer in a room is a pancake peer, so the rooms fleet prefers pancake's
// own CapTP profile — `pancake-next` over Cap'n Proto — and this run keeps one
// pancake member in the room to hold that end. The other member is a genuine
// Goblins vat (`conformance/goblins-peer/racket/rooms-member.rkt`), which
// speaks the OCapN v1.0 baseline over Syrup and nothing else. Since ADR-0103
// each session settles its own pair from the two hellos, so the room admits
// both without either member being told in advance what the other is.
//
// The run proves four things, and asserts all four rather than assuming any:
//
//   1. The Goblins vat entered the room, posted a line, and heard the pancake
//      member's line come back through the capability the room calls it on.
//   2. The pancake member heard the Goblins vat's line the same way.
//   3. The two sessions settled on *different* profiles. The proof is the
//      server's own trace stream — the one ocapnviz's Live mode reads — where
//      each `ocapn.session-opened` names the codec and CapTP version the
//      handshake decided, and the `ocapn.session-meta` the room emits when a
//      member subscribes names which member that session carries.
//   4. The vat reports its own end of that session to the same stream, and the
//      two ends name the session identically. The vat is pointed at the
//      endpoint with `ROOMS_VIZ_URL`, so the wire it holds is described twice,
//      once from each side. A viewer draws one edge per OCapN Session ID, and
//      neither end is ever told that name — each derives it from the two
//      session keys the handshake exchanged. So this is where pancake's
//      derivation and Goblins's are held to the same bytes, and where the vat
//      stops being a loose end on the picture.
//
// Runs as `zig build goblins-rooms`; needs `deno`, `racket`, and the `goblins`
// collection on PATH.

import { readAnnouncedLocator } from "../../apps/rooms/lib/locator.ts";
import { runChild, stopSpawnedServer } from "../../apps/_demo/orchestrator.ts";
import { CAPTP_VERSION_WIRE, type TraceEvent } from "@pancake/runtime";
import { connectVizViewer, vizPortOf } from "../../apps/rooms/test/viz_viewer.ts";

/** `--iroh` runs the same room over encrypted QUIC instead of cleartext TCP.
 *
 * Nothing below changes for it. Both members dial a locator the server
 * announces, and an iroh locator is still a locator. What the flag exercises is
 * the accepting side: the room server's iroh listener proves each partner's
 * endpoint id in the QUIC handshake and passes it to the session
 * (`Session.bindVerifiedChannelKey`, ADR-0105). The open session therefore
 * reports authenticated transport provenance. */
const IROH = Deno.args.includes("--iroh");
const GATE = IROH ? "goblins-rooms-iroh" : "goblins-rooms";
const ROOT = Deno.cwd();
const ROOM = "goblins-and-pancake";
const PANCAKE_NICK = "deno-ada";
const GOBLINS_NICK = "goblins-carol";
const GOBLINS_LINE = "hello from a goblins vat";
/** What the Goblins vat calls its own implementation on the records it
 * publishes, and what the room server calls its own. Reading them off the trace
 * is how this harness tells one producer's view of a wire from the other's. */
const GOBLINS_PROFILE = "goblins";
const PANCAKE_PROFILE = "pancake";
const PANCAKE_LINE = "hello from a pancake peer";
/** How long the server has to say where it is listening. Finite, because a
 * server that never comes up must fail loud rather than park the step. */
const ANNOUNCE_MS = 30_000;

const DENO_FLAGS = ["run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env"];

/** Abandon the run. It throws rather than exiting so the server this harness
 * spawned is always reaped on the way out. */
function fail(message: string): never {
	throw new Error(message);
}

/** Read the server's stderr until it announces its trace capability, then keep
 * draining it to the log so anything the server says afterwards is visible when
 * a member fails. The room's own locator comes off stdout through
 * `readAnnouncedLocator`; this is the other announcement, and it is a sturdyref
 * rather than an address: a viewer enlivens it, and it names where the endpoint
 * listens for the producers that write to it. */
async function awaitVizSturdyref(stream: ReadableStream<Uint8Array>): Promise<string> {
	const reader = stream.getReader();
	const decoder = new TextDecoder();
	let buf = "";
	const deadline = Date.now() + ANNOUNCE_MS;
	while (Date.now() < deadline) {
		const { value, done } = await reader.read();
		if (done) break;
		buf += decoder.decode(value, { stream: true });
		const m = buf.match(/ROOMS-VIZ-LISTENING (\S+)/);
		if (m) {
			drainToLog(reader, decoder).catch(() => {});
			return m[1];
		}
	}
	reader.releaseLock();
	fail(`the rooms server never announced its trace broadcast\n${buf}`);
}

/** Keep printing what the server says for the rest of the run. Both of its
 * pipes get one of these once the announcements are read: a server left with a
 * pipe nobody empties eventually blocks on a write, and its diagnostics are
 * exactly what a failing member's log needs. Nothing awaits them. */
function drainRest(stream: ReadableStream<Uint8Array>): void {
	drainToLog(stream.getReader(), new TextDecoder()).catch(() => {});
}

async function drainToLog(
	reader: ReadableStreamDefaultReader<Uint8Array>,
	decoder: TextDecoder,
): Promise<void> {
	while (true) {
		const { value, done } = await reader.read();
		if (done) return;
		for (const line of decoder.decode(value, { stream: true }).split("\n")) {
			if (line.length > 0) console.log(`${GATE} server: ${line}`);
		}
	}
}

/** What the trace said about one session: the profile its handshake settled on,
 * the member the room annotated it with, and the two things that only matter
 * once more than one peer is reporting — who reported it, and the OCapN Session
 * ID both ends of it derive. */
interface SessionRow {
	codec?: string;
	captpVersion?: string;
	label?: string;
	selfProfile?: string;
	sessionId?: string;
}

/** Follow the server's live trace, the same way ocapnviz's Live mode does, and
 * keep one row per session.
 *
 * Records arrive through a capability rather than as frames off a socket: the
 * endpoint hands them to an inbox this viewer spawns, after enlivening the
 * sturdyref the server announced. `viz_viewer.ts` is the one place that
 * connection is made, so this harness reads the endpoint through exactly the
 * shape the browser proofs and production ocapnviz do.
 *
 * It resolves only once the viewer is subscribed, and the members are started
 * after that. The endpoint does replay the sessions that are live when a viewer
 * connects, but nothing replays a session that opened and closed in the gap, so
 * connecting first is what makes this a reading rather than a race. */
async function watchTrace(
	sturdyref: string,
): Promise<{ rows: Map<string, SessionRow>; close: () => Promise<void> }> {
	const rows = new Map<string, SessionRow>();
	const viewer = await connectVizViewer(vizPortOf(sturdyref), sturdyref, (record) => {
		const ev = record as unknown as TraceEvent;
		const row = rows.get(ev.session) ?? {};
		if (ev.kind === "ocapn.session-opened") {
			row.codec = ev.codec;
			row.captpVersion = ev.captp_version;
			row.selfProfile = ev.a_profile;
			row.sessionId = ev.session_id;
		} else if (ev.kind === "ocapn.session-meta" && ev.meta?.label) {
			row.label = ev.meta.label;
		} else return;
		rows.set(ev.session, row);
	});
	return { rows, close: () => viewer.close() };
}

/** The one session the room annotated with `label`, or a failure naming what the
 * trace did hold instead. */
function sessionOf(rows: Map<string, SessionRow>, label: string): SessionRow {
	const found = [...rows.values()].filter((r) => r.label === label);
	if (found.length !== 1) {
		const seen = [...rows.entries()]
			.map(([id, r]) => `${id}: ${r.label ?? "(no label)"} ${r.codec}/${r.captpVersion}`)
			.join("; ");
		fail(`the trace named ${found.length} sessions "${label}", wanted 1; it held ${seen}`);
	}
	return found[0];
}

/** The one session the Goblins vat reported about ITSELF, or a failure naming
 * what the trace did hold instead.
 *
 * The room server reports every session it carries; the vat reports the one it
 * holds. Both views reach this endpoint, and `a_profile` is what tells them
 * apart — the room server says `pancake` of its own end, the vat says
 * `goblins`. Nothing else on a record can: the two views of one wire agree on
 * the session id by design, which is the whole point of it. */
function vatSelfReport(rows: Map<string, SessionRow>): SessionRow {
	const found = [...rows.values()].filter((r) => r.selfProfile === GOBLINS_PROFILE);
	if (found.length !== 1) {
		const seen = [...rows.entries()]
			.map(([id, r]) => `${id}: ${r.selfProfile ?? "(no profile)"}`)
			.join("; ");
		fail(
			`${found.length} sessions were reported by a "${GOBLINS_PROFILE}" producer, wanted 1; the trace held ${seen}`,
		);
	}
	return found[0];
}

function expectProfile(
	row: SessionRow,
	label: string,
	codec: string,
	captpVersion: string,
): void {
	if (row.codec !== codec || row.captpVersion !== captpVersion) {
		fail(
			`${label}'s session settled ${row.codec}/${row.captpVersion}, wanted ${codec}/${captpVersion}`,
		);
	}
	console.log(`${GATE}: ${label} settled codec=${row.codec} captp=${row.captpVersion}`);
}

// The room server, on an ephemeral port, with its trace broadcast on another.
const server = new Deno.Command("deno", {
	// iroh addresses an endpoint by id, so there is no port to pin.
	args: IROH
		? [...DENO_FLAGS, `${ROOT}/apps/rooms/server/main.ts`]
		: [...DENO_FLAGS, `${ROOT}/apps/rooms/server/main.ts`, "0"],
	cwd: ROOT,
	env: IROH ? { ROOMS_VIZ_PORT: "0", ROOMS_TRANSPORT: "iroh" } : { ROOMS_VIZ_PORT: "0" },
	stdout: "piped",
	stderr: "piped",
}).spawn();

let failed = false;
let trace: { rows: Map<string, SessionRow>; close: () => void } | null = null;
try {
	// Both announcements come out before the first member dials: the trace URL on
	// stderr, the room's own locator on stdout.
	const vizRef = await awaitVizSturdyref(server.stderr);
	const locator = await readAnnouncedLocator(server, ANNOUNCE_MS);
	drainRest(server.stdout);
	console.log(`${GATE}: rooms server at ${locator}, live trace at ${vizRef}`);

	trace = await watchTrace(vizRef);
	// The vat is a producer rather than a viewer, and the two halves of this
	// endpoint are reached differently: a viewer enlivens the capability above,
	// while a producer opens a socket and writes records to it. So the vat is
	// told where the endpoint listens, which the endpoint itself names in the
	// sturdyref it announced.
	const publishUrl = `ws://127.0.0.1:${vizPortOf(vizRef)}/`;

	// Both members enter the same room and each waits to hear the other. The
	// pancake client posts once its whole roster is present; the Goblins vat
	// posts as soon as it has subscribed and waits for the pancake member's line.
	const roster = `${PANCAKE_NICK},${GOBLINS_NICK}`;
	const [pancake, goblins] = await Promise.all([
		runChild("deno", [
			...DENO_FLAGS,
			`${ROOT}/apps/rooms/clients/deno/client.ts`,
			locator,
			ROOM,
			PANCAKE_NICK,
			PANCAKE_LINE,
			roster,
		], ROOT),
		runChild(
			"racket",
			[
				"-y",
				`${ROOT}/conformance/goblins-peer/racket/rooms-member.rkt`,
				locator,
				ROOM,
				GOBLINS_NICK,
				GOBLINS_LINE,
				PANCAKE_NICK,
			],
			ROOT,
			{ ROOMS_VIZ_URL: publishUrl },
		),
	]);

	console.log(`──────── the pancake member (exit ${pancake.code}) ────────`);
	console.log(pancake.out.trimEnd());
	console.log(`──────── the goblins vat (exit ${goblins.code}) ────────`);
	console.log(goblins.out.trimEnd());
	console.log("");

	if (goblins.code !== 0 || !goblins.out.includes("ROOMS OK")) {
		fail("the goblins vat did not complete the exchange");
	}
	if (pancake.code !== 0) fail("the pancake member did not complete the exchange");
	if (!goblins.out.includes(PANCAKE_LINE)) {
		fail(`the goblins vat never heard "${PANCAKE_LINE}"`);
	}
	if (!pancake.out.includes(GOBLINS_LINE)) {
		fail(`the pancake member never heard "${GOBLINS_LINE}"`);
	}

	// The profiles, off the server's own trace rather than off either member's
	// word. A Goblins vat speaks only the baseline; the pancake member and the
	// server both prefer pancake-next over Cap'n Proto and get it.
	expectProfile(
		sessionOf(trace.rows, GOBLINS_NICK),
		GOBLINS_NICK,
		"syrup",
		CAPTP_VERSION_WIRE.v1_0,
	);
	expectProfile(
		sessionOf(trace.rows, PANCAKE_NICK),
		PANCAKE_NICK,
		"capnp",
		CAPTP_VERSION_WIRE.next,
	);

	// The vat is a PRODUCER here, not only a member: `ROOMS_VIZ_URL` above points
	// it at the same endpoint the server publishes to, so the wire it holds is
	// reported from both of its ends. What has to hold is that the two reports
	// name one wire and not two — a viewer draws one edge per OCapN Session ID,
	// so if the vat and the server derived that name differently the room would
	// be drawn with the vat twice over, once as a peer and once as a loose end.
	//
	// Neither end is told the name. Each derives it from the two session keys
	// the handshake already exchanged, so this is also the assertion that
	// pancake's derivation and Goblins's agree byte for byte.
	const serverView = sessionOf(trace.rows, GOBLINS_NICK);
	const vatView = vatSelfReport(trace.rows);
	if (serverView.selfProfile !== PANCAKE_PROFILE) {
		fail(
			`the room server reported its own end as "${serverView.selfProfile}", wanted "${PANCAKE_PROFILE}"`,
		);
	}
	if (!vatView.sessionId || !serverView.sessionId) {
		fail(
			`a session was reported with no OCapN Session ID: vat ${vatView.sessionId}, server ${serverView.sessionId}`,
		);
	}
	if (vatView.sessionId !== serverView.sessionId) {
		fail(
			`the two ends of one session named it differently: the vat says ${vatView.sessionId}, the room server says ${serverView.sessionId}`,
		);
	}
	console.log(
		`${GATE}: both ends of ${GOBLINS_NICK}'s session named it ${vatView.sessionId}`,
	);

	console.log(
		`${GATE} OK: a real Goblins vat and a pancake peer held one room, each on the profile its own session settled`,
	);
} catch (err) {
	failed = true;
	console.error(`${GATE} FAILED: ${err instanceof Error ? err.message : err}`);
} finally {
	await trace?.close();
	await stopSpawnedServer(server);
}

Deno.exit(failed ? 1 : 0);
