/// <reference lib="dom" />

// One RTCDataChannel adapted to the runtime's `Channel` seam. Each read and
// write is one DataChannel message. The Host session decides from transport
// metadata that WebRTC packets carry bare codec frames; this adapter only moves
// bounded opaque binary packets.

import type { Channel } from "@pancake/runtime";
import { TRANSPORT_WEBRTC_MAX_PACKET_BYTES, WEBRTC_DATA_CHANNEL_QUEUE_BYTES } from "@pancake/abi";

// An RTCDataChannel exposes `bufferedAmount` and a `bufferedamountlow` event, so
// `write` gates outbound flow without timer polling: hold the next write until
// the send buffer drains below the high-water, so a fast producer is
// backpressured rather than growing memory. SCTP's own flow control backs this.
const rtcSendHighWaterBytes = WEBRTC_DATA_CHANNEL_QUEUE_BYTES;
const rtcReceiveMaxMessages = 256;
const rtcReceiveMaxQueuedBytes = WEBRTC_DATA_CHANNEL_QUEUE_BYTES;

function waitForDrain(dc: RTCDataChannel): Promise<void> {
	if (dc.readyState !== "open") return Promise.reject(new Error("webrtc: data channel closed"));
	if (dc.bufferedAmount <= rtcSendHighWaterBytes) return Promise.resolve();
	return new Promise((resolve, reject) => {
		let settled = false;
		const settle = (fn: () => void) => {
			if (settled) return;
			settled = true;
			dc.removeEventListener("bufferedamountlow", onDrain);
			dc.removeEventListener("close", onClose);
			dc.removeEventListener("error", onError);
			fn();
		};
		const onClose = () => settle(() => reject(new Error("webrtc: data channel closed")));
		const onError = () => settle(() => reject(new Error("webrtc: data channel error")));
		const onDrain = () => {
			if (dc.readyState === "open") settle(resolve);
			else onClose();
		};
		dc.addEventListener("bufferedamountlow", onDrain);
		dc.addEventListener("close", onClose);
		dc.addEventListener("error", onError);
		// If the buffer crossed the threshold between the first check and the
		// listener installation, finish immediately instead of parking forever.
		if (dc.bufferedAmount <= rtcSendHighWaterBytes) onDrain();
		else if (dc.readyState !== "open") onClose();
	});
}

type PendingRead = {
	resolve(value: Uint8Array | null): void;
	reject(error: unknown): void;
};

function binaryPacket(data: unknown): Uint8Array | null {
	if (data instanceof ArrayBuffer) return new Uint8Array(data);
	if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
	return null;
}

/** Adapt an ordered, reliable `dc` to a `Channel`. Inbound packets are bounded
 * until the runtime claims them; outbound writes resolve once `bufferedAmount`
 * is at or below the high-water, so a fast producer is backpressured rather
 * than growing memory. */
export function rtcChannel(dc: RTCDataChannel): Channel {
	dc.binaryType = "arraybuffer";
	dc.bufferedAmountLowThreshold = rtcSendHighWaterBytes;
	const queue: Uint8Array[] = [];
	let queuedBytes = 0;
	let pending: PendingRead | null = null;
	let writing: Promise<void> = Promise.resolve();
	let pendingWriteBytes = 0;
	let closed = false;
	let failure: unknown = null;

	function fail(error: unknown): void {
		if (failure == null) failure = error;
		closed = true;
		const waiter = pending;
		pending = null;
		if (waiter) waiter.reject(error);
		dc.close();
	}

	function close(): void {
		closed = true;
		const waiter = pending;
		pending = null;
		if (waiter) waiter.resolve(null);
	}

	dc.onmessage = (event: MessageEvent) => {
		const packet = binaryPacket(event.data);
		if (packet == null) {
			fail(new Error("webrtc: expected binary data channel message"));
			return;
		}
		if (packet.byteLength > TRANSPORT_WEBRTC_MAX_PACKET_BYTES) {
			fail(new Error("webrtc: packet exceeds transport cap"));
			return;
		}
		if (
			queue.length >= rtcReceiveMaxMessages ||
			queuedBytes + packet.byteLength > rtcReceiveMaxQueuedBytes
		) {
			fail(new Error("webrtc: inbound packet queue overflow"));
			return;
		}
		const waiter = pending;
		if (waiter) {
			pending = null;
			waiter.resolve(packet);
			return;
		}
		queue.push(packet);
		queuedBytes += packet.byteLength;
	};
	dc.onclose = close;
	dc.onerror = () => fail(new Error("webrtc: data channel error"));

	return {
		read(): Promise<Uint8Array | null> {
			const packet = queue.shift();
			if (packet) {
				queuedBytes -= packet.byteLength;
				return Promise.resolve(packet);
			}
			if (failure != null) return Promise.reject(failure);
			if (closed) return Promise.resolve(null);
			if (pending) return Promise.reject(new Error("webrtc: concurrent reads are not supported"));
			return new Promise<Uint8Array | null>((resolve, reject) => {
				pending = { resolve, reject };
			});
		},
		async write(data: Uint8Array): Promise<void> {
			if (data.byteLength > TRANSPORT_WEBRTC_MAX_PACKET_BYTES) {
				throw new Error("webrtc: packet exceeds transport cap");
			}
			if (pendingWriteBytes + data.byteLength > rtcSendHighWaterBytes) {
				throw new Error("webrtc: outbound queue exceeded");
			}
			pendingWriteBytes += data.byteLength;
			const current = writing.then(async () => {
				if (dc.readyState !== "open") throw new Error("webrtc: data channel closed");
				dc.send(data as Uint8Array<ArrayBuffer>);
				await waitForDrain(dc);
			}).finally(() => {
				pendingWriteBytes -= data.byteLength;
			});
			writing = current;
			await current;
		},
		close(): void {
			dc.onmessage = null;
			dc.onclose = null;
			dc.onerror = null;
			close();
			dc.close();
		},
	};
}
