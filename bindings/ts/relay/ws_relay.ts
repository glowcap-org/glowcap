// Adapt an upgraded WebSocket to the byte relay in `relay.ts`: buffer inbound
// frames from the instant the socket opens, then pipe bytes both ways through
// `relayBytes` without parsing them. One implementation, used by any embedder
// that hosts browser peers and by the web binding's relay proof.
//
// `webSocketRelay` pipes a browser's socket to a far side the caller dials.
// `webSocketChannel` is the mirror: it presents an already-open socket as a
// `RelayChannel`, so a held registered socket (the cold-dial rendezvous,
// ADR-0088) can be the far side of another socket's relay.

import {
	type ByteSink,
	type ByteSource,
	relayBytes,
	type RelayChannel,
	type RelayConfig,
} from "./relay.ts";
import {
	type WebSocketByteChannel,
	webSocketChannel as byteWebSocketChannel,
	type WebSocketChannelOptions,
} from "@pancake/stack/websocket";

/** WebSocket-specific relay adapter limits. */
export interface WebSocketRelayOptions extends WebSocketChannelOptions {
	/** Maximum bytes admitted into the adapter's inbound queue before the relay
	 * pump reads them. Browser WebSockets cannot be paused, and the cold-dial
	 * rendezvous must install handlers before the far-side dial resolves, so this
	 * is the adapter's memory bound for early or stalled inbound bytes. */
	inboundHighWaterBytes?: number;
}

/** Maximum WebSocket message admitted by the relay adapter. WebSocket
 * fragmentation is reassembled before `message`, so this is the adapter's
 * transport-message bound, not a CapTP frame bound. The relay never parses
 * those frames. A smaller queue limit may be selected per connection. */
export const MAX_RELAY_WEBSOCKET_MESSAGE_BYTES = 1 << 20;

// The shared byte adaptation for one upgraded WebSocket: an inbound stream that
// buffers from the instant the socket opens (a peer sends its first handshake
// bytes immediately, so a handler attached later would drop them), a sink that
// backpressures on `bufferedAmount`, and idempotent close/cancel.
interface WsByteIo {
	source: ByteSource;
	sink: ByteSink;
	close: (code?: number, reason?: string) => void;
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
		...options,
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

	let channel: RelayChannel;
	try {
		channel = await getChannel();
	} catch (err) {
		console.error(`relay: dial failed: ${err instanceof Error ? err.message : String(err)}`);
		close(1011, dialFailReason);
		await cancel();
		return;
	}
	try {
		await relayBytes(source, sink, channel, config, () => close());
	} finally {
		close();
	}
}

/**
 * Present an already-open WebSocket as a `RelayChannel`, so it can be the far
 * side of another socket's `webSocketRelay`. This is the cold-dial rendezvous
 * far leg (ADR-0088): a browser that cannot be dialed holds an inbound socket
 * at the relay, and a dialer naming its identity is relayed onto this channel.
 * Byte-transparent like every relay leg — the keyed session runs end to end
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
