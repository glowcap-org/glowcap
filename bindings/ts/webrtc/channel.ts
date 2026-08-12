/// <reference lib="dom" />

// One RTCDataChannel adapted to the stack's byte-`Channel` seam, the WebRTC
// sibling of `@pancake/web`'s `webSocketChannel` (ADR-0089). A keyed OCapN
// session runs over it byte-for-byte; framing is the host's stream delimiter's
// job, not the channel's. The channel carries opaque session bytes and never
// inspects them.

import type { Channel } from "@pancake/stack";

// An RTCDataChannel exposes `bufferedAmount` and a `bufferedamountlow` event, so
// `write` gates outbound flow without timer polling: hold the next write until
// the send buffer drains below the high-water, so a fast producer is
// backpressured rather than growing memory. SCTP's own flow control backs this.
const rtcSendHighWaterBytes = 1 << 20; // 1 MiB

function waitForDrain(dc: RTCDataChannel): Promise<void> {
	if (dc.bufferedAmount <= rtcSendHighWaterBytes || dc.readyState !== "open") {
		return Promise.resolve();
	}
	return new Promise((resolve) => {
		const done = () => {
			dc.removeEventListener("bufferedamountlow", done);
			dc.removeEventListener("close", done);
			dc.removeEventListener("error", done);
			resolve();
		};
		dc.addEventListener("bufferedamountlow", done);
		dc.addEventListener("close", done);
		dc.addEventListener("error", done);
		// If the buffer crossed the threshold between the first check and the
		// listener installation, finish immediately instead of parking forever.
		if (dc.bufferedAmount <= rtcSendHighWaterBytes || dc.readyState !== "open") {
			done();
		}
	});
}

/** Adapt an open, ordered, reliable `dc` to a `Channel`. Inbound messages flow
 * through a `ReadableStream` reader; a close ends the stream and an error faults
 * it. Outbound `write` resolves once `bufferedAmount` is at or below the
 * high-water, so a fast producer is backpressured rather than growing memory. */
export function rtcChannel(dc: RTCDataChannel): Channel {
	dc.binaryType = "arraybuffer";
	dc.bufferedAmountLowThreshold = rtcSendHighWaterBytes;
	const reader = new ReadableStream<Uint8Array>({
		start(controller) {
			dc.onmessage = (event: MessageEvent) => {
				try {
					controller.enqueue(new Uint8Array(event.data as ArrayBuffer));
				} catch { /* stream already closed */ }
			};
			dc.onclose = () => {
				try {
					controller.close();
				} catch { /* already closed */ }
			};
			dc.onerror = () => {
				try {
					controller.error(new Error("RTCDataChannel error"));
				} catch { /* already closed */ }
			};
		},
	}).getReader();
	return {
		async read(): Promise<Uint8Array | null> {
			// A clean close arrives as `done` (onclose); a transport error arrives as
			// a rejection (onerror). Let the rejection propagate, as the WebSocket
			// channel does, so a dropped channel never looks like a graceful close.
			const { value, done } = await reader.read();
			return done ? null : value ?? null;
		},
		async write(data: Uint8Array): Promise<void> {
			dc.send(data as Uint8Array<ArrayBuffer>);
			await waitForDrain(dc);
		},
		close(): void {
			try {
				dc.close();
			} catch { /* already closed */ }
		},
	};
}
