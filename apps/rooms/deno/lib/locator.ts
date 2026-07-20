// DENO-SPECIFIC: dialing a rooms locator.
//
// The rooms server, its clients, the web bridge, and the orchestrator all carry
// the server's address as one string, so a member dials the same way regardless
// of transport: a `hostname:port` dials over TCP; an `ocapn://<nodeid>.iroh?…`
// URI dials over iroh's encrypted QUIC — directly from a terminal, or through
// web.ts's `/relay` byte pipe from a browser (which has no socket API).

import {
	connect,
	designatorHostPort,
	HINT_DIRECT_ADDRESSES,
	type Host,
	parseLocator,
	type Session as SessionType,
	socketAddrDesignator,
	tcpLocator,
	TRANSPORT_IROH,
} from "@pancake/stack";
import { Reachability } from "@pancake/iroh";

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

// TERMINAL-ONLY: dial iroh directly through the sidecar. A URI carrying
// direct-addresses dials those (Direct); a node-id-only URI resolves through
// discovery, honoring the host's configured redeem posture when one is passed.
function dialIrohDirect(locator: string, host?: Host): Promise<SessionType> {
	type IrohReachability = (typeof Reachability)[keyof typeof Reachability];
	const loc = parseLocator(locator);
	const hints = loc.hints.get(HINT_DIRECT_ADDRESSES) ?? "";
	const fallback = host ? (host.redeemReachability as IrohReachability) : Reachability.Discovery;
	return connect(
		locator,
		hints.length > 0 ? Reachability.Direct : fallback,
		host,
	);
}

/** Dial a rooms peer from a locator: an `ocapn://…iroh?…` URI over iroh,
 * otherwise `hostname:port` over TCP. A `host` keys the dial with the host's
 * retained OCapN identity and shared gift registry (member listen + room dial
 * share one Host so register can `fetch("dm")` on the room session). Omitted,
 * the dial gets a fresh identity, which is all an ordinary client needs.
 *
 * In a browser (`window` present) an iroh URI dials through the stack's own
 * `connect`, whose browser arm rides the relay `init({ relayUrl })` named; in
 * a terminal it is dialed directly. */
export function dial(locator: string, host?: Host): Promise<SessionType> {
	if (isUriLocator(locator)) {
		const loc = parseLocator(locator);
		if (loc.transport !== TRANSPORT_IROH) {
			throw new Error(
				`rooms expected an iroh ocapn:// URI, got "${loc.transport}": ${locator}`,
			);
		}
		return typeof window !== "undefined"
			? connect(
				locator,
				undefined,
				host,
			)
			: dialIrohDirect(locator, host);
	}
	const { hostname, port } = designatorHostPort(locator);
	return connect(tcpLocator(hostname, port), undefined, host);
}
