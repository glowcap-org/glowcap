// A transport-neutral rooms locator.
//
// The rooms server, its clients, the web bridge, and the orchestrator all carry
// the server's address as one string, so a member dials the same way regardless
// of transport: a `hostname:port` dials over TCP; an `ocapn://<nodeid>.iroh?…` URI
// dials over iroh's encrypted QUIC through the sidecar. One argument, two
// transports, the demo flips between them without a different code path.

import {
	connect,
	designatorHostPort,
	HINT_DIRECT_ADDRESSES,
	type Host,
	parseLocator,
	type Session,
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

/** Dial a rooms peer from a locator: an `ocapn://…iroh?…` URI over iroh,
 * otherwise `hostname:port` over TCP. A `host` keys the dial with the host's
 * retained OCapN identity and shared gift registry, what a directory's
 * member dial-back needs so the gift it later mints (signed with that identity)
 * matches the deposit's provenance. Omitted, the dial gets a fresh identity,
 * which is all an ordinary client needs. Every dial goes through the one
 * CapTP dialer `connect(locator[, reachability][, host])`. */
export function dial(locator: string, host?: Host): Promise<Session> {
	if (isUriLocator(locator)) {
		const loc = parseLocator(locator);
		if (loc.transport !== TRANSPORT_IROH) {
			throw new Error(
				`rooms expected an iroh ocapn:// URI, got "${loc.transport}": ${locator}`,
			);
		}
		// A URI carrying direct-addresses dials those directly (relay-less Direct);
		// a node-id-only URI resolves the peer through discovery. The hint-less
		// fallback honors the host's configured redeem posture when one is passed
		// (a no-relay host lowers it to DiscoveryNoRelay), exactly as the binding's
		// own `dialExporter` redeem path does; a host-less dial keeps the plain
		// Discovery default.
		type IrohReachability = (typeof Reachability)[keyof typeof Reachability];
		const hints = loc.hints.get(HINT_DIRECT_ADDRESSES) ?? "";
		const fallback = host
			? (host.redeemReachability as IrohReachability)
			: Reachability.Discovery;
		return connect(
			locator,
			hints.length > 0 ? Reachability.Direct : fallback,
			host,
		);
	}
	const { hostname, port } = designatorHostPort(locator);
	return connect(tcpLocator(hostname, port), undefined, host);
}
