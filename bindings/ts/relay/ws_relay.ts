// Adapt an upgraded WebSocket to the byte relay in `relay.ts`: buffer inbound
// frames from the instant the socket opens, then pipe bytes both ways through
// `relayBytes` without parsing them. One implementation, used by any embedder
// that hosts browser peers and by the web binding's relay proof.
//
// `webSocketRelay` pipes a browser's socket to a far side the caller dials.
// `webSocketChannel` is the mirror: it presents an already-open socket as a
// `RelayChannel`, so a held registered socket (the cold-dial rendezvous,
// ADR-0034) can be the far side of another socket's relay.

import { type ByteSink, type ByteSource, relayBytes, type RelayChannel, type RelayConfig } from "./relay.ts";
import type { Timer } from "@glowcap/runtime/transport";
import {
	type WebSocketByteChannel,
	webSocketChannel as byteWebSocketChannel,
	type WebSocketChannelOptions,
} from "@glowcap/runtime/websocket";
import { retainCleanupFailures } from "@glowcap/runtime/transport";
import { BINDING_WEBSOCKET_MESSAGE_CAP_BYTES } from "@glowcap/abi";

/** A far-side dial the relay could not complete. The browser's socket was
 * already closed with code 1011 and the caller's dial-fail reason, so nothing
 * about this rejection is unhandled; it exists so an embedder can log an
 * ordinary environmental failure as what it is (an unreachable or refusing
 * target, usually retried by the browser on a backoff) instead of an
 * unexpected serving fault. `cause` carries the dial's own error. */
export class RelayDialFailed extends Error {
	constructor(reason: string, cause: unknown) {
		super(`${reason}: ${cause instanceof Error ? cause.message : String(cause)}`, { cause });
		this.name = "RelayDialFailed";
	}
}

/** Log one relay-serving rejection in the runtime-line vocabulary. Identical
 * dial failures report on an exponentially widening interval while the outage
 * continues, then forget themselves after one quiet interval. Anything else
 * keeps the loud `unexpected error` label it deserves. One authority, so the
 * embedders that host `webSocketRelay` cannot drift apart in wording. */
export function relayFailureLogger(
	log: (line: string) => void = (line) => console.error(line),
	initialWindowMs: number = 30_000,
	maximumWindowMs: number = initialWindowMs * 20,
): (err: unknown) => void {
	if (
		!Number.isSafeInteger(initialWindowMs) || initialWindowMs < 1 ||
		!Number.isSafeInteger(maximumWindowMs) || maximumWindowMs < initialWindowMs
	) throw new RangeError("relay failure log windows are invalid");
	interface FailureWindow {
		count: number;
		intervalMs: number;
		timer: Timer | null;
	}
	const seen = new Map<string, FailureWindow>();
	const schedule = (line: string, entry: FailureWindow): void => {
		entry.timer = setTimeout(() => {
			if (entry.count === 0) {
				seen.delete(line);
				return;
			}
			log(`${line} (repeated ${entry.count} more times)`);
			entry.count = 0;
			entry.intervalMs = Math.min(entry.intervalMs * 2, maximumWindowMs);
			schedule(line, entry);
		}, entry.intervalMs);
		// A pending flush must not pin the process open past its last socket.
		if (typeof entry.timer === "number") Deno.unrefTimer?.(entry.timer);
	};
	return (err) => {
		if (!(err instanceof RelayDialFailed)) {
			log(`relay: unexpected error: ${err instanceof Error ? err.message : String(err)}`);
			return;
		}
		const line = `relay: dial failed: ${err.message}`;
		const held = seen.get(line);
		if (held !== undefined) {
			held.count++;
			return;
		}
		log(line);
		const entry: FailureWindow = {
			count: 0,
			intervalMs: initialWindowMs,
			timer: null,
		};
		seen.set(line, entry);
		schedule(line, entry);
	};
}

/** WebSocket-specific relay adapter limits. */
export interface WebSocketRelayOptions extends WebSocketChannelOptions {
	/** Maximum bytes admitted into the adapter's inbound queue before the relay
	 * pump reads them. Browser WebSockets cannot be paused, and the cold-dial
	 * rendezvous must install handlers before the far-side dial resolves, so this
	 * is the adapter's memory bound for early or stalled inbound bytes. */
	inboundHighWaterBytes?: number;
	/** Cancel this relay session through its joined WebSocket close barrier.
	 * Process embedders use this to stop active pumps before releasing their
	 * listener; the far channel still closes through pair-atomic teardown. */
	signal?: AbortSignal;
}

/** Maximum WebSocket message admitted by the relay adapter. WebSocket
 * fragmentation is reassembled before `message`, so this is the adapter's
 * transport-message bound, not a CapTP frame bound. The relay never parses
 * those frames. A smaller queue limit may be selected per connection. */
export const MAX_RELAY_WEBSOCKET_MESSAGE_BYTES = BINDING_WEBSOCKET_MESSAGE_CAP_BYTES;

// The shared byte adaptation for one upgraded WebSocket: an inbound stream that
// buffers from the instant the socket opens (a peer sends its first handshake
// bytes immediately, so a handler attached later would drop them), a sink that
// backpressures on `bufferedAmount`, and idempotent close/cancel.
interface WsByteIo {
	source: ByteSource;
	sink: ByteSink;
	close: (code?: number, reason?: string) => Promise<void>;
	cancel: () => Promise<void>;
}

function wsByteIo(socket: WebSocket, options?: WebSocketRelayOptions): WsByteIo {
	const inboundHighWaterBytes = options?.inboundHighWaterBytes ??
		MAX_RELAY_WEBSOCKET_MESSAGE_BYTES;
	if (
		!Number.isSafeInteger(inboundHighWaterBytes) ||
		inboundHighWaterBytes <= 0 ||
		inboundHighWaterBytes > MAX_RELAY_WEBSOCKET_MESSAGE_BYTES
	) {
		throw new RangeError(
			`relay WebSocket message bound must be an integer from 1 to ${MAX_RELAY_WEBSOCKET_MESSAGE_BYTES}`,
		);
	}
	const channel: WebSocketByteChannel = byteWebSocketChannel(socket, {
		closeTimeoutMs: options?.closeTimeoutMs,
		inboundHighWaterBytes,
	});
	return {
		source: { read: () => channel.read() },
		// The shared channel owns serialized, bounded outbound chunking. Keeping
		// that policy there makes browser sessions and both relay legs identical.
		sink: { write: (chunk) => channel.write(chunk) },
		close: (code, reason) => channel.close(code, reason),
		cancel: () => channel.cancel(),
	};
}

/**
 * Pipe an upgraded WebSocket to the channel `getChannel` opens, in both
 * directions, until either leg ends. Resolves when the session is fully torn
 * down, dial failure included.
 *
 * The WebSocket handlers are wired synchronously, before the async dial: a
 * browser peer sends its first handshake bytes the instant the socket opens, so
 * a handler attached after the dial resolved would drop them. The inbound
 * stream buffers those chunks until the channel is ready. On a dial failure the
 * socket closes with 1011 so the browser learns the relay leg failed, not the
 * session. Capacity admission and the far-side allow-list are the caller's job;
 * this is the pump alone.
 */
export async function webSocketRelay(
	socket: WebSocket,
	getChannel: () => Promise<RelayChannel>,
	dialFailReason: string,
	config: RelayConfig,
	options?: WebSocketRelayOptions,
): Promise<void> {
	const { source, sink, close, cancel } = wsByteIo(socket, options);
	const stop = () => void close(1001, "relay stopped");
	if (options?.signal?.aborted) stop();
	else options?.signal?.addEventListener("abort", stop, { once: true });

	try {
		let channel: RelayChannel;
		try {
			channel = await getChannel();
		} catch (err) {
			throw new RelayDialFailed(
				dialFailReason,
				await retainCleanupFailures(err, [
					cancel,
					() => close(1011, dialFailReason),
				]),
			);
		}
		await relayBytes(source, sink, channel, config, () => close());
	} finally {
		options?.signal?.removeEventListener("abort", stop);
	}
}

/**
 * Present an already-open WebSocket as a `RelayChannel`, so it can be the far
 * side of another socket's `webSocketRelay`. This is the cold-dial rendezvous
 * far leg (ADR-0034): a browser that cannot be dialed holds an inbound socket
 * at the relay, and a dialer naming its identity is relayed onto this channel.
 * Byte-transparent like every relay leg: the keyed session runs end to end
 * between the two sockets and the relay parses nothing.
 */
export function webSocketChannel(
	socket: WebSocket,
	options?: WebSocketRelayOptions,
): RelayChannel {
	const { source, sink, close } = wsByteIo(socket, options);
	return {
		read: () => source.read(),
		write: (chunk: Uint8Array) => sink.write(chunk),
		close: () => close(),
	};
}
