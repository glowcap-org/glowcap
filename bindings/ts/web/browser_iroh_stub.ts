// Browser arm of @pancake/iroh: iroh is a native-only transport, so a browser
// dial rides a byte relay instead of QUIC. `browser-bundle.json` maps
// `@pancake/iroh` (and `/internal`) here; the stack's one dial path
// (`dial.ts`'s peer-id arm) lands in `_connectIroh`, which opens a WebSocket
// to the relay `init({ relayUrl })` named and drives the ordinary handshake
// over it. The relay only moves bytes; session authority stays end to end.

import { webSocketChannel } from "./ws_channel.ts";
import { _relayUrl } from "./mod.ts";

const NATIVE_ONLY =
	"pancake web: iroh is a native-only transport; a browser needs init({ relayUrl }) naming a byte relay to dial it";

const unavailable = (): never => {
	throw new Error(NATIVE_ONLY);
};

export const listenIroh = unavailable;
export const Reachability = {} as Record<string, never>;
export class IrohConn {
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

/** The stack's peer-id dial arm in a browser: open the configured relay's
 * WebSocket for the locator and establish the session over that byte pipe.
 * Signature mirrors the native `_connectIroh(nodeId, directAddresses,
 * reachability, host)`; reachability is the relay's concern here, so it is
 * accepted and unused. */
export async function _connectIroh(
	nodeId: string,
	directAddresses: string,
	_reachability: unknown,
	host?: unknown,
): Promise<unknown> {
	const relayUrl = _relayUrl();
	if (relayUrl === null) throw new Error(NATIVE_ONLY);
	const stack = await import("@pancake/stack");
	const hints = new Map<string, string>();
	if (directAddresses.length > 0) {
		hints.set(stack.HINT_DIRECT_ADDRESSES, directAddresses);
	}
	const locator = stack.formatPeerUri(stack.TRANSPORT_IROH, nodeId, hints);
	const url = relayUrl(locator);
	const ws = new WebSocket(url);
	await new Promise<void>((resolve, reject) => {
		const onError = () => reject(new Error(`pancake web: relay WebSocket failed: ${url}`));
		ws.addEventListener("error", onError, { once: true });
		ws.addEventListener("open", () => {
			ws.removeEventListener("error", onError);
			resolve();
		}, { once: true });
	});
	const channel = webSocketChannel(ws);
	try {
		return await stack.Session.establishDialedLocator(
			(host as InstanceType<typeof stack.Host> | undefined) ?? new stack.Host(),
			stack.TRANSPORT_IROH,
			nodeId,
			channel,
		);
	} catch (err) {
		channel.close();
		throw err;
	}
}
