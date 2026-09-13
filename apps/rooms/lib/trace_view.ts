// Reading the live trace, and the line a record makes. This is not a socket
// reader: the WebSocket is only the byte channel, and records
// arrive through an inbox capability after enlivening the sturdyref the server
// announces as `ROOMS-TRACE-LISTENING`. A consumer that watched the socket
// directly would hear nothing, which is why the connect lives here once rather
// than being rediscovered by each consumer.
//
// It moved out of the browser proofs because a second consumer arrived. There
// were already four implementations of this contract across the repository —
// ocapnviz, the proofs, the Rust endpoint, and the Racket producer — and a
// fifth written for a terminal would have been the one that drifted, since
// nothing checks a client the way `checkTraceVocabulary` checks the schema.

import { designatorHostPort, Host, parseSturdyRef, Session, webSocketChannel } from "@glowcap/runtime";
import { traceCapUrl } from "./trace_publish.ts";
import { answerWithin } from "./deadline.ts";

export type TraceRecord = Record<string, unknown>;

/** How long the endpoint has to take a subscription. Generous next to an
 * ordinary room verb: this one replays the whole live topology before it
 * answers, and the reader asking for it has just typed a command rather than
 * being mid-conversation. */
const SUBSCRIBE_MS = 15_000;

/** The endpoint's port, read out of the announcement.
 *
 * A viewer needs two things that are really one fact: the byte channel to open,
 * and the peer to establish a session with. The endpoint states both in the
 * announcement, so a caller holding it needs to be told nothing else — which is
 * what lets a caller that asked for an ephemeral port connect at all. */
export function tracePortOf(sturdyref: string): number {
	return designatorHostPort(parseSturdyRef(sturdyref, "v1_0").locator.designator).port;
}

/** The trace capability inside the announcement: the sturdyref's swissnum is
 * the same swiss the endpoint requires of every socket, so a holder of the
 * announcement needs no second secret. */
export function traceCapOf(sturdyref: string): string {
	return new TextDecoder().decode(parseSturdyRef(sturdyref, "v1_0").swissnum);
}

/** The endpoint address a producer or viewer may use, including the capability
 * every socket must present. Producers replace the path with `/publish` while
 * preserving this query. */
export function traceUrlOf(sturdyref: string): string {
	return traceCapUrl(`ws://127.0.0.1:${tracePortOf(sturdyref)}/`, traceCapOf(sturdyref));
}

/** Connect one viewer and feed every record to `apply`, replay included,
 * exactly as ocapnviz consumes the endpoint. The returned close releases the
 * session and its Host. */
export async function connectTraceViewer(
	sturdyref: string,
	apply: (record: TraceRecord) => void,
): Promise<{ closed: Promise<void>; close(): Promise<void> }> {
	const locator = parseSturdyRef(sturdyref, "v1_0").locator;
	const socket = new WebSocket(traceUrlOf(sturdyref));
	await new Promise<void>((resolve, reject) => {
		socket.onopen = () => resolve();
		socket.onerror = () => reject(new Error("the live timeline endpoint would not accept a viewer"));
	});
	const host = new Host(); // rooms-profile-exempt: a viewer is production ocapnviz's v1.0 peer.
	const session = await Session.establishDialedLocator(
		host,
		locator,
		webSocketChannel(socket),
	);
	const serving = session.serve();
	const raw_log = Deno.env.get("TRACE_VIEWER_LOG");
	const inbox = session.spawn((verb, args) => {
		if (verb !== "record" || args.length !== 1 || typeof args[0] !== "string") {
			throw new Error("the viewer inbox received an invalid record");
		}
		if (raw_log != null) {
			Deno.writeTextFileSync(raw_log, args[0] + "\n", { append: true });
		}
		apply(JSON.parse(args[0]) as TraceRecord);
		return null;
	});
	const trace = await session.enliven(sturdyref);
	// Bounded, because an endpoint that holds the socket open and never answers
	// the subscribe is indistinguishable from one with nothing to report yet,
	// and a consumer waiting on it would sit there looking correct forever.
	await answerWithin(session.send(trace, "subscribe", [inbox]), "the live trace subscription", SUBSCRIBE_MS);
	return {
		// Settles when the session ends, however it ends. A consumer that keeps
		// running past its feed reports a quiet peer where what actually
		// happened is that nobody is talking to it any more, and those look
		// identical from the outside.
		closed: serving,
		async close() {
			await session.close();
			await serving;
			await host.close();
		},
	};
}

/** One record as one line.
 *
 * Keyed on `kind`, and an unrecognised kind prints rather than being dropped:
 * a trace consumer that silently swallows a record it cannot read is lying
 * about the run, and the reader has no way to tell that from a quiet peer.
 *
 * The session column is the producer-scoped id the endpoint stamps (`p0/s1`),
 * and that scope is what tells two producers' identical ids apart, so it is shown as
 * the endpoint gives it rather than shortened to something ambiguous. */
export function traceLine(record: TraceRecord): string {
	const at = stamp(record.sim_t_ns);
	const session = typeof record.session === "string" ? record.session : "-";
	const kind = typeof record.kind === "string" ? record.kind : "?";
	switch (kind) {
		case "ocapn.session-opened": {
			const who = `${str(record.a_label) ?? str(record.a) ?? "?"} -> ${str(record.b) ?? "?"}`;
			const how = [str(record.transport), str(record.captp_version), str(record.codec)]
				.filter((part) => part !== null).join("/");
			const proof = record.provenance === "authenticated-transport" ? "authenticated" : "unauthenticated";
			return `${at}  open   ${session}  ${who}  ${how}  ${proof}`;
		}
		case "ocapn.message-decoded": {
			const way = record.outbound === true ? "->" : "<-";
			// `len` is the frame's true byte length even when the record
			// carried only a head, so it is the honest number in both cases.
			const len = typeof record.len === "number" ? `${record.len}B` : "";
			return `${at}  msg    ${session}  ${way} ${str(record.op) ?? "?"}  ${len}`.trimEnd();
		}
		case "ocapn.session-closed":
			return `${at}  close  ${session}  ${str(record.reason) ?? "closed"}`;
		case "ocapn.session-meta": {
			// A claim by the producing application, never protocol identity, so
			// it is shown as one. A null label is the application withdrawing
			// the name rather than saying nothing, and reads differently.
			const meta = record.meta as { label?: string | null } | undefined;
			const label = meta === undefined || meta.label === undefined
				? ""
				: meta.label === null
				? "(name withdrawn)"
				: `calls it ${meta.label}`;
			return `${at}  meta   ${session}  ${label}`.trimEnd();
		}
		case "trace.replay-end":
			return `${at}  ----   replay complete, live from here`;
		default:
			return `${at}  ${kind}  ${JSON.stringify(record)}`;
	}
}

function str(value: unknown): string | null {
	return typeof value === "string" && value !== "" ? value : null;
}

/** Simulated nanoseconds as a clock-shaped stamp. The endpoint's times are its
 * own monotonic count rather than wall time, so this reads as elapsed rather
 * than pretending to be an hour of the day. */
function stamp(value: unknown): string {
	if (typeof value !== "number" || !Number.isFinite(value)) return "        -   ";
	const ms = value / 1_000_000;
	const s = Math.floor(ms / 1000);
	return `${String(Math.floor(s / 60)).padStart(3, " ")}:${String(s % 60).padStart(2, "0")}.${
		String(Math.floor(ms % 1000)).padStart(3, "0")
	}`;
}
