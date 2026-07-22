// One WebSocket adapted to the stack's byte-`Channel` seam, shared by every
// place that carries pancake bytes over a WebSocket: the browser binding's own
// dial (`adapter.ts`), the accepting-host test (`test/serve_ws_host.ts`), and
// the rooms relay test. Each caller differs only in how it gets the socket
// (opening it, or being handed an accepted one) and whether it wraps a
// `localAddr`; the byte plumbing is this one function.

import type { Channel } from "@pancake/stack";

// A `WebSocket` has no drain event, so `write` gates outbound flow by polling
// `bufferedAmount` down below this high-water before it resolves: a producer
// outrunning its partner stops being read from until its send buffer drains,
// which closes the far side's flow-control window instead of growing tab memory.
const wsSendHighWaterBytes = 1 << 20; // 1 MiB
const wsDrainPollMs = 4;

/** Adapt `ws` (already open, or opening — messages cannot arrive before the
 * open event) to a `Channel`. Inbound frames flow through a `ReadableStream`
 * reader; a close or error ends the stream. Outbound `write` resolves once the
 * socket's send buffer is at or below the high-water, so a fast producer is
 * backpressured rather than growing tab memory unbounded. The inbound queue is
 * bounded by the reader keeping up. */
export function webSocketChannel(ws: WebSocket): Channel {
	ws.binaryType = "arraybuffer";
	const reader = new ReadableStream<Uint8Array>({
		start(controller) {
			ws.onmessage = (event: MessageEvent) => {
				try {
					controller.enqueue(new Uint8Array(event.data as ArrayBuffer));
				} catch { /* stream already closed */ }
			};
			ws.onclose = () => {
				try {
					controller.close();
				} catch { /* already closed */ }
			};
			ws.onerror = () => {
				try {
					controller.error(new Error("WebSocket error"));
				} catch { /* already closed */ }
			};
		},
	}).getReader();
	return {
		async read(): Promise<Uint8Array | null> {
			// A clean close arrives as `done` via `controller.close()` (onclose); a
			// transport error arrives as a rejection via `controller.error()`
			// (onerror). Let the rejection propagate — the native adapters do, and
			// `Session.serve` promises to reject on a transport error. Swallowing it
			// into an EOF here would make a dropped socket look like a graceful close.
			const { value, done } = await reader.read();
			return done ? null : value ?? null;
		},
		async write(data: Uint8Array): Promise<void> {
			ws.send(data as Uint8Array<ArrayBuffer>);
			while (ws.bufferedAmount > wsSendHighWaterBytes && ws.readyState === WebSocket.OPEN) {
				await new Promise((resolve) => setTimeout(resolve, wsDrainPollMs));
			}
		},
		close(): void {
			ws.close();
		},
	};
}
