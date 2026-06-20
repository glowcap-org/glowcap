// A transport-neutral rooms locator.
//
// The rooms server, its clients, the web bridge, and the orchestrator all carry
// the server's address as one string, so a member dials the same way regardless
// of transport: a `host:port` dials over TCP; an `ocapn://<nodeid>.iroh?…` URI
// dials over iroh's encrypted QUIC through the sidecar. One argument, two
// transports, the demo flips between them without a different code path.

import { Connection, type Node, parseLocator } from "@pancake/stack";
import { connectIroh, Reachability } from "@pancake/iroh";

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
 * otherwise `host:port` over TCP. A `node` keys the dial with the node's
 * retained OCapN identity and shared gift registry, what a directory's
 * member dial-back needs so the gift it later mints (signed with that identity)
 * matches the deposit's provenance. Omitted, the dial gets a fresh identity,
 * which is all an ordinary client needs. */
export function dial(locator: string, node?: Node): Promise<Connection> {
	if (isUriLocator(locator)) {
		const loc = parseLocator(locator);
		if (loc.transport !== "iroh") {
			throw new Error(
				`rooms expected an iroh ocapn:// URI, got "${loc.transport}": ${locator}`,
			);
		}
		// A URI carrying direct-addresses dials those directly (relay-less Direct);
		// a node-id-only URI resolves the peer through discovery. The hint-less
		// fallback honors the node's configured redeem posture when one is passed
		// (a no-relay node lowers it to DiscoveryNoRelay), exactly as the binding's
		// own `dialExporter` redeem path does; a node-less dial keeps the plain
		// Discovery default. The same helper covers an offline direct dial and an
		// internet dial-by-id.
		type IrohReachability = (typeof Reachability)[keyof typeof Reachability];
		const hints = loc.hints.get("direct-addresses") ?? "";
		const fallback = node
			? (node.redeemReachability as IrohReachability)
			: Reachability.Discovery;
		return connectIroh(
			loc.designator,
			hints,
			hints.length > 0 ? Reachability.Direct : fallback,
			node,
		);
	}
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
	return Connection.connect(host, port, node);
}
