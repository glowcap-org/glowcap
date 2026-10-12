/**
 * Convert a `glowcap griddle run` timeline (NDJSON on stdin) into an ocapnviz
 * TimelineDocument (JSON on stdout), so a simulated conversation opens in the
 * viewer's Play mode:
 *
 *   glowcap griddle run --scenario crossed-fetch --seed 7 \
 *     | deno run scripts/griddle-import.ts > /tmp/crossed-fetch.json
 *
 * The mapping is layer-for-layer. griddle's base kinds carry network facts
 * and no protocol, which is exactly the viewer's document vocabulary:
 *
 *   host_joined            -> peer-joined
 *   message_in_flight      -> message-sent (arrivalT from arrive_ns)
 *   message_delivered      -> message-delivered
 *
 * The viewer draws messages inside sessions, which griddle's network layer
 * does not name, so the first frame between a pair of hosts synthesizes one
 * session-opened for that pair. griddle's delivered events carry no message
 * id. They correlate FIFO per directed link, which is sound because the
 * simulator's links are FIFOs by construction (reordering one would model a
 * broken transport, and it refuses to).
 *
 * Dropped, until the viewer grows a vocabulary for them:
 * link_up/link_down (the viewer has no link entity), message_lost (a cut
 * link's loss shows as a message that never arrives), and the captp_* kinds
 * (the viewer's protocol annotations are richer than a kind string, mapping
 * them flat would mislead). Times convert from simulated nanoseconds to the
 * document's milliseconds.
 */

const NS_PER_MS = 1_000_000;

type DocEvent = Record<string, unknown>;

const decoder = new TextDecoder();
let input = "";
for await (const chunk of Deno.stdin.readable) {
	input += decoder.decode(chunk, { stream: true });
}

const events: DocEvent[] = [];
const peers: string[] = [];
const sessions: string[] = [];
const sessionOf = new Map<string, string>(); // unordered pair key -> sessionId
// FIFO of in-flight message ids per directed link, matching the simulator's
// own per-link ordering guarantee.
const inFlight = new Map<string, string[]>();
let eventSeq = 0;
let messageSeq = 0;
let lastT = 0;
let scenario = "griddle";

const peerId = (id: number) => `host-${id}`;
const pairKey = (a: number, b: number) => (a < b ? `${a}-${b}` : `${b}-${a}`);
const nextId = () => `e${++eventSeq}`;
const toMs = (ns: number) => Math.round(ns / NS_PER_MS);

function sessionFor(t: number, src: number, dst: number): string {
	const key = pairKey(src, dst);
	const existing = sessionOf.get(key);
	if (existing !== undefined) return existing;
	const sessionId = `s-${key}`;
	sessionOf.set(key, sessionId);
	sessions.push(sessionId);
	events.push({
		id: nextId(),
		t,
		kind: "session-opened",
		sessionId,
		a: peerId(src),
		b: peerId(dst),
		codec: "syrup",
		captpVersion: "next",
	});
	return sessionId;
}

for (const line of input.split("\n")) {
	if (line.length === 0) continue;
	const ev = JSON.parse(line);
	const t = toMs(ev.sim_t_ns ?? 0);
	lastT = Math.max(lastT, t);
	switch (ev.kind) {
		case "sim_started":
			scenario = ev.scenario ?? scenario;
			break;
		case "host_joined": {
			peers.push(peerId(ev.id));
			events.push({
				id: nextId(),
				t,
				kind: "peer-joined",
				peerId: peerId(ev.id),
				profile: "glowcap",
			});
			break;
		}
		case "message_in_flight": {
			const sessionId = sessionFor(t, ev.src, ev.dst);
			const messageId = `m${++messageSeq}`;
			const link = `${ev.src}->${ev.dst}`;
			const queue = inFlight.get(link) ?? [];
			queue.push(messageId);
			inFlight.set(link, queue);
			const arrivalT = toMs(ev.arrive_ns ?? ev.sim_t_ns ?? 0);
			lastT = Math.max(lastT, arrivalT);
			events.push({
				id: nextId(),
				t,
				kind: "message-sent",
				messageId,
				sessionId,
				from: peerId(ev.src),
				to: peerId(ev.dst),
				arrivalT,
			});
			break;
		}
		case "message_delivered": {
			const link = `${ev.src}->${ev.dst}`;
			const messageId = inFlight.get(link)?.shift();
			if (messageId === undefined) break; // a delivery with no send is a producer bug; drop rather than invent
			events.push({ id: nextId(), t, kind: "message-delivered", messageId });
			break;
		}
		default:
			break; // link_up/link_down/message_lost/captp_*, see the module note
	}
}

const doc = {
	id: `griddle-${scenario}`,
	duration: lastT + 100,
	events,
	rowOrder: { peers, sessions },
};

console.log(JSON.stringify(doc, null, "\t"));
