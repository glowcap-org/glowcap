// The live timeline endpoint: one WebSocket that carries the room's own
// sessions AND every other peer's, in the versioned timeline schema ocapnviz's
// Live mode consumes. Point the viewer's "Live feed…" URL at
// `ws://127.0.0.1:<port>/` and the topology draws as it happens.
//
// Two kinds of socket connect here. A VIEWER connects to `/` and receives; a
// PRODUCER connects to `/publish` and sends, one JSON record per line, and
// receives nothing. That split is what lets a direct message appear at all: a
// DM is a session between two members, held on the members' own hosts, and the
// room server never sees a byte of it. Telemetry converges here; the traffic
// stays direct. Nothing a producer sends can reach another peer — this endpoint
// only ever forwards to viewers.
//
// The endpoint, not the producer, owns every name and number a viewer keys on:
//
//   - the PRODUCER SCOPE each session id is prefixed by. Every producer mints
//     its session ids from a counter that starts at one, so two producers both
//     name their first session `live-h1-s1`. Merging feeds without a scope
//     would braid unrelated sessions into one. The scope is assigned here, at
//     connect, rather than claimed by the producer, so it can neither collide
//     nor be spoofed.
//   - `seq`, monotone, so a reconnecting viewer drops what it already applied.
//   - `epoch`, this endpoint's start, so a viewer can tell a RESTARTED endpoint
//     from a resumed one and retire the dead process's topology.
//   - `sim_t_ns`, restamped on arrival. Two producers share no time origin, so
//     arrival here is the only clock the merged stream has in common.
//
// Two peers of one session both trace it, and each reports the same wire (the
// OCapN session identifier, which both ends derive). BOTH views are forwarded.
// Choosing one and dropping the other is a drawing decision, and this is the
// transport: the dropped view carries the annotations, the closes, and the
// half of the conversation only that end can see, and none of it comes back.
// So the endpoint forwards what it is told and the viewer decides what to
// draw — it can, because each message carries a tag over its own wire bytes
// that both ends derive alike, so two sightings of one message fold together
// there without anything being discarded here.
//
// A connecting viewer needs the topology that exists NOW — and nothing else.
// The replay is exactly the still-live sessions' opens, each followed by its
// latest annotation when one was set, all marked `replay: true` so the viewer
// treats them as state; history is deliberately not replayed (a dead session's
// open/close pair would materialize ghost topology at the start of every
// recording, and the viewer drops replayed messages regardless). The batch ends
// with `trace.replay-end`, so the viewer knows when it has the whole picture:
// one wire is two rows here, and a viewer drawing them one at a time would
// invent the same learning sequence a live feed genuinely goes through.

import type { TraceEvent } from "@pancake/stack";
import { VIZ_PUBLISH_PATH } from "../lib/viz_publish.ts";

export type VizServer = {
	sink: (ev: TraceEvent) => void;
	/** The port the socket actually bound, once it has. `0` asks for an
	 * ephemeral one, and a caller that did needs this to reach it. */
	ready: Promise<number>;
	close: () => void;
};

type Stamped = { seq: number; line: string };

/** What the endpoint remembers about one session a producer reported: enough
 * to close it when the producer goes away, and nothing else. Which sessions
 * are the same conversation is the viewer's question, and it has the wire name
 * and the per-message tags to answer it. */
type Row = {
	/** The scoped session id, the name every forwarded record carries. */
	id: string;
};

/** One connected feed source: the room's own trace, or a publishing peer. */
type Producer = {
	scope: string;
	rows: Map<string, Row>;
	socket: WebSocket | null;
};

/** Records a producer may report before the endpoint stops believing it. A
 * peer holds one session per partner; a thousand is far past any real room and
 * still bounds what one misbehaving publisher can make this process hold. */
const MAX_ROWS_PER_PRODUCER = 1024;

/** The longest string field the endpoint will carry from a producer. Long
 * enough for a designator, a wire name, or a verb; short enough that a
 * producer cannot grow the replay state by sending one enormous label. */
const MAX_FIELD_BYTES = 4096;

/** The longest line a producer may send. A message record carries a base64
 * frame, so this is well above the producer's own payload cap. */
const MAX_LINE_BYTES = 1 << 20;

/** What travels on the feed. A producer's records are protocol observations
 * (`TraceEvent`, the type the bindings emit); the endpoint adds facts about the
 * feed itself, which no producer may send — `KINDS` below is the producer's
 * vocabulary, and this one is deliberately not in it, so a producer cannot
 * announce another's departure. */
type FeedRecord = TraceEvent | {
	v: 1;
	sim_t_ns: number;
	kind: "trace.producer-left";
	scope: string;
};

/** The mark that closes a viewer's replay. Everything before it on a
 * fresh socket is the topology that already exists, and a wire watched
 * from both ends is in there twice — so a viewer that drew each line as
 * it arrived would draw a stand-in for an end whose name is further down
 * the same batch, then take it back. Marking the end lets the viewer
 * treat the batch as one picture and never claim to have learned
 * anything.
 *
 * Endpoint-authored, like `trace.producer-left` and for the same reason:
 * only this side knows where one viewer's replay stops. It is deliberately
 * outside `KINDS`, so `parseRecord` refuses it from a producer — a forged
 * one would make a viewer commit half a snapshot as if it were whole.
 *
 * It carries no `seq`. Sequence numbers are global and drive the viewer's
 * monotone dedup window; this record is sent to one viewer, so it must not
 * advance a window every other viewer shares. That is why it goes straight
 * to the socket instead of through `broadcast`. */
const replayEndLine = (epoch: number, sim_t_ns: number): string =>
	JSON.stringify({ v: 1, sim_t_ns, kind: "trace.replay-end", epoch });

const KINDS = new Set([
	"ocapn.session-opened",
	"ocapn.message-decoded",
	"ocapn.session-closed",
	"ocapn.session-meta",
]);

/** Read one producer line as a timeline record, or null when it is not one.
 * Everything a producer sends is attacker-controlled until this returns: the
 * endpoint accepts only the schema's own shapes, bounded, and drops the rest
 * rather than forwarding it to a viewer. */
export function parseRecord(line: string): TraceEvent | null {
	if (line.length > MAX_LINE_BYTES) return null;
	let raw: unknown;
	try {
		raw = JSON.parse(line);
	} catch {
		return null;
	}
	if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return null;
	const rec = raw as Record<string, unknown>;
	if (rec.v !== 1) return null;
	if (typeof rec.kind !== "string" || !KINDS.has(rec.kind)) return null;
	// `session` is the producer's own handle for the session, which every
	// record carries and the endpoint scopes below. It is NOT the OCapN
	// Session ID: that is `session_id`, which only an open carries, which
	// both ends of one session derive to the same value, and which is
	// therefore the only one that can merge two producers' views.
	if (typeof rec.session !== "string" || rec.session.length === 0) return null;
	if (rec.session.length > MAX_FIELD_BYTES) return null;
	for (
		const field of [
			"a",
			// What a producer says about ITSELF: the name it would like shown,
			// and the implementation it states it runs. Both reach a viewer, so
			// both are bounded here like every other carried string — neither is
			// a way to grow the replay state with one enormous value.
			"a_label",
			"a_profile",
			"b",
			"transport",
			"session_id",
			"provenance",
			"codec",
			"captp_version",
			"op",
			"digest",
		]
	) {
		const value = rec[field];
		if (value === undefined) continue;
		if (typeof value !== "string" || value.length > MAX_FIELD_BYTES) return null;
	}
	// `seq`, `epoch` and `replay` are the endpoint's to assign; a producer that
	// sent its own does not get to keep it.
	delete rec.seq;
	delete rec.epoch;
	delete rec.replay;
	return rec as unknown as TraceEvent;
}

/** The lines a (re)connecting viewer replays: every still-live
 * session's open and, when set, its latest annotation, in seq order,
 * each marked `replay: true` (spliced into the stored JSON — every
 * line is one object, so the prefix splice is sound). The mark lets
 * the viewer treat replay as STATE: the topology and names that
 * exist now, never history. Original stamps are kept, so the
 * viewer's monotone dedup window works unchanged on a reconnect.
 * Exported for tests. */
export function replayLines(
	liveOpens: ReadonlyMap<string, Stamped>,
	liveMetas: ReadonlyMap<string, Stamped>,
): string[] {
	const state = [...liveOpens.values()];
	for (const [sessionId, meta] of liveMetas) {
		if (liveOpens.has(sessionId)) state.push(meta);
	}
	return state
		.sort((a, b) => a.seq - b.seq)
		.map((s) => `{"replay":true,${s.line.slice(1)}`);
}

/** Start the endpoint on `port` (0 takes an ephemeral one) and return the sink
 * to hand to `enableTrace`. The `ROOMS-VIZ-LISTENING` line names the port the
 * socket actually bound, so a viewer — or a harness — reads the URL rather than
 * guessing at one. Sends never block the room server: a socket that cannot
 * accept a frame is dropped (the viewer reconnects and replays). */
export function startViz(port: number): VizServer {
	const liveOpens = new Map<string, Stamped>();
	const liveMetas = new Map<string, Stamped>();
	const clients = new Set<WebSocket>();
	const controller = new AbortController();
	const epoch = Date.now();
	const t0 = performance.now();

	let announceBound: (port: number) => void = () => {};
	const ready = new Promise<number>((resolve) => {
		announceBound = resolve;
	});

	const producers = new Set<Producer>();
	let nextScope = 0;
	const newProducer = (socket: WebSocket | null): Producer => {
		const producer: Producer = { scope: `p${nextScope++}`, rows: new Map(), socket };
		producers.add(producer);
		return producer;
	};

	let seq = 0;
	const broadcast = (ev: FeedRecord): Stamped => {
		seq += 1;
		const line = JSON.stringify({
			...ev,
			sim_t_ns: Math.round((performance.now() - t0) * 1_000_000),
			seq,
			epoch,
		});
		for (const socket of clients) {
			try {
				socket.send(line);
			} catch {
				clients.delete(socket);
			}
		}
		return { seq, line };
	};

	/** Drop a row from the endpoint's state, forwarding a close when the
	 * viewer should see one. `announce` is true only where a producer told
	 * this endpoint the session closed — the one case where the close is
	 * something somebody observed. A row replaced in place, or one going
	 * away because its producer did, is not a close and does not get one. */
	const retire = (producer: Producer, row: Row, announce: boolean): void => {
		producer.rows.delete(row.id);
		if (announce) {
			broadcast({ v: 1, sim_t_ns: 0, kind: "ocapn.session-closed", session: row.id });
		}
		liveOpens.delete(row.id);
		liveMetas.delete(row.id);
	};

	const ingest = (producer: Producer, incoming: TraceEvent): void => {
		const id = `${producer.scope}/${incoming.session}`;
		const ev = { ...incoming, session: id };
		if (ev.kind === "ocapn.session-opened") {
			const existing = producer.rows.get(id);
			if (existing !== undefined) retire(producer, existing, false);
			if (producer.rows.size >= MAX_ROWS_PER_PRODUCER) return;
			producer.rows.set(id, { id });
			liveOpens.set(id, broadcast(ev));
			return;
		}
		const row = producer.rows.get(id);
		if (row === undefined) return;
		if (ev.kind === "ocapn.session-closed") {
			retire(producer, row, true);
			return;
		}
		const stamped = broadcast(ev);
		if (ev.kind === "ocapn.session-meta") liveMetas.set(id, stamped);
	};

	const dropProducer = (producer: Producer): void => {
		if (!producers.delete(producer)) return;
		// A viewer that reloads must not see the ghosts of a peer that left, so
		// this producer's rows leave the replay state. What it does NOT do is
		// announce a close for each of them. A telemetry socket dropping is a
		// fact about this feed; whether the CapTP session behind it is still
		// running is not something the endpoint observed, and `ocapn.` is the
		// vocabulary for what a producer observed. The viewer is told the
		// producer left and works out the consequence for its own picture.
		for (const row of [...producer.rows.values()]) retire(producer, row, false);
		// And the producer's own node goes with it. A consumer keeps a
		// reporting host alive across its sessions closing, because a room
		// server outlives the members that come and go — but that reasoning
		// ends at the producer's own life, and a browser tab that refreshes
		// would otherwise leave a node nothing could ever retire.
		//
		// Only this endpoint knows a producer departed, so only it can say so.
		// `trace.` rather than `ocapn.`: an `ocapn.` record is a protocol fact a
		// producer observed; this is a fact about the trace stream itself. Not
		// `viz.` — that would name one consumer of the stream rather than the
		// stream, and ADR-0104 keeps those apart.
		broadcast({ v: 1, sim_t_ns: 0, kind: "trace.producer-left", scope: producer.scope });
	};

	Deno.serve(
		{
			hostname: "127.0.0.1",
			port,
			signal: controller.signal,
			onListen: ({ port: bound }) => {
				announceBound(bound);
				console.error(`ROOMS-VIZ-LISTENING ws://127.0.0.1:${bound}/`);
			},
		},
		(req) => {
			if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") {
				return new Response(
					"rooms viz: connect a websocket — / to watch, /publish to send\n",
					{ status: 400 },
				);
			}
			const publishing = new URL(req.url).pathname === VIZ_PUBLISH_PATH;
			const { socket, response } = Deno.upgradeWebSocket(req);
			if (publishing) {
				const producer = newProducer(socket);
				socket.onmessage = (msg) => {
					if (typeof msg.data !== "string") return;
					const rec = parseRecord(msg.data);
					if (rec !== null) ingest(producer, rec);
				};
				socket.onclose = () => dropProducer(producer);
				socket.onerror = () => dropProducer(producer);
				return response;
			}
			socket.onopen = () => {
				for (const line of replayLines(liveOpens, liveMetas)) socket.send(line);
				// Sent even when there was nothing to replay: the mark says the
				// batch is complete, and an empty one is complete too. It goes
				// before the socket joins `clients`, so no live record can slip
				// into the middle of a batch a viewer is still holding.
				socket.send(
					replayEndLine(epoch, Math.round((performance.now() - t0) * 1_000_000)),
				);
				clients.add(socket);
			};
			socket.onclose = () => clients.delete(socket);
			socket.onerror = () => clients.delete(socket);
			return response;
		},
	);

	// The room server's own trace is a producer like any other, scoped like any
	// other, so its session ids cannot collide with a peer's.
	const local = newProducer(null);
	return {
		sink: (ev) => ingest(local, ev),
		ready,
		close: () => {
			controller.abort();
			for (const producer of [...producers]) {
				if (producer.socket !== null) {
					try {
						producer.socket.close();
					} catch {
						// already gone
					}
				}
			}
			producers.clear();
			for (const socket of clients) {
				try {
					socket.close();
				} catch {
					// already gone
				}
			}
			clients.clear();
		},
	};
}
