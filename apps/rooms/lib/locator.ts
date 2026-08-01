// DENO-SPECIFIC: dialing a rooms locator.
//
// The rooms server, its clients, the web bridge, and the orchestrator all carry
// the server's address as one string, so a member dials the same way regardless
// of transport: a `hostname:port` dials over TCP; an `ocapn://<nodeid>.iroh?…`
// URI dials over iroh's encrypted QUIC — directly from a terminal, or through
// serve.ts's `/relay` byte pipe from a browser (which has no socket API).

import {
	connect,
	designatorHostPort,
	HINT_DIRECT_ADDRESSES,
	type Host,
	parseLocator,
	Reachability,
	type Session as SessionType,
	socketAddrDesignator,
	tcpLocator,
	TRANSPORT_IROH,
} from "@pancake/stack";

/** Whether `locator` is an `ocapn://` URI (iroh) rather than a `hostname:port`. */
export function isUriLocator(locator: string): boolean {
	return locator.includes("://");
}

/** The token the server prints after `ROOMS-SERVER-LISTENING`. */
export const ANNOUNCE_RE = /ROOMS-SERVER-LISTENING (\S+)/;

/** A loopback TCP designator for an ephemeral/bound port. */
export function loopbackTcpDesignator(port: number): string {
	return socketAddrDesignator("127.0.0.1", port);
}

/** Turn the server's announce token into a dial locator: a bare port becomes a
 * `127.0.0.1:<port>` TCP locator; an `ocapn://` URI passes through unchanged. */
export function announceToLocator(token: string): string {
	return /^\d+$/.test(token) ? loopbackTcpDesignator(Number(token)) : token;
}

/** Read a rooms server child's first `ROOMS-SERVER-LISTENING <token>` line from
 * its stdout and resolve it to a dial locator (a TCP `host:port`, or an iroh
 * `ocapn://` URI), giving up after `deadlineMs`. The orchestrator and the web
 * bridge both spawn a server and wait for this line, so the reader lives here
 * beside the announce vocabulary it parses. */
export async function readAnnouncedLocator(
	proc: Deno.ChildProcess,
	deadlineMs = 10_000,
): Promise<string> {
	const reader = proc.stdout.getReader();
	const decoder = new TextDecoder();
	let buf = "";
	const deadline = Date.now() + deadlineMs;
	try {
		while (Date.now() < deadline) {
			const { value, done } = await reader.read();
			if (done) break;
			buf += decoder.decode(value);
			const m = buf.match(ANNOUNCE_RE);
			if (m) return announceToLocator(m[1]);
		}
	} finally {
		reader.releaseLock();
	}
	throw new Error("rooms server never announced its locator");
}

// Dial an iroh URI with the posture the core requires for a peer-id open: a URI
// carrying direct-addresses dials those (Direct); a node-id-only URI resolves
// through discovery, honoring the host's configured redeem posture when one is
// passed. A terminal dials the endpoint directly through the sidecar; a browser
// rides the same `connect` to the relay (`init({ relayUrl })`), so both need the
// posture and neither may pass `undefined`. `Reachability` is the stack's own
// enum, so it carries real values in the browser (the `@pancake/iroh` re-export
// is stubbed there).
function dialIroh(locator: string, host?: Host): Promise<SessionType> {
	const loc = parseLocator(locator);
	const hints = loc.hints.get(HINT_DIRECT_ADDRESSES) ?? "";
	const fallback = host ? host.redeemReachability : Reachability.Discovery;
	return connect(locator, hints.length > 0 ? Reachability.Direct : fallback, host);
}

/** Dial a rooms peer from a locator: an `ocapn://…iroh?…` URI over iroh,
 * otherwise `hostname:port` over TCP. A `host` keys the dial with the host's
 * retained OCapN identity and live-session handoff directory (a member's listen endpoint
 * and its room dial share one Host, so an inbox it publishes giftably is the one
 * a caller's redeem withdraws). Omitted, the dial gets a fresh identity, which is
 * all an ordinary client needs.
 *
 * A browser and a terminal dial the same way; the browser's `connect` rides the
 * relay transparently. */
export function dial(locator: string, host?: Host): Promise<SessionType> {
	if (isUriLocator(locator)) {
		const loc = parseLocator(locator);
		if (loc.transport !== TRANSPORT_IROH) {
			throw new Error(
				`rooms expected an iroh ocapn:// URI, got "${loc.transport}": ${locator}`,
			);
		}
		return dialIroh(locator, host);
	}
	const { hostname, port } = designatorHostPort(locator);
	return connect(tcpLocator(hostname, port), undefined, host);
}
