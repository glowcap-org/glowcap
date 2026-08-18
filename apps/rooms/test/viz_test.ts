// The live timeline endpoint, at the two seams a merged feed depends on.
//
// The pure half is the replay a connecting viewer gets: exactly the still-live
// sessions' opens, in seq order, marked `replay: true` so the viewer treats
// them as state. History is deliberately absent — a dead session's open/close
// pair replayed on connect materialized ghost topology at the start of every
// recording.
//
// The socket half is what merging feeds actually needs. Every producer numbers
// its own sessions from one, so two producers name their first session
// identically; the endpoint scopes each id by the connection it arrived on, and
// nothing a producer sends can claim a scope. Both ends of one session report
// it, and both views are forwarded: which of them to draw is the viewer's
// decision, and this endpoint is the transport. And a producer that goes away
// takes its topology with it, or a reloading viewer sees the ghosts of a peer
// that left.

import { parseRecord, replayLines, startViz, type VizServer } from "../server/viz.ts";
import { announceLines, publishUrl, vizCapUrl } from "../lib/viz_publish.ts";
import { Host, parseSturdyRef, Session, webSocketChannel } from "@pancake/runtime";
import type { TraceEvent } from "@pancake/runtime";
import { assertEquals } from "./assert.ts";

function assert(ok: boolean, what: string): void {
	if (!ok) throw new Error(what);
}

type Stamped = { seq: number; line: string };

/** The capability every socket here presents. Admission itself — a socket
 * refused without it, writes never landing — is `viz_cap_test.ts`'s subject. */
const CAP = "f0".repeat(32);

const stamp = (seq: number): Stamped => ({ seq, line: `{"seq":${seq}}` });
const replayed = (seq: number): string => `{"replay":true,"seq":${seq}}`;

Deno.test("replay is exactly the live opens, in seq order", () => {
	const liveOpens = new Map([
		["s2", stamp(7)],
		["s1", stamp(3)],
		["s3", stamp(400)],
	]);
	assertEquals(replayLines(liveOpens, new Map()), [
		replayed(3),
		replayed(7),
		replayed(400),
	]);
});

Deno.test("a live session's annotation replays beside its open", () => {
	// The label is state like the open is: a connecting viewer hears
	// who a live session carries. A meta for a session that already
	// closed replays nothing.
	const liveOpens = new Map([["s1", stamp(3)]]);
	const liveMetas = new Map([["s1", stamp(9)], ["dead", stamp(4)]]);
	assertEquals(replayLines(liveOpens, liveMetas), [
		replayed(3),
		replayed(9),
	]);
});

Deno.test("no live sessions replays nothing", () => {
	assertEquals(replayLines(new Map(), new Map()), []);
});

// ── What a producer may say ──────────────────────────────────────────────────

Deno.test("a producer line that is not a timeline record is refused", () => {
	assert(parseRecord("not json") === null, "non-JSON accepted");
	assert(parseRecord("[1,2,3]") === null, "array accepted");
	assert(
		parseRecord('{"v":2,"kind":"ocapn.session-opened","session":"s"}') === null,
		"wrong version accepted",
	);
	assert(
		parseRecord('{"v":1,"kind":"whatever","session":"s"}') === null,
		"unknown kind accepted",
	);
	assert(
		parseRecord('{"v":1,"kind":"ocapn.session-opened"}') === null,
		"missing session id accepted",
	);
	assert(
		parseRecord('{"v":1,"kind":"ocapn.session-opened","session":5}') === null,
		"non-string id accepted",
	);
	assert(
		parseRecord(`{"v":1,"kind":"ocapn.session-opened","session":"${"x".repeat(5000)}"}`) ===
			null,
		"unbounded id accepted",
	);
	assert(
		parseRecord('{"v":1,"kind":"ocapn.session-opened","session":"s","a":7}') === null,
		"non-string endpoint accepted",
	);
});

Deno.test("what a producer says about itself is bounded like everything else", () => {
	// A producer states two things about its own end beside the designator it
	// calls itself by: what it would like to be shown as, and what it says it
	// runs. Both reach a viewer, so both are checked for type and length here —
	// otherwise the shortest way to hand a viewer a megabyte is to publish a
	// session whose profile is a megabyte long.
	const line = (field: string, value: string) =>
		`{"v":1,"kind":"ocapn.session-opened","session":"s","${field}":${value}}`;
	for (const field of ["a_label", "a_profile"]) {
		assert(
			parseRecord(line(field, `"${"x".repeat(5000)}"`)) === null,
			`unbounded ${field} accepted`,
		);
		assert(parseRecord(line(field, "7")) === null, `non-string ${field} accepted`);
		const ok = parseRecord(line(field, '"pancake"'));
		assert(ok !== null, `an ordinary ${field} was refused`);
		assertEquals((ok as unknown as Record<string, unknown>)[field], "pancake");
	}
});

Deno.test("a producer cannot stamp its own seq, epoch, or replay mark", () => {
	// Those name the endpoint's own state. A producer that sends them would
	// otherwise be able to make a viewer drop live records (a huge seq), retire
	// live topology (a fresh epoch), or hide traffic (the replay mark).
	const rec = parseRecord(
		'{"v":1,"kind":"ocapn.session-opened","session":"s","seq":99999,"epoch":123,"replay":true}',
	);
	assert(rec !== null, "a well-formed record was refused");
	const fields = rec as unknown as Record<string, unknown>;
	assert(fields.seq === undefined, "producer seq survived");
	assert(fields.epoch === undefined, "producer epoch survived");
	assert(fields.replay === undefined, "producer replay mark survived");
});

Deno.test("publishUrl points at the producer half of an endpoint URL", () => {
	assertEquals(publishUrl("ws://127.0.0.1:9000/"), "ws://127.0.0.1:9000/publish");
	assertEquals(publishUrl("ws://127.0.0.1:9000/publish"), "ws://127.0.0.1:9000/publish");
});

Deno.test("a reconnecting producer re-announces its live topology and nothing else", () => {
	// A reconnect is a new scope at the endpoint, so the sessions this peer
	// still holds have to be named again under it. History must not come with
	// them: a record about a closed session would draw topology that is gone.
	const open = (id: string): TraceEvent => ({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		session: id,
	});
	const meta = (id: string): TraceEvent => ({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-meta",
		session: id,
		meta: { label: "bob" },
	});
	const opens = new Map([["s1", open("s1")]]);
	const metas = new Map([["s1", meta("s1")], ["gone", meta("gone")]]);
	assertEquals(announceLines(opens, metas), [
		JSON.stringify(open("s1")),
		JSON.stringify(meta("s1")),
	]);
});

// ── The endpoint over real sockets ───────────────────────────────────────────

/** A browser-shaped viewer: WebSocket is only the byte channel; records arrive
 * through an inbox capability after enlivening the announced sturdyref. */
class Viewer {
	readonly records: Record<string, unknown>[] = [];
	#host: Host;
	#session: Session;
	#closed: Promise<void>;
	#released = false;

	private constructor(host: Host, session: Session, closed: Promise<void>) {
		this.#host = host;
		this.#session = session;
		this.#closed = closed.finally(() => {
			if (this.#released) return;
			this.#released = true;
			return this.#host.close();
		});
	}

	static async connect(viz: VizServer): Promise<Viewer> {
		const port = await viz.ready;
		const sturdyref = await viz.sturdyref;
		const locator = parseSturdyRef(sturdyref, "v1_0").locator;
		const socket = new WebSocket(vizCapUrl(`ws://127.0.0.1:${port}/`, CAP));
		await opened(socket);
		const host = new Host(); // rooms-profile-exempt: production ocapnviz's v1.0 peer.
		const session = await Session.establishDialedLocator(
			host,
			locator,
			webSocketChannel(socket),
		);
		const closed = session.serve().catch(() => {});
		const viewer = new Viewer(host, session, closed);
		const inbox = session.spawn((verb, args) => {
			if (verb !== "record" || args.length !== 1 || typeof args[0] !== "string") {
				throw new Error("test inbox received an invalid record");
			}
			viewer.records.push(JSON.parse(args[0]));
			return null;
		});
		const trace = await session.enliven(sturdyref);
		await session.send(trace, "subscribe", [inbox]);
		return viewer;
	}

	close(): void {
		void this.#session.close();
	}

	waitClosed(): Promise<void> {
		return this.#closed;
	}

	of(kind: string): Record<string, unknown>[] {
		return this.records.filter((r) => r.kind === kind);
	}

	/** Wait until `want` records of `kind` have arrived, or fail loudly. */
	async expect(kind: string, want: number): Promise<Record<string, unknown>[]> {
		for (let i = 0; i < 200; i += 1) {
			const found = this.of(kind);
			if (found.length >= want) return found;
			await new Promise((r) => setTimeout(r, 10));
		}
		throw new Error(
			`expected ${want} ${kind} records, saw ${this.of(kind).length}: ` +
				JSON.stringify(this.records),
		);
	}
}

function opened(socket: WebSocket): Promise<void> {
	return new Promise((resolve, reject) => {
		socket.onopen = () => resolve();
		socket.onerror = () => reject(new Error("socket would not open"));
	});
}

async function publisher(port: number): Promise<WebSocket> {
	const socket = new WebSocket(vizCapUrl(`ws://127.0.0.1:${port}/publish`, CAP));
	await opened(socket);
	return socket;
}

/** One session-opened record as a producer would send it. */
function openRecord(session: string, self: string, partner: string, sessionId?: string): string {
	return JSON.stringify({
		v: 1,
		sim_t_ns: 1,
		kind: "ocapn.session-opened",
		session,
		a: self,
		b: partner,
		...(sessionId === undefined ? {} : { session_id: sessionId }),
	});
}

/** Give the endpoint a moment to apply what was just sent. */
function settle(): Promise<void> {
	return new Promise((r) => setTimeout(r, 60));
}

Deno.test("two producers' identical session ids stay apart", async () => {
	// The load-bearing one. Both producers name their first session `live-h1-s1`
	// because both count from one. Without a scope assigned here, a viewer would
	// braid two unrelated sessions into a single row.
	const viz = startViz(0, CAP);
	const port = await viz.ready;
	try {
		const viewer = await Viewer.connect(viz);
		const alice = await publisher(port);
		const bob = await publisher(port);
		alice.send(openRecord("live-h1-s1", "alice", "room"));
		bob.send(openRecord("live-h1-s1", "bob", "room"));
		const opens = await viewer.expect("ocapn.session-opened", 2);
		const ids = opens.map((r) => r.session as string);
		assert(ids[0] !== ids[1], `two producers collided on ${ids[0]}`);
		assert(
			ids.every((id) => id.endsWith("/live-h1-s1")),
			`a scoped id lost the producer's own name: ${JSON.stringify(ids)}`,
		);
		// And each producer's own endpoints survive the scoping untouched.
		assertEquals(opens.map((r) => r.a).sort(), ["alice", "bob"]);
		alice.close();
		bob.close();
		viewer.close();
	} finally {
		viz.close();
	}
});

Deno.test("the room's own trace is scoped like any other producer's", async () => {
	const viz = startViz(0, CAP);
	const port = await viz.ready;
	try {
		const viewer = await Viewer.connect(viz);
		const peer = await publisher(port);
		viz.sink({
			v: 1,
			sim_t_ns: 1,
			kind: "ocapn.session-opened",
			session: "live-h1-s1",
			a: "room",
			b: "member",
		});
		peer.send(openRecord("live-h1-s1", "member", "room"));
		const opens = await viewer.expect("ocapn.session-opened", 2);
		const ids = opens.map((r) => r.session as string);
		assert(ids[0] !== ids[1], "the local sink collided with a publisher");
		peer.close();
		viewer.close();
	} finally {
		viz.close();
	}
});

Deno.test("both ends of one wire reach the viewer", async () => {
	// A direct message is traced by BOTH members, and each reports the same
	// wire — the OCapN session identifier, which both ends derive. Forwarding
	// one and dropping the other would be a drawing decision made in the
	// transport, and it costs the dropped end's annotations and closes. So
	// both arrive, each carrying the wire name and the per-message tags the
	// viewer folds them together on.
	const wire = "a".repeat(64);
	const viz = startViz(0, CAP);
	const port = await viz.ready;
	try {
		const viewer = await Viewer.connect(viz);
		const alice = await publisher(port);
		const bob = await publisher(port);
		alice.send(openRecord("live-h1-s1", "alice", "bob", wire));
		await settle();
		bob.send(openRecord("live-h1-s1", "bob", "alice", wire));
		bob.send(JSON.stringify({
			v: 1,
			sim_t_ns: 2,
			kind: "ocapn.message-decoded",
			session: "live-h1-s1",
			op: "dm",
			digest: "ff".repeat(16),
		}));
		alice.send(JSON.stringify({
			v: 1,
			sim_t_ns: 2,
			kind: "ocapn.message-decoded",
			session: "live-h1-s1",
			op: "dm",
			digest: "ff".repeat(16),
		}));
		await viewer.expect("ocapn.message-decoded", 2);
		const opens = await viewer.expect("ocapn.session-opened", 2);
		assertEquals(opens.map((r) => r.a), ["alice", "bob"]);
		// The OCapN Session ID rides through untouched from both ends: it is
		// what tells the viewer these are two reports of one session.
		assertEquals(opens.map((r) => r.session_id), [wire, wire]);
		// The tag rides through untouched: it is what the viewer folds on.
		assertEquals(
			viewer.of("ocapn.message-decoded").map((r) => r.digest),
			["ff".repeat(16), "ff".repeat(16)],
		);
		alice.close();
		bob.close();
		viewer.close();
	} finally {
		viz.close();
	}
});

Deno.test("two different wires both draw", async () => {
	// Two producers arriving together are two conversations, and the endpoint
	// keeps their ids apart whatever wires they name.
	const viz = startViz(0, CAP);
	const port = await viz.ready;
	try {
		const viewer = await Viewer.connect(viz);
		const peer = await publisher(port);
		peer.send(openRecord("live-h1-s1", "alice", "bob", "a".repeat(64)));
		peer.send(openRecord("live-h1-s2", "alice", "carol", "b".repeat(64)));
		await viewer.expect("ocapn.session-opened", 2);
		peer.close();
		viewer.close();
	} finally {
		viz.close();
	}
});

Deno.test("one end closing a wire reaches the viewer", async () => {
	// The bug this replaces: whichever end the endpoint had chosen NOT to
	// forward could close its session and the feed stayed silent, so a direct
	// message closed from the receiving tab never ended in the picture.
	const wire = "c".repeat(64);
	const viz = startViz(0, CAP);
	const port = await viz.ready;
	try {
		const viewer = await Viewer.connect(viz);
		const alice = await publisher(port);
		const bob = await publisher(port);
		alice.send(openRecord("live-h1-s1", "alice", "bob", wire));
		await settle();
		bob.send(openRecord("live-h1-s1", "bob", "alice", wire));
		await viewer.expect("ocapn.session-opened", 2);
		bob.send(JSON.stringify({
			v: 1,
			sim_t_ns: 3,
			kind: "ocapn.session-closed",
			session: "live-h1-s1",
		}));
		const closes = await viewer.expect("ocapn.session-closed", 1);
		assert(
			(closes[0].session as string).endsWith("/live-h1-s1"),
			"the close named a different session",
		);
		alice.close();
		bob.close();
		viewer.close();
	} finally {
		viz.close();
	}
});

Deno.test("a producer that leaves takes its sessions with it", async () => {
	// A viewer that reloads must not meet the ghosts of a peer that left, and a
	// live viewer must hear the leaving as it happens.
	//
	// What it must NOT hear is a session CLOSE. A telemetry socket dropping is
	// a fact about this feed; whether the conversation behind it is still
	// running is not something anyone here observed, and `ocapn.` is the
	// vocabulary for what a producer observed. The endpoint reports the
	// departure and the viewer works out what that means for its picture.
	const viz = startViz(0, CAP);
	const port = await viz.ready;
	try {
		const viewer = await Viewer.connect(viz);
		const peer = await publisher(port);
		peer.send(openRecord("live-h1-s1", "alice", "room"));
		await viewer.expect("ocapn.session-opened", 1);
		peer.close();
		await viewer.expect("trace.producer-left", 1);
		assertEquals(viewer.of("ocapn.session-closed").length, 0);
		// And a viewer connecting afterwards replays no topology — it is told
		// the batch is over, and the batch is empty.
		const later = await Viewer.connect(viz);
		await settle();
		assertEquals(later.records.map((r) => r.kind), ["trace.replay-end"]);
		later.close();
		viewer.close();
	} finally {
		viz.close();
	}
});

Deno.test("a late viewer replays the live topology and no traffic", async () => {
	const viz = startViz(0, CAP);
	const port = await viz.ready;
	try {
		const peer = await publisher(port);
		peer.send(openRecord("live-h1-s1", "alice", "room"));
		peer.send(JSON.stringify({
			v: 1,
			sim_t_ns: 2,
			kind: "ocapn.session-meta",
			session: "live-h1-s1",
			meta: { label: "alice" },
		}));
		peer.send(JSON.stringify({
			v: 1,
			sim_t_ns: 3,
			kind: "ocapn.message-decoded",
			session: "live-h1-s1",
			op: "say",
		}));
		await settle();
		const viewer = await Viewer.connect(viz);
		await viewer.expect("ocapn.session-meta", 1);
		assertEquals(viewer.of("ocapn.session-opened").length, 1);
		assertEquals(viewer.of("ocapn.message-decoded").length, 0);
		assert(
			viewer.records.filter((r) => r.kind !== "trace.replay-end").every((r) => r.replay === true),
			"a replayed record was not marked as state",
		);
		peer.close();
		viewer.close();
	} finally {
		viz.close();
	}
});

Deno.test("a publisher receives nothing the endpoint forwards", async () => {
	// The socket goes one way by construction: telemetry converges, and a
	// producer connection must never become a channel between peers. The one
	// thing it ever hears is the endpoint's own admission mark, which forwards
	// nothing and names nobody.
	const viz = startViz(0, CAP);
	const port = await viz.ready;
	try {
		const alice = await publisher(port);
		const received: string[] = [];
		alice.onmessage = (msg) => received.push(String(msg.data));
		const bob = await publisher(port);
		bob.send(openRecord("live-h1-s1", "bob", "room"));
		await settle();
		const kinds = received.map((line) => (JSON.parse(line) as { kind?: string }).kind);
		assert(
			kinds.every((kind) => kind === "trace.publish-ready") && kinds.length <= 1,
			`a producer heard more than its admission: ${JSON.stringify(received)}`,
		);
		alice.close();
		bob.close();
	} finally {
		viz.close();
	}
});

Deno.test("a viewer is told where its replay ends", async () => {
	// One wire is TWO rows here, because both its ends report it. A viewer
	// drawing each row as it arrives would draw a stand-in for an end whose
	// name is further down the same batch, then take it back — inventing the
	// learning sequence a live feed genuinely goes through. The mark lets it
	// treat the batch as one picture instead.
	const viz = startViz(0, CAP);
	const port = await viz.ready;
	try {
		const peer = await publisher(port);
		peer.send(openRecord("live-h1-s1", "alice", "room", "wire-1"));
		await settle();
		const viewer = await Viewer.connect(viz);
		await viewer.expect("trace.replay-end", 1);
		// It comes last: everything before it is the batch.
		const last = viewer.records[viewer.records.length - 1];
		assertEquals(last?.kind, "trace.replay-end");
		assertEquals(viewer.records[0]?.kind, "ocapn.session-opened");
		// It carries no seq. Sequence numbers are global and drive every
		// viewer's dedup window; this record is sent to one viewer, so
		// advancing that window would make the next one skip a real record.
		assertEquals(last?.seq, undefined);
		assertEquals(typeof last?.epoch, "number");
		peer.close();
		viewer.close();
	} finally {
		viz.close();
	}
});

Deno.test("an empty replay completes and excludes the viewer's own session", async () => {
	// A viewer connecting to an idle endpoint has to learn that it has the
	// whole picture, and "nothing" is a whole picture. Without the mark it
	// would hold an empty batch until the first live record — and a quiet
	// room may not send one for minutes.
	const viz = startViz(0, CAP);
	try {
		const viewer = await Viewer.connect(viz);
		await viewer.expect("trace.replay-end", 1);
		await settle();
		assertEquals(viewer.records.length, 1);
	} finally {
		viz.close();
	}
});

Deno.test("a slow viewer is closed on overflow without taking the endpoint down", async () => {
	const viz = startViz(0, CAP);
	try {
		const viewer = await Viewer.connect(viz);
		await viewer.expect("trace.replay-end", 1);
		const open: TraceEvent = {
			v: 1,
			sim_t_ns: 0,
			kind: "ocapn.session-opened",
			session: "room-s1",
			a: "rooms",
			b: "alice",
		};
		// The first delivery is in flight while these synchronous writes fill the
		// bounded subscriber queue. Overflow is observable as closure of this
		// exact CapTP session, never as a silently stale "connected" viewer.
		for (let i = 0; i < 300; i += 1) viz.sink(open);
		let deadline: ReturnType<typeof setTimeout> | undefined;
		try {
			await Promise.race([
				viewer.waitClosed(),
				new Promise<never>((_, reject) => {
					deadline = setTimeout(
						() => reject(new Error("overflow did not close the viewer")),
						2_000,
					);
				}),
			]);
		} finally {
			if (deadline !== undefined) clearTimeout(deadline);
		}

		// Capacity belongs to subscriptions, not the endpoint. A fresh browser
		// peer can enliven the same durable capability and receive its snapshot.
		const replacement = await Viewer.connect(viz);
		await replacement.expect("trace.replay-end", 1);
		assertEquals(replacement.of("ocapn.session-opened").length, 1);
		replacement.close();
		await replacement.waitClosed();
	} finally {
		viz.close();
	}
});

Deno.test("a producer cannot forge the end of a replay", async () => {
	// Only this endpoint knows where one viewer's replay stops. A forged mark
	// would make a viewer commit half a snapshot as though it were whole,
	// which is the stand-in it would then have to take back.
	assertEquals(
		parseRecord(JSON.stringify({
			v: 1,
			sim_t_ns: 0,
			kind: "trace.replay-end",
			session: "s1",
		})),
		null,
	);
	// And it does not reach a viewer even when a producer sends one.
	const viz = startViz(0, CAP);
	const port = await viz.ready;
	try {
		const viewer = await Viewer.connect(viz);
		await viewer.expect("trace.replay-end", 1);
		const peer = await publisher(port);
		peer.send(JSON.stringify({
			v: 1,
			sim_t_ns: 0,
			kind: "trace.replay-end",
			session: "s1",
		}));
		peer.send(openRecord("live-h1-s1", "alice", "room", "wire-1"));
		await viewer.expect("ocapn.session-opened", 1);
		assert(
			viewer.of("trace.replay-end").length === 1,
			"a producer's forged end-of-replay reached a viewer",
		);
		peer.close();
		viewer.close();
	} finally {
		viz.close();
	}
});
