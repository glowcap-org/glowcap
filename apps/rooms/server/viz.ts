// The live timeline endpoint: one WebSocket that carries the room's own
// sessions AND every other peer's, in the versioned timeline schema ocapnviz's
// Live mode consumes. Give the viewer the `ROOMS-VIZ-LISTENING` sturdyref and
// the topology draws as it happens.
//
// No socket is admitted on reachability alone. The endpoint is minted with
// one capability swiss, and every connect — viewer and producer alike —
// presents it as the `cap` query parameter or is closed with a typed refusal
// (`VIZ_REFUSED_CLOSE_CODE`). The same swiss is the durable trace
// publication's name, so the announced sturdyref is the whole viewing grant:
// its swissnum admits the socket and enlivens the trace object. Writing into
// the timeline is the same swiss presented on `/publish`; before this,
// reaching the port was the authority to write, which is the ambient door
// this closes.
//
// Two kinds of socket connect here. An OCapN VIEWER connects to `/` and
// receives through a durable trace capability; a PRODUCER connects to
// `/publish` and sends, one JSON record per line, and hears back only the
// endpoint's own `trace.publish-ready` admission mark. That
// split is what lets a direct message appear at all: a
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

import * as tcp from "@glowcap/tcp";
import { currentSession, Host, Ref, Session, TRANSPORT_TCP, webSocketChannel } from "@glowcap/runtime";
import type { TraceEvent } from "@glowcap/runtime";
import { DESIGNATOR_SCHEME_ADDRESS } from "@glowcap/abi";
import { throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";
import { VIZ_CAP_PARAM, VIZ_PUBLISH_PATH, VIZ_REFUSED_CLOSE_CODE } from "../lib/viz_publish.ts";
import { observeCloseFailure, observeSettledFailures, releaseRefusedCapability } from "./viz/lifecycle.ts";
import {
	MAX_LINE_BYTES,
	MAX_REMOTE_PRODUCERS,
	MAX_ROWS_PER_PRODUCER,
	MAX_SUBSCRIBER_QUEUE,
	MAX_SUBSCRIBER_QUEUE_BYTES,
	MAX_SUBSCRIBERS,
	ProducerBudget,
} from "./viz/policy.ts";
import { parseRecord, utf8Bytes } from "./viz/records.ts";
import { formatRoomsSturdyref } from "../lib/locator.ts";

export { parseRecord } from "./viz/records.ts";

export type VizServer = {
	sink: (ev: TraceEvent) => void;
	/** The port the socket actually bound, once it has. `0` asks for an
	 * ephemeral one, and a caller that did needs this to reach it. */
	ready: Promise<number>;
	/** The durable trace capability announced by the endpoint. */
	sturdyref: Promise<string>;
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

type TraceSubscriber = {
	session: Session;
	inbox: Ref;
	queue: Array<{ line: string; bytes: number }>;
	queuedBytes: number;
	draining: boolean;
	active: boolean;
};

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

/** The reason a refused socket carries in its close frame. */
export const VIZ_REFUSED_REASON = "rooms viz: this endpoint requires its capability";

/** Whether two secrets are the same string, compared without an early exit,
 * so a probe cannot walk the swiss one character at a time by timing the
 * refusal. `charCodeAt` past either end is `NaN`, which `| 0` folds to zero,
 * so a length mismatch still walks the longer string and lands in the
 * accumulated difference. */
export function constantTimeEquals(a: string, b: string): boolean {
	const length = Math.max(a.length, b.length);
	let diff = a.length ^ b.length;
	for (let i = 0; i < length; i += 1) {
		diff |= (a.charCodeAt(i) | 0) ^ (b.charCodeAt(i) | 0);
	}
	return diff === 0;
}

/** The endpoint-authored mark an admitted producer hears, and the only thing
 * it will ever hear: a positive admission signal, so taking the capability in
 * a client is a deterministic round trip rather than a grace timer. Outside
 * `KINDS` like the other endpoint-authored records, so `parseRecord` refuses
 * a forged one, and without `seq` for `replayEndLine`'s reason: it goes to
 * one socket and must not advance the shared dedup window. */
const publishReadyLine = (epoch: number, sim_t_ns: number): string =>
	JSON.stringify({ v: 1, sim_t_ns, kind: "trace.publish-ready", epoch });

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

/** Start the endpoint on `port` (0 takes an ephemeral one), guarded by
 * `swiss` — the viz capability every socket must present — and return the
 * sink to hand to `enableTrace`. The trace object is published under that
 * same swiss, so the `ROOMS-VIZ-LISTENING` sturdyref carries the whole
 * grant: the port the socket actually bound, the peer to establish with,
 * and the swissnum that both admits the socket and enlivens the trace.
 * Sends never block the room server: a socket that cannot accept a frame
 * is dropped (the viewer reconnects and replays). */
export function startViz(
	port: number,
	swiss: string,
	onTrouble: (source: string, error: unknown) => void,
): VizServer {
	const traceHost = new Host(); // rooms-profile-exempt: generic v1.0 observer, not a Rooms peer.
	const traceDesignator = traceHost.designator();
	traceHost.publishGiftable(swiss, (verb, args) => {
		const session = currentSession();
		if (session == null) throw new Error("trace.subscribe requires a session");
		if (verb !== "subscribe" || args.length !== 1 || !(args[0] instanceof Ref)) {
			throwAfterReleasingCapabilities(
				session,
				args,
				new Error("trace.subscribe expects one inbox capability"),
			);
		}
		addSubscriber(session, args[0]);
		return null;
	});
	const liveOpens = new Map<string, Stamped>();
	const liveMetas = new Map<string, Stamped>();
	const subscribers = new Set<TraceSubscriber>();
	const subscriberBySession = new Map<Session, TraceSubscriber>();
	const acceptedSessions = new Set<Session>();
	const viewerSockets = new Set<WebSocket>();
	const viewerTasks = new Set<Promise<void>>();
	const controller = new AbortController();
	const epoch = Date.now();
	const t0 = performance.now();
	let boundPort = port;
	let closing = false;

	let announceBound: (port: number) => void = () => {};
	const ready = new Promise<number>((resolve) => {
		announceBound = resolve;
	});
	let announceSturdyref: (sturdyref: string) => void = () => {};
	const sturdyref = new Promise<string>((resolve) => {
		announceSturdyref = resolve;
	});

	const producers = new Set<Producer>();
	const producerBudget = new ProducerBudget();
	let nextScope = 0;
	const newProducer = (socket: WebSocket | null): Producer | null => {
		if (socket !== null && !producerBudget.admitRemote()) return null;
		const producer: Producer = { scope: `p${nextScope++}`, rows: new Map(), socket };
		producers.add(producer);
		return producer;
	};

	let seq = 0;
	const broadcast = (ev: FeedRecord): Stamped | null => {
		seq += 1;
		const line = JSON.stringify({
			...ev,
			sim_t_ns: Math.round((performance.now() - t0) * 1_000_000),
			seq,
			epoch,
		});
		const bytes = utf8Bytes(line);
		if (bytes > MAX_LINE_BYTES) return null;
		for (const subscriber of subscribers) enqueue(subscriber, line, bytes);
		return { seq, line };
	};

	function removeSubscriber(subscriber: TraceSubscriber, closeSession = false): void {
		if (!subscriber.active) return;
		subscriber.active = false;
		subscriber.queue.length = 0;
		subscriber.queuedBytes = 0;
		subscribers.delete(subscriber);
		if (subscriberBySession.get(subscriber.session) === subscriber) {
			subscriberBySession.delete(subscriber.session);
		}
		if (closeSession) {
			observeCloseFailure(
				() => subscriber.session.close(),
				(error) => onTrouble("a viz subscriber would not retire", error),
			);
		} else {
			try {
				subscriber.session.release(subscriber.inbox);
			} catch (error) {
				onTrouble("a viz subscriber capability release failed", error);
			}
		}
	}

	async function drain(subscriber: TraceSubscriber): Promise<void> {
		if (subscriber.draining) return;
		subscriber.draining = true;
		try {
			while (subscriber.active && subscriber.queue.length > 0) {
				const record = subscriber.queue.shift()!;
				subscriber.queuedBytes -= record.bytes;
				await subscriber.session.tell(subscriber.inbox, "record", [record.line]);
			}
		} catch {
			removeSubscriber(subscriber, true);
		} finally {
			subscriber.draining = false;
		}
	}

	function enqueue(subscriber: TraceSubscriber, line: string, bytes?: number): void {
		if (!subscriber.active) return;
		const size = bytes ?? utf8Bytes(line);
		if (
			size > MAX_LINE_BYTES ||
			subscriber.queue.length >= MAX_SUBSCRIBER_QUEUE ||
			subscriber.queuedBytes + size > MAX_SUBSCRIBER_QUEUE_BYTES
		) {
			removeSubscriber(subscriber, true);
			return;
		}
		subscriber.queue.push({ line, bytes: size });
		subscriber.queuedBytes += size;
		void drain(subscriber);
	}

	function addSubscriber(session: Session, inbox: Ref): void {
		const prior = subscriberBySession.get(session);
		if (prior !== undefined) removeSubscriber(prior);
		if (subscribers.size >= MAX_SUBSCRIBERS) {
			releaseRefusedCapability(
				session,
				inbox,
				(error) => onTrouble("a refused viz subscriber capability release failed", error),
			);
			throw new Error("trace subscriber limit reached");
		}
		const subscriber: TraceSubscriber = {
			session,
			inbox,
			queue: [],
			queuedBytes: 0,
			draining: false,
			active: true,
		};
		subscribers.add(subscriber);
		subscriberBySession.set(session, subscriber);
		for (const line of replayLines(liveOpens, liveMetas)) enqueue(subscriber, line);
		enqueue(
			subscriber,
			replayEndLine(epoch, Math.round((performance.now() - t0) * 1_000_000)),
		);
	}

	/** Drop a row from the endpoint's state, forwarding a close when the
	 * viewer should see one. `announce` is true only where a producer told
	 * this endpoint the session closed — the one case where the close is
	 * something somebody observed. A row replaced in place, or one going
	 * away because its producer did, is not a close and does not get one. */
	const retire = (producer: Producer, row: Row, announce: boolean): void => {
		if (!producer.rows.delete(row.id)) return;
		producerBudget.retireRow();
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
			if (producer.rows.size >= MAX_ROWS_PER_PRODUCER || !producerBudget.retainRow()) return;
			producer.rows.set(id, { id });
			const stamped = broadcast(ev);
			if (stamped !== null) liveOpens.set(id, stamped);
			return;
		}
		const row = producer.rows.get(id);
		if (row === undefined) return;
		if (ev.kind === "ocapn.session-closed") {
			retire(producer, row, true);
			return;
		}
		const stamped = broadcast(ev);
		if (ev.kind === "ocapn.session-meta" && stamped !== null) liveMetas.set(id, stamped);
	};

	const dropProducer = (producer: Producer): void => {
		if (!producers.delete(producer)) return;
		if (producer.socket !== null) producerBudget.retireRemote();
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
				boundPort = bound;
				announceBound(bound);
				const locator = tcp.locator("127.0.0.1", bound);
				const ref = formatRoomsSturdyref(locator, swiss);
				announceSturdyref(ref);
				console.error(`ROOMS-VIZ-LISTENING ${ref}`);
			},
		},
		(req) => {
			if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") {
				return new Response(
					"rooms viz: connect an OCapN websocket at / or publish telemetry at /publish, " +
						`presenting the viz capability as ?${VIZ_CAP_PARAM}=<swiss>\n`,
					{ status: 400 },
				);
			}
			const url = new URL(req.url);
			const publishing = url.pathname === VIZ_PUBLISH_PATH;
			const { socket, response } = Deno.upgradeWebSocket(req);
			// Admission first, before either role exists. A socket that does not
			// present the capability is never a producer and never a viewer: no
			// handler is installed, so nothing it sends is parsed, ingested, or
			// forwarded. The refusal happens after the upgrade so the closing
			// handshake can carry a reason a WebSocket client is able to read;
			// a plain 403 would reach it only as an anonymous handshake failure.
			if (!constantTimeEquals(url.searchParams.get(VIZ_CAP_PARAM) ?? "", swiss)) {
				socket.onopen = () => socket.close(VIZ_REFUSED_CLOSE_CODE, VIZ_REFUSED_REASON);
				return response;
			}
			if (publishing) {
				const producer = newProducer(socket);
				if (producer === null) {
					socket.onopen = () =>
						socket.close(
							1013,
							`rooms viz: producer limit ${MAX_REMOTE_PRODUCERS} reached`,
						);
					return response;
				}
				socket.onopen = () => {
					// The admission mark: the one thing a producer ever hears.
					try {
						socket.send(publishReadyLine(epoch, Math.round((performance.now() - t0) * 1_000_000)));
					} catch {
						// A socket that died mid-open reports through onclose.
					}
				};
				socket.onmessage = (msg) => {
					if (typeof msg.data !== "string") return;
					const rec = parseRecord(msg.data);
					if (rec !== null) ingest(producer, rec);
				};
				socket.onclose = () => dropProducer(producer);
				socket.onerror = () => dropProducer(producer);
				return response;
			}
			viewerSockets.add(socket);
			// Taken out again by the task that opening starts. A socket that never
			// opens starts no task and would sit in this set for the life of the
			// process; a listener rather than `onclose`, because the session takes the
			// socket's own handlers when it establishes.
			socket.addEventListener("close", () => viewerSockets.delete(socket));
			socket.onopen = () => {
				const task = (async () => {
					let session: Session | null = null;
					try {
						session = await Session.establishAccepted(traceHost, {
							transport: TRANSPORT_TCP,
							designatorScheme: DESIGNATOR_SCHEME_ADDRESS,
							serverDesignator: tcp.addressDesignator("127.0.0.1", boundPort),
							channel: webSocketChannel(socket),
							localAddress: tcp.addressDesignator("127.0.0.1", boundPort),
						});
						acceptedSessions.add(session);
						await session.serve().catch((error) => {
							onTrouble("a viz viewer session failed", error);
						});
					} catch (error) {
						onTrouble("a viz viewer setup failed", error);
						try {
							socket.close();
						} catch (closeError) {
							onTrouble("a viz viewer socket would not close", closeError);
						}
					} finally {
						viewerSockets.delete(socket);
						if (session !== null) {
							const subscriber = subscriberBySession.get(session);
							if (subscriber !== undefined) removeSubscriber(subscriber);
							acceptedSessions.delete(session);
						}
					}
				})();
				viewerTasks.add(task);
				void task.finally(() => viewerTasks.delete(task)).catch((error) => {
					console.error("[rooms] viz viewer lifecycle failed:", error);
				});
			};
			return response;
		},
	);

	// The room server's own trace is a producer like any other, scoped like any
	// other, so its session ids cannot collide with a peer's.
	const local = newProducer(null)!;
	const ignoredTraceSessions = new Set<string>();
	return {
		sink: (ev) => {
			// The trace endpoint is itself a Host. Its browser observer session is
			// implementation machinery, not room activity, and must not become a
			// row in the trace it is delivering. The open identifies the session;
			// subsequent messages and close carry only that session handle.
			if (ev.kind === "ocapn.session-opened" && ev.a === traceDesignator) {
				ignoredTraceSessions.add(ev.session);
				return;
			}
			if (ignoredTraceSessions.has(ev.session)) {
				if (ev.kind === "ocapn.session-closed") ignoredTraceSessions.delete(ev.session);
				return;
			}
			ingest(local, ev);
		},
		ready,
		sturdyref,
		close: () => {
			if (closing) return;
			closing = true;
			controller.abort();
			for (const producer of [...producers]) {
				producer.rows.clear();
				if (producer.socket !== null) {
					try {
						producer.socket.close();
					} catch (error) {
						console.error("[rooms] viz producer socket close failed:", error);
					}
				}
			}
			producers.clear();
			producerBudget.clear();
			liveOpens.clear();
			liveMetas.clear();
			ignoredTraceSessions.clear();
			for (const subscriber of subscribers) removeSubscriber(subscriber);
			for (const socket of viewerSockets) {
				try {
					socket.close();
				} catch (error) {
					console.error("[rooms] viz viewer socket close failed:", error);
				}
			}
			viewerSockets.clear();
			const sessions = [...acceptedSessions];
			acceptedSessions.clear();
			// This embedding's close lever cannot await. Keep the shared Host alive
			// until every accepted session has stopped using it.
			const shutdownOperations = [
				...sessions.map((session, index) => ({
					operation: `accepted viewer session ${index + 1} close`,
					promise: Promise.resolve().then(() => session.close()),
				})),
				...[...viewerTasks].map((promise, index) => ({
					operation: `viewer task ${index + 1}`,
					promise,
				})),
			];
			void observeSettledFailures(
				shutdownOperations,
				(operation, error) => console.error(`[rooms] viz ${operation} failed:`, error),
			).then(() => traceHost.close()).catch((error) => {
				console.error("[rooms] viz trace host shutdown failed:", error);
			});
		},
	};
}
