// A trace viewer receives records through an inbox capability. The WebSocket
// carries CapTP bytes. The advertised route alone grants no trace access.

import {
	type Channel,
	designatorHostPort,
	Host,
	openWebSocketChannel,
	parseSturdyRef,
	Session,
} from "@glowcap/runtime";
import { traceCapUrl } from "./trace_publish.ts";
import { answerWithin } from "./deadline.ts";

export type TraceRecord = Record<string, unknown>;

/** Whether a parsed wire value is a trace record: a plain JSON object. */
function isTraceRecord(raw: unknown): raw is TraceRecord {
	return raw != null && typeof raw === "object" && !Array.isArray(raw);
}

/** How long the endpoint has to take a subscription. Generous next to an
 * ordinary room verb, because this one replays the whole live topology before
 * it answers, and the reader asking for it has just typed a command and is not
 * mid-conversation. */
const SUBSCRIBE_MS = 15_000;

/** The endpoint's port, read out of the announcement.
 *
 * A viewer needs two things that are one fact: the byte channel to open, and
 * the peer to establish a session with. The endpoint states both in the
 * announcement, so a caller holding it needs nothing else. That is what lets a
 * caller that asked for an ephemeral port connect at all. */
export function tracePortOf(sturdyref: string): number {
	return designatorHostPort(parseSturdyRef(sturdyref, "v1_0").locator.designator).port;
}

/** The trace capability inside the announcement. The sturdyref's swissnum is
 * the same swiss the endpoint requires of every socket, so a holder of the
 * announcement needs no second secret. */
export function traceCapOf(sturdyref: string): string {
	return new TextDecoder().decode(parseSturdyRef(sturdyref, "v1_0").swissnum);
}

/** The advertised viewer channel, proxy prefix included. The endpoint always
 * advertises it, so a link without it is refused rather than guessed. */
export function traceUrlOf(sturdyref: string): string {
	const endpoint = parseSturdyRef(sturdyref, "v1_0").locator.hints.get("captp-websocket");
	if (typeof endpoint !== "string") throw new Error("the trace link must advertise its captp-websocket channel");
	const url = new URL(endpoint);
	if (!["ws:", "wss:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
		throw new Error("trace channel must be a WebSocket URL without credentials, query or fragment");
	}
	return endpoint;
}

/** Producers use their independently advertised route and HTTP capability.
 * The endpoint always advertises the route, as the server's own reader
 * requires, so a link without it is refused. */
export function tracePublishUrlOf(sturdyref: string): string {
	const endpoint = parseSturdyRef(sturdyref, "v1_0").locator.hints.get("trace-publish");
	if (typeof endpoint !== "string") throw new Error("the trace link must advertise its trace-publish endpoint");
	return traceCapUrl(endpoint, traceCapOf(sturdyref));
}

/** Connect one viewer and feed every record to `apply`, replay included, as
 * ocapnviz consumes the endpoint. The returned close releases the session and
 * its Host. */
export async function connectTraceViewer(
	sturdyref: string,
	apply: (record: TraceRecord) => void,
): Promise<{ closed: Promise<void>; close(): Promise<void> }> {
	const locator = parseSturdyRef(sturdyref, "v1_0").locator;
	const host = new Host(); // rooms-profile-exempt: a viewer is production ocapnviz's v1.0 peer.
	let channel: Channel | undefined;
	let session: Session | undefined;
	let serving: Promise<void> | undefined;
	const close = async () => {
		const failures: unknown[] = [];
		try {
			if (session) await session.close();
			else await channel?.close();
		} catch (error) {
			failures.push(error);
		}
		try {
			await serving;
		} catch (error) {
			failures.push(error);
		}
		try {
			await host.close();
		} catch (error) {
			failures.push(error);
		}
		if (failures.length !== 0) throw new AggregateError(failures, "closing the trace viewer failed");
	};
	try {
		// Adopt the byte channel inside onopen, before an immediate greeting
		// can arrive. The shared opener also owns failed or cancelled opens.
		channel = await openWebSocketChannel(traceUrlOf(sturdyref), undefined, AbortSignal.timeout(SUBSCRIBE_MS));
		session = await answerWithin(
			Session.establishDialedLocator(
				host,
				locator,
				channel,
			),
			"the live trace handshake",
			SUBSCRIBE_MS,
		);
		serving = session.serve();
		// Startup can fail before the caller owns `closed`. Keep its rejection
		// observed while cleanup retains the same result for that caller.
		void serving.catch(() => {}); // tolerant: observes rejection until cleanup or the caller awaits the same result.
		const inbox = session.spawn((verb, args) => {
			if (verb !== "record" || args.length !== 1 || typeof args[0] !== "string") {
				throw new Error("the viewer inbox received an invalid record");
			}
			const record: unknown = JSON.parse(args[0]);
			if (!isTraceRecord(record)) {
				throw new Error("the live trace sent a record that is not an object");
			}
			apply(record);
			return null;
		});
		const trace = await answerWithin(session.enliven(sturdyref), "the live trace capability", SUBSCRIBE_MS);
		// Bounded, because an endpoint that holds the socket open and never answers
		// the subscribe looks the same as one with nothing to report yet, and a status-allow: pending state or quoted runtime label
		// consumer waiting on it would sit there looking correct forever.
		await answerWithin(session.send(trace, "subscribe", [inbox]), "the live trace subscription", SUBSCRIBE_MS);
		return {
			// Settles when the session ends, however it ends. A consumer that keeps
			// running past its feed reports a quiet peer when nobody is talking to
			// it any more, and those look identical from the outside.
			closed: serving,
			close,
		};
	} catch (error) {
		try {
			await close();
		} catch (cleanup) {
			throw new AggregateError([error, cleanup], "opening the trace viewer failed and cleanup also failed");
		}
		throw error;
	}
}

/** One record as one line.
 *
 * Keyed on `kind`. An unrecognized kind prints and is not dropped, because a
 * trace consumer that silently swallows a record it cannot read misreports the
 * run, and the reader cannot tell that from a quiet peer.
 *
 * The session column is the producer-scoped id the endpoint stamps (`p0/s1`).
 * That scope tells two producers' identical ids apart, so it is shown as the
 * endpoint gives it and not shortened to something ambiguous. */
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
			// carried only a head, so it is the accurate number in both cases.
			const len = typeof record.len === "number" ? `${record.len}B` : "";
			return `${at}  msg    ${session}  ${way} ${str(record.op) ?? "?"}  ${len}`.trimEnd();
		}
		case "ocapn.session-closed":
			return `${at}  close  ${session}  ${str(record.reason) ?? "closed"}`;
		case "ocapn.session-meta": {
			// A claim by the producing application, never protocol identity, so
			// it is shown as one. A null label is the application withdrawing
			// the name, and it reads differently from saying nothing.
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
 * monotonic count and not wall time, so this reads as elapsed time and does
 * not pretend to be an hour of the day. */
function stamp(value: unknown): string {
	if (typeof value !== "number" || !Number.isFinite(value)) return "        -   ";
	const ms = value / 1_000_000;
	const s = Math.floor(ms / 1000);
	return `${String(Math.floor(s / 60)).padStart(3, " ")}:${String(s % 60).padStart(2, "0")}.${
		String(Math.floor(ms % 1000)).padStart(3, "0")
	}`;
}
