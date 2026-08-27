// The publishing half of the live timeline feed: a peer sends its own trace to
// the shared endpoint, so the sessions it holds appear beside everyone else's.
//
// This is what makes a direct message visible. A DM is a session between two
// members, formed by three-party introduction and held on the members' own
// hosts; the room server never carries a byte of it and must not start. What
// converges is telemetry, on a socket that goes only one way — a producer
// sends records and hears nothing back but the endpoint's own admission mark,
// so nothing here is a channel between peers and nothing here can carry
// application traffic.
//
// The socket is not open to whoever can reach it: the endpoint mints one
// capability swiss when it is enabled, and a producer presents it on the
// connect URL (`VIZ_CAP_PARAM`) or is closed with a typed refusal. Holding
// the swiss is the authority to write into the timeline.
//
// The endpoint scopes a producer's session ids by the CONNECTION they arrived
// on, which is what keeps two producers' identical ids apart. A reconnect is
// therefore a new scope, and the sessions this peer still holds have to be
// announced again under it. So this half keeps the same state the endpoint
// keeps for a reconnecting viewer — the live opens and their latest
// annotations, and nothing else — and sends it as the first thing on every
// connection. History is not resent: a record about a session that has since
// closed would draw topology that no longer exists.
//
// Telemetry never gets to slow the application down. Records that arrive while
// the socket is still connecting wait in a bounded buffer and the oldest are
// dropped past its ceiling (safe, because the live state above is resent in
// full anyway); a send that throws is swallowed; a socket that dies is retried
// with backoff.

import type { TraceEvent } from "@pancake/runtime";
import * as z from "zod/mini";
import { nonnegativeSafeInteger } from "./schema.ts";

const PublishReadySchema = z.strictObject({
	v: z.literal(1),
	sim_t_ns: nonnegativeSafeInteger,
	kind: z.literal("trace.publish-ready"),
	epoch: nonnegativeSafeInteger,
});

/** The endpoint path a producer connects to. Viewers use `/`; this is the
 * other half of that split, named once so the endpoint and its producers
 * cannot drift apart. */
export const VIZ_PUBLISH_PATH = "/publish";

/** The query parameter a connecting socket presents the endpoint's capability
 * in — producers and viewers alike. Reachability alone reads and writes
 * nothing: the endpoint refuses a socket that does not present its swiss.
 * (ocapnviz presents the same parameter from the sturdyref it already holds;
 * its viewer names the parameter itself because it shares no module with this
 * app.) */
export const VIZ_CAP_PARAM = "cap";

/** The close code a refused socket receives, with the reason in the close
 * frame, so a WebSocket client can read why it was turned away. In the
 * application range because the WebSocket protocol reserves the low codes. */
export const VIZ_REFUSED_CLOSE_CODE = 4403;

/** The page-origin timeline socket. Browser pages reach the supervised
 * endpoint through their own origin, so HTTPS selects WSS and no internal
 * endpoint port enters browser state. */
export function originVizUrl(location: { protocol: string; host: string }): string {
	return `${location.protocol === "https:" ? "wss://" : "ws://"}${location.host}/viz`;
}

/** Why a durable visualizer override cannot be used, or null for blank and a
 * complete WebSocket URL. Validation never rewrites the operator's value. */
export function vizOverrideRefusal(value: string): string | null {
	if (value === "") return null;
	if (value !== value.trim()) return "The visualizer endpoint cannot begin or end with whitespace.";
	let parsed: URL;
	try {
		parsed = new URL(value);
	} catch {
		return "The visualizer endpoint must be a complete WebSocket URL.";
	}
	if (parsed.protocol !== "ws:" && parsed.protocol !== "wss:") {
		return "The visualizer endpoint must use ws:// or wss://.";
	}
	if (parsed.hash !== "") return "The visualizer endpoint cannot include a fragment.";
	return null;
}

/** Put the capability on an endpoint URL, viewer or producer alike. */
export function vizCapUrl(url: string, swiss: string): string {
	const parsed = new URL(url);
	parsed.searchParams.set(VIZ_CAP_PARAM, swiss);
	return parsed.toString();
}

/** Records held while the socket is connecting. One session's opening burst is
 * a handful; this is far above that and still a fixed ceiling. */
const MAX_PENDING = 4096;

/** Backoff before redialing an endpoint that is down, so a missing endpoint is
 * polled rather than hot-looped. */
const RETRY_MS = 1_000;

export type VizPublisher = {
	/** Hand this to `enableTrace`. */
	sink: (ev: TraceEvent) => void;
	/** Stop publishing and close the socket. */
	stop: () => void;
};

/** Turn a viewer URL into the producer URL for the same endpoint. Accepts
 * either spelling, so a caller can pass whatever URL it was configured with. */
export function publishUrl(url: string): string {
	const parsed = new URL(url);
	if (!parsed.pathname.endsWith(VIZ_PUBLISH_PATH)) parsed.pathname = VIZ_PUBLISH_PATH;
	return parsed.toString();
}

/** The records that re-announce this peer's live topology on a fresh
 * connection: every still-open session, then the latest annotation of each,
 * in that order so an annotation never arrives before the session it names.
 * Exported for tests. */
export function announceLines(
	opens: ReadonlyMap<string, TraceEvent>,
	metas: ReadonlyMap<string, TraceEvent>,
): string[] {
	const lines = [...opens.values()].map((ev) => JSON.stringify(ev));
	for (const [id, meta] of metas) {
		if (opens.has(id)) lines.push(JSON.stringify(meta));
	}
	return lines;
}

/** Publish this peer's trace records to the endpoint at `url`, presenting
 * `cap` — the endpoint's capability swiss — on the socket. Returns the sink to
 * install with `enableTrace`, and the stop that ends publishing.
 *
 * The endpoint answers an admitted producer with one `trace.publish-ready`
 * mark (surfaced through `onStatus`) and refuses a socket presenting the
 * wrong swiss by closing it with `VIZ_REFUSED_CLOSE_CODE`. A refusal is
 * final — the swiss is wrong, and redialing it forever would be a busy wait
 * against a fact — so it stops this publisher and reports through
 * `onRefused`; every other close keeps the ordinary retry. */
export function publishViz(
	url: string,
	opts: {
		cap: string;
		onError?: (err: unknown) => void;
		onRefused?: (reason: string) => void;
		onStatus?: (connected: boolean) => void;
	},
): VizPublisher {
	const target = vizCapUrl(publishUrl(url), opts.cap);
	const onError = opts.onError ?? (() => {});
	const opens = new Map<string, TraceEvent>();
	const metas = new Map<string, TraceEvent>();
	// The records waiting on a socket that is not up yet, as a queue with a
	// moving head. Past the ceiling every further record drops the oldest, and
	// `Array.shift` would walk the whole buffer to do it — the most work at
	// exactly the moment there is least of it to spare. The head moves
	// instead, and the spent front is reclaimed in one pass once it is half
	// the buffer, so a long outage costs one amortized copy per record rather
	// than one full walk each.
	const pending: string[] = [];
	let head = 0;
	let socket: WebSocket | null = null;
	let stopped = false;
	let retry: ReturnType<typeof setTimeout> | undefined;

	const write = (line: string): boolean => {
		if (socket === null || socket.readyState !== WebSocket.OPEN) return false;
		try {
			socket.send(line);
			return true;
		} catch (err) {
			onError(err);
			return false;
		}
	};

	/** Give back the front of the queue once the spent half outweighs the
	 * live one. */
	const reclaim = (): void => {
		if (head === 0 || head * 2 < pending.length) return;
		pending.splice(0, head);
		head = 0;
	};

	const forget = (): void => {
		pending.length = 0;
		head = 0;
	};

	const flush = (): void => {
		while (head < pending.length) {
			if (!write(pending[head])) {
				reclaim();
				return;
			}
			head++;
		}
		forget();
	};

	const connect = (): void => {
		if (stopped) return;
		let ws: WebSocket;
		try {
			ws = new WebSocket(target);
		} catch (err) {
			onError(err);
			retry = setTimeout(connect, RETRY_MS);
			return;
		}
		socket = ws;
		ws.onopen = () => {
			for (const line of announceLines(opens, metas)) write(line);
			flush();
		};
		ws.onerror = () => {};
		// The endpoint's admission mark is the only thing a producer ever
		// hears; nothing forwarded reaches this socket.
		ws.onmessage = (msg) => {
			if (typeof msg.data !== "string" || msg.data.length > 1024) return;
			try {
				const mark = z.safeParse(PublishReadySchema, JSON.parse(msg.data));
				if (mark.success) opts.onStatus?.(true);
			} catch {
				// Not a mark; a producer ignores what it cannot read.
			}
		};
		ws.onclose = (event) => {
			if (socket === ws) socket = null;
			opts.onStatus?.(false);
			if (stopped) return;
			if (event.code === VIZ_REFUSED_CLOSE_CODE) {
				stopped = true;
				forget();
				opts.onRefused?.(event.reason || "the endpoint refused this capability");
				return;
			}
			retry = setTimeout(connect, RETRY_MS);
		};
	};

	connect();

	return {
		sink: (ev) => {
			if (stopped) return;
			if (ev.kind === "ocapn.session-opened") opens.set(ev.session, ev);
			else if (ev.kind === "ocapn.session-meta") metas.set(ev.session, ev);
			else if (ev.kind === "ocapn.session-closed") {
				opens.delete(ev.session);
				metas.delete(ev.session);
			}
			const line = JSON.stringify(ev);
			if (head === pending.length && write(line)) return;
			pending.push(line);
			if (pending.length - head > MAX_PENDING) head++;
			reclaim();
			flush();
		},
		stop: () => {
			stopped = true;
			if (retry !== undefined) clearTimeout(retry);
			forget();
			opens.clear();
			metas.clear();
			if (socket !== null) {
				try {
					socket.close();
				} catch {
					// already gone
				}
				socket = null;
			}
		},
	};
}
