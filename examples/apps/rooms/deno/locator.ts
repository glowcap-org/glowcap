// A transport-neutral rooms locator.
//
// The rooms server, its clients, the web bridge, and the orchestrator all carry
// the server's address as one string, so a member dials the same way regardless
// of transport: a `host:port` dials over TCP; an `ocapn://<nodeid>.iroh?…` URI
// dials over iroh's encrypted QUIC through the sidecar. One argument, two
// transports — the demo flips between them without a different code path.

import { connect, type Connection, tcpLocator } from "@pancake/stack";
import { Reachability } from "@pancake/iroh";

/** Whether `locator` is an `ocapn://` URI (iroh) rather than a `host:port`. */
export function isUriLocator(locator: string): boolean {
	return locator.includes("://");
}

/** The token the server prints after `ROOMS-SERVER-LISTENING`. */
export const ANNOUNCE_RE = /ROOMS-SERVER-LISTENING (\S+)/;

/** Turn the server's announce token into a dial locator: a bare port becomes a
 * `127.0.0.1:<port>` TCP locator; an `ocapn://` URI passes through unchanged. */
export function announceToLocator(token: string): string {
	return /^\d+$/.test(token) ? `127.0.0.1:${token}` : token;
}

/** Dial a rooms peer from a locator: an `ocapn://…iroh?…` URI over iroh,
 * otherwise `host:port` over TCP. */
export function dial(locator: string): Promise<Connection> {
	// Rooms URIs carry direct-addresses, so dial with the explicit `.direct` posture.
	if (isUriLocator(locator)) return connect(locator, Reachability.Direct);
	const colon = locator.lastIndexOf(":");
	if (colon < 0) {
		throw new Error(
			`rooms locator is neither host:port nor an ocapn:// URI: ${locator}`,
		);
	}
	const host = locator.slice(0, colon);
	const port = Number(locator.slice(colon + 1));
	if (!Number.isInteger(port)) {
		throw new Error(`rooms locator has no valid port: ${locator}`);
	}
	return connect(tcpLocator(host, port));
}
