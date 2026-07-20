// DENO-SPECIFIC: the rooms relay endpoint's server side. It adapts an upgraded
// WebSocket to the byte relay in @pancake/relay and dials the far side: TCP for a
// `host:port` locator, iroh for an `ocapn://` URI. The bytes are never parsed,
// so the keyed OCapN session rides through end to end.

import { type RelayChannel, type RelayConfig, webSocketRelay } from "@pancake/relay";
import { isUriLocator } from "./lib/locator.ts";

const idleTimeoutMs = 60_000;
// Instantaneous memory is bounded by the WebSocket send-buffer backpressure in
// @pancake/relay, and liveness by the idle timeout; this per-session byte total
// is only a runaway backstop, set far above any real chat session's traffic so
// a peer sitting in a room for hours is never dropped mid-conversation.
const maxBytesPerSession = 1024 * 1024 * 1024;
const tcpDialTimeoutMs = 5_000;
const maxRelaySessions = 100;

// Live relay sessions, counted from capacity admission until the relay's
// pair-atomic teardown finishes (dial failures included).
let activeRelaySessions = 0;

/** Whether the relay may dial `locator`. An `ocapn://` URI is allowed to any
 * iroh node: node ids are key-verified and the keyed handshake carries session
 * authority end to end. That open-destination policy is deliberate for the demo,
 * and it is named attack surface: it makes the relay a bandwidth amplifier to
 * any iroh peer, bounded only by capacity and per-session backpressure. A real
 * deployment pins the iroh destination set the way TCP is already pinned to the
 * room server itself, `127.0.0.1:<roomPort>`. */
export function relayAllowed(locator: string, roomPort: number): boolean {
	if (isUriLocator(locator)) {
		return locator.startsWith("ocapn://");
	}
	return locator === `127.0.0.1:${roomPort}`;
}

/** Whether a browser `Origin` header may drive the relay: absent (non-browser
 * clients) or matching the request's own `Host`. A cross-origin page is
 * refused before the WebSocket upgrade. */
export function relayOriginAllowed(origin: string | null, host: string | null): boolean {
	if (!origin) return true;
	if (!host) return false;
	try {
		return new URL(origin).host === host;
	} catch {
		return false;
	}
}

const relayConfig: RelayConfig = { idleTimeoutMs, maxBytesPerSession };

/** Admit a relay session under the capacity cap, then hand the WebSocket to the
 * shared byte pump against the channel `getChannel` opens. The pump
 * (`webSocketRelay`) owns the byte plumbing and teardown; this wrapper owns only
 * the live-session count. */
function relayViaChannel(
	socket: WebSocket,
	getChannel: () => Promise<RelayChannel>,
	dialFailReason: string,
): void {
	if (activeRelaySessions >= maxRelaySessions) {
		socket.close(1008, "relay capacity exceeded");
		return;
	}
	activeRelaySessions++;
	webSocketRelay(socket, getChannel, dialFailReason, relayConfig).catch((err) => {
		console.error(
			`relay: unexpected error: ${err instanceof Error ? err.message : String(err)}`,
		);
	}).finally(() => {
		activeRelaySessions--;
	});
}

async function dialTcp(locator: string): Promise<RelayChannel> {
	const colonIdx = locator.lastIndexOf(":");
	if (colonIdx === -1) throw new Error("invalid TCP target format");
	const host = locator.slice(0, colonIdx);
	const port = Number(locator.slice(colonIdx + 1));
	if (!Number.isInteger(port) || port < 1 || port > 65535) {
		throw new Error("invalid port");
	}
	const connecting = Deno.connect({ hostname: host, port });
	let dialTimer: number | undefined;
	let timedOut = false;
	let tcp: Deno.TcpConn;
	try {
		tcp = await Promise.race([
			connecting,
			new Promise<never>((_, reject) => {
				dialTimer = setTimeout(() => {
					timedOut = true;
					reject(new Error("TCP dial timeout"));
				}, tcpDialTimeoutMs) as unknown as number;
			}),
		]);
	} finally {
		// Disarm the timer on the happy path (or it would later close the live
		// connection). If it already won the race, close the abandoned connect
		// when it lands late so a slow dial leaks no fd.
		clearTimeout(dialTimer);
		if (timedOut) connecting.then((late) => late.close()).catch(() => {});
	}
	let reader;
	try {
		reader = tcp.readable.getReader();
	} catch (err) {
		tcp.close();
		throw err;
	}
	let writer;
	try {
		writer = tcp.writable.getWriter();
	} catch (err) {
		reader.releaseLock();
		tcp.close();
		throw err;
	}
	return {
		read: async () => {
			const result = await reader.read();
			return result.done ? null : result.value;
		},
		write: (chunk) => writer.write(chunk),
		close: () => {
			reader.releaseLock();
			writer.releaseLock();
			tcp.close();
		},
	};
}

type IrohRelayModule = {
	dialLocatorForRelay: (locator: string, reachability: unknown) => Promise<RelayChannel>;
	Reachability: Record<string, unknown>;
};
// Cache the promise, not the result, so concurrent dials load the module once.
let irohModulePromise: Promise<IrohRelayModule> | null = null;
async function dialIroh(locator: string): Promise<RelayChannel> {
	irohModulePromise ??= import("@pancake/iroh") as Promise<IrohRelayModule>;
	const irohModule = await irohModulePromise;
	return await irohModule.dialLocatorForRelay(locator, irohModule.Reachability.Discovery);
}

/** Relay an upgraded WebSocket to `locator`: TCP for `host:port`, iroh for an
 * `ocapn://` URI. The caller has already checked `relayAllowed`. */
export function relayToLocator(socket: WebSocket, locator: string): void {
	if (locator.length > 2048) {
		socket.close(1008, "locator too long");
		return;
	}
	if (isUriLocator(locator)) {
		if (!locator.startsWith("ocapn://")) {
			socket.close(1008, "unsupported URI scheme");
			return;
		}
		relayViaChannel(socket, () => dialIroh(locator), "iroh relay dial failed");
	} else {
		relayViaChannel(socket, () => dialTcp(locator), "TCP relay target unreachable");
	}
}
