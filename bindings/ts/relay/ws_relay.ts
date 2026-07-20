// Adapt an upgraded WebSocket to the byte relay in `relay.ts`: buffer inbound
// frames from the instant the socket opens, dial the far side, then pipe bytes
// both ways through `relayBytes` without parsing them. One implementation, used
// by any embedder that hosts browser peers and by the web binding's relay proof.

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
	const wsSource: ByteSource = {
		read: async () => {
			const { value, done } = await reader.read();
			return done ? null : value;
		},
	};
	const wsSink: ByteSink = {
		write: async (chunk: Uint8Array) => {
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

	const closeWs = (code?: number, reason?: string) => {
		try {
			socket.close(code, reason);
		} catch { /* already closed */ }
	};

	let channel: RelayChannel;
	try {
		channel = await getChannel();
	} catch (err) {
		console.error(`relay: dial failed: ${err instanceof Error ? err.message : String(err)}`);
		closeWs(1011, dialFailReason);
		await reader.cancel().catch(() => {});
		return;
	}
	try {
		await relayBytes(wsSource, wsSink, channel, config, () => closeWs());
	} finally {
		closeWs();
	}
}
