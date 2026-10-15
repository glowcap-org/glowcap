// Browser arm of @glowcap/iroh: iroh is an FFI-only transport, so a browser
// dial rides a byte relay instead of QUIC. `browser-bundle.json` maps
// `@glowcap/iroh` (and `/internal`) here; the runtime's one dial path
// (`dial.ts`'s peer-id arm) lands in `_connectIroh`, which opens a WebSocket
// to the relay `init({ relayUrl })` named and drives the ordinary handshake
// over it. The relay only moves bytes; session authority stays end to end.

import { webSocketChannel } from "../runtime/websocket.ts";
import { _relayUrl } from "./mod.ts";
import { IROH_RELAY_DIAL_ALLOWANCE_MS } from "./relay_budget.ts";

// The relay accepts this socket first and dials the far endpoint only after, so
// from the browser's side that dial and the handshake are one serial wait on
// one channel. A relay that stages its iroh dial through the driver loop spends
// the runtime's `GLOWCAP_DISCOVERY_DIAL_*` retry budget (ADR-0193) before a
// single byte moves, so the caller's handshake bound is widened by that budget
// here. Otherwise a dial that is still working reads as
// a silent partner.
const FFI_ONLY =
	"glowcap web: iroh is an FFI-only transport; a browser needs init({ relayUrl }) naming a byte relay to dial it";

const unavailable = (): never => {
	throw new Error(FFI_ONLY);
};

export const listen = unavailable;
export const Reachability = {} as Record<string, never>;
export class IrohConnection {
	constructor() {
		unavailable();
	}
}
export class IrohNetlayer {
	constructor() {
		unavailable();
	}
}
export class IrohServer {
	constructor() {
		unavailable();
	}
}

/** The runtime's peer-id dial arm in a browser: open the configured relay's
 * WebSocket for the locator and establish the session over that byte pipe.
 * Signature mirrors the FFI `_connectIroh(nodeId, directAddresses,
 * reachability, host, handshakeTimeoutMs)`; reachability is the relay's concern
 * here, so it is accepted and unused. The handshake bound is not: a relay that
 * accepts this socket and then never bridges anything is exactly the silent
 * partner the bound exists for, widened by the far dial the relay runs on this
 * socket's behalf. A caller that asked for no bound still gets none.
 *
 * The session is told that the far end holds `nodeId`
 * (`Session.bindVerifiedChannelKey`, ADR-0105). The FFI arm reads that off
 * the QUIC connection it opened; here the relay opened it, and iroh completes a
 * dial only against the endpoint it was asked for, so the fact is the relay's
 * and this passes it on. It rests on the relay being the one the page was
 * configured with, which is the same thing every byte of this session already
 * rests on. It is not a claim about the relay's honesty either way: a relay that
 * bridged somewhere else is caught rather than believed, because the far peer's
 * hello then names a key this does not, and the session refuses.
 *
 * Without this relay testimony the session can still open, but its durable
 * provenance is `unauthenticated`. */
export async function _connectIroh(
	nodeId: string,
	directAddresses: string,
	_reachability: unknown,
	host?: unknown,
	handshakeTimeoutMs?: number | null,
): Promise<unknown> {
	const relayUrl = _relayUrl();
	if (relayUrl === null) throw new Error(FFI_ONLY);
	const runtimeApi = await import("@glowcap/runtime");
	const hints = new Map<string, string>();
	if (directAddresses.length > 0) {
		hints.set(runtimeApi.HINT_DIRECT_ADDRESSES, directAddresses);
	}
	const locator = runtimeApi.formatPeerUri(runtimeApi.TRANSPORT_IROH, nodeId, hints);
	const url = relayUrl(locator);
	const ws = new WebSocket(url);
	await new Promise<void>((resolve, reject) => {
		const onError = () => reject(new Error(`glowcap web: relay WebSocket failed: ${url}`));
		ws.addEventListener("error", onError, { once: true });
		ws.addEventListener("open", () => {
			ws.removeEventListener("error", onError);
			resolve();
		}, { once: true });
	});
	const channel = webSocketChannel(ws);
	const asked = handshakeTimeoutMs === undefined ? runtimeApi.HANDSHAKE_TIMEOUT_MS : handshakeTimeoutMs;
	try {
		return await runtimeApi.Session.establishDialedLocator(
			(host as InstanceType<typeof runtimeApi.Host> | undefined) ?? new runtimeApi.Host(),
			runtimeApi.bareLocator(runtimeApi.TRANSPORT_IROH, nodeId),
			channel,
			asked ? asked + IROH_RELAY_DIAL_ALLOWANCE_MS : asked,
			nodeId,
		);
	} catch (err) {
		channel.close();
		throw err;
	}
}
