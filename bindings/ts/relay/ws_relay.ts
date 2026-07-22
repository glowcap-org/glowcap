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

// The browser-bound sink gates on this send-buffer high-water: a `WebSocket`
// has no drain event, so `write` polls `bufferedAmount` down before returning.
// That is what backpressures the far side — while a slow browser's buffer is
// full, `relayBytes` stops reading the far channel, so its TCP/QUIC receive
// window closes. Without this gate the relay would drain the far side as fast
// as it arrives and pile it into the WebSocket's own queue unbounded.
const wsSendHighWaterBytes = 1 << 20; // 1 MiB
const wsDrainPollMs = 4;

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

function wsByteIo(socket: WebSocket): WsByteIo {
	socket.binaryType = "arraybuffer";

	const fromWs = new ReadableStream<Uint8Array>({
		start(controller) {
			socket.onmessage = (event: MessageEvent) => {
				try {
					controller.enqueue(new Uint8Array(event.data as ArrayBuffer));
				} catch { /* stream already closed by teardown */ }
			};
			socket.onclose = () => {
				try {
					controller.close();
				} catch { /* already closed */ }
			};
			socket.onerror = () => {
				try {
					controller.error(new Error("WebSocket error"));
				} catch { /* already closed */ }
			};
		},
	});
	const reader = fromWs.getReader();

	const source: ByteSource = {
		read: async () => {
			const { value, done } = await reader.read();
			return done ? null : value;
		},
	};
	const sink: ByteSink = {
		write: async (chunk: Uint8Array) => {
			// A dialer socket may still be completing its WebSocket upgrade when the
			// far side already has bytes to deliver — the cold-dial rendezvous
			// buffers the accept side's early hello, so the very first far→dialer
			// write can land before the dialer socket finishes opening. Wait for the
			// open rather than throwing and tearing the bridge down. A socket that is
			// already open skips the wait; one that closes while connecting rejects.
			if (socket.readyState === WebSocket.CONNECTING) {
				await new Promise<void>((resolve, reject) => {
					socket.addEventListener("open", () => resolve(), { once: true });
					socket.addEventListener("error", () => reject(new Error("WebSocket error")), {
						once: true,
					});
					socket.addEventListener("close", () => reject(new Error("WebSocket closed")), {
						once: true,
					});
				});
			}
			if (socket.readyState !== WebSocket.OPEN) {
				throw new Error("WebSocket closed");
			}
			socket.send(chunk);
			// Backpressure: hold the far→browser leg until the send buffer drains
			// below the high-water, so the far side's flow control engages.
			while (
				socket.bufferedAmount > wsSendHighWaterBytes &&
				socket.readyState === WebSocket.OPEN
			) {
				await new Promise((resolve) => setTimeout(resolve, wsDrainPollMs));
			}
		},
	};
	const close = (code?: number, reason?: string) => {
		try {
			socket.close(code, reason);
		} catch { /* already closed */ }
	};
	const cancel = () => reader.cancel().catch(() => {});

	return { source, sink, close, cancel };
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
): Promise<void> {
	const { source, sink, close, cancel } = wsByteIo(socket);

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
export function webSocketChannel(socket: WebSocket): RelayChannel {
	const { source, sink, close } = wsByteIo(socket);
	return {
		read: () => source.read(),
		write: (chunk: Uint8Array) => sink.write(chunk),
		close: () => close(),
	};
}
