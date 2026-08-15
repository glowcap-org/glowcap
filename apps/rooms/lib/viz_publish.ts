// The publishing half of the live timeline feed: a peer sends its own trace to
// the shared endpoint, so the sessions it holds appear beside everyone else's.
//
// This is what makes a direct message visible. A DM is a session between two
// members, formed by three-party introduction and held on the members' own
// hosts; the room server never carries a byte of it and must not start. What
// converges is telemetry, on a socket that goes only one way — a producer
// sends records and receives nothing, so nothing here is a channel between
// peers and nothing here can carry application traffic.
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

/** The endpoint path a producer connects to. Viewers use `/`; this is the
 * other half of that split, named once so the endpoint and its producers
 * cannot drift apart. */
export const VIZ_PUBLISH_PATH = "/publish";

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

/** Publish this peer's trace records to the endpoint at `url`. Returns the
 * sink to install with `enableTrace`, and the stop that ends publishing. */
export function publishViz(
	url: string,
	opts: { onError?: (err: unknown) => void } = {},
): VizPublisher {
	const target = publishUrl(url);
	const onError = opts.onError ?? (() => {});
	const opens = new Map<string, TraceEvent>();
	const metas = new Map<string, TraceEvent>();
	const pending: string[] = [];
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

	const flush = (): void => {
		while (pending.length > 0) {
			if (!write(pending[0])) return;
			pending.shift();
		}
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
		ws.onclose = () => {
			if (socket === ws) socket = null;
			if (!stopped) retry = setTimeout(connect, RETRY_MS);
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
			if (pending.length === 0 && write(line)) return;
			pending.push(line);
			while (pending.length > MAX_PENDING) pending.shift();
			flush();
		},
		stop: () => {
			stopped = true;
			if (retry !== undefined) clearTimeout(retry);
			pending.length = 0;
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
