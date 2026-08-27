/// <reference lib="dom" />

import { rtcChannel } from "../channel.ts";
import { TRANSPORT_WEBRTC_MAX_PACKET_BYTES, WEBRTC_DATA_CHANNEL_QUEUE_BYTES } from "@pancake/abi";
import { assertDeepEquals } from "../../dogfood/assert.ts";

class FakeDataChannel extends EventTarget {
	binaryType: BinaryType = "blob";
	bufferedAmount = 0;
	bufferedAmountLowThreshold = 0;
	readyState: RTCDataChannelState = "open";
	readonly sent: Uint8Array[] = [];
	onmessage: ((event: MessageEvent) => void) | null = null;
	onclose: (() => void) | null = null;
	onerror: (() => void) | null = null;

	send(data: Uint8Array): void {
		this.sent.push(new Uint8Array(data));
	}

	deliver(data: unknown): void {
		this.onmessage?.(new MessageEvent("message", { data }));
	}

	drain(): void {
		this.bufferedAmount = 0;
		this.dispatchEvent(new Event("bufferedamountlow"));
	}

	close(): void {
		this.readyState = "closed";
		this.onclose?.();
		this.dispatchEvent(new Event("close"));
	}
}

async function rejectionOf(promise: Promise<unknown>): Promise<unknown> {
	try {
		await promise;
	} catch (error) {
		return error;
	}
	throw new Error("expected promise to reject");
}

Deno.test("rtcChannel writes one DataChannel message per packet", async () => {
	const dc = new FakeDataChannel();
	const channel = rtcChannel(dc as unknown as RTCDataChannel);
	await channel.write(new Uint8Array([1, 2, 3]));
	await channel.write(new Uint8Array([4]));
	assertDeepEquals(dc.sent.map((frame) => [...frame]), [[1, 2, 3], [4]]);
});

Deno.test("rtcChannel bounds concurrent outbound writes", async () => {
	const dc = new FakeDataChannel();
	const channel = rtcChannel(dc as unknown as RTCDataChannel);
	dc.bufferedAmount = WEBRTC_DATA_CHANNEL_QUEUE_BYTES + 1;
	const queued: Promise<void>[] = [];
	for (
		let i = 0;
		i < WEBRTC_DATA_CHANNEL_QUEUE_BYTES / TRANSPORT_WEBRTC_MAX_PACKET_BYTES;
		i += 1
	) {
		queued.push(channel.write(new Uint8Array(TRANSPORT_WEBRTC_MAX_PACKET_BYTES)));
	}
	const error = await rejectionOf(channel.write(new Uint8Array([4])));
	if (!String(error).includes("outbound queue exceeded")) throw error;
	dc.drain();
	await Promise.all(queued);
});

Deno.test("rtcChannel rejects outbound packets over the WebRTC transport cap", async () => {
	const dc = new FakeDataChannel();
	const channel = rtcChannel(dc as unknown as RTCDataChannel);
	const error = await rejectionOf(channel.write(new Uint8Array(TRANSPORT_WEBRTC_MAX_PACKET_BYTES + 1)));
	if (!String(error).includes("transport cap")) throw error;
	assertDeepEquals(dc.sent.length, 0);
});

Deno.test("rtcChannel rejects a write when the channel closes before drain", async () => {
	const dc = new FakeDataChannel();
	const channel = rtcChannel(dc as unknown as RTCDataChannel);
	dc.bufferedAmount = WEBRTC_DATA_CHANNEL_QUEUE_BYTES + 1;
	const written = channel.write(new Uint8Array([1]));
	dc.close();
	const error = await rejectionOf(written);
	if (!String(error).includes("data channel closed")) throw error;
});

Deno.test("rtcChannel reads one DataChannel message per packet", async () => {
	const dc = new FakeDataChannel();
	const channel = rtcChannel(dc as unknown as RTCDataChannel);
	dc.deliver(new Uint8Array([9, 8]).buffer);
	dc.deliver(new Uint8Array([7]).buffer);
	assertDeepEquals([...(await channel.read() ?? new Uint8Array())], [9, 8]);
	assertDeepEquals([...(await channel.read() ?? new Uint8Array())], [7]);
	dc.close();
	assertDeepEquals(await channel.read(), null);
});

Deno.test("rtcChannel rejects non-binary messages", async () => {
	const dc = new FakeDataChannel();
	const channel = rtcChannel(dc as unknown as RTCDataChannel);
	dc.deliver("not bytes");
	const error = await rejectionOf(channel.read());
	if (!String(error).includes("expected binary")) throw error;
});

Deno.test("rtcChannel rejects inbound packets over the WebRTC transport cap", async () => {
	const dc = new FakeDataChannel();
	const channel = rtcChannel(dc as unknown as RTCDataChannel);
	dc.deliver(new Uint8Array(TRANSPORT_WEBRTC_MAX_PACKET_BYTES + 1).buffer);
	const error = await rejectionOf(channel.read());
	if (!String(error).includes("transport cap")) throw error;
});

Deno.test("rtcChannel bounds queued inbound bytes", async () => {
	const dc = new FakeDataChannel();
	const channel = rtcChannel(dc as unknown as RTCDataChannel);
	const accepted = WEBRTC_DATA_CHANNEL_QUEUE_BYTES / TRANSPORT_WEBRTC_MAX_PACKET_BYTES;
	for (let i = 0; i < accepted; i += 1) {
		dc.deliver(new Uint8Array(TRANSPORT_WEBRTC_MAX_PACKET_BYTES).buffer);
	}
	dc.deliver(new Uint8Array([1]).buffer);
	for (let i = 0; i < accepted; i += 1) {
		const packet = await channel.read();
		assertDeepEquals(packet?.byteLength, TRANSPORT_WEBRTC_MAX_PACKET_BYTES);
	}
	const error = await rejectionOf(channel.read());
	if (!String(error).includes("queue overflow")) throw error;
});
