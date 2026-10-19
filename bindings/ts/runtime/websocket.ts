// One WebSocket adapted to the byte-`Channel` seam, shared by every place that
// carries glowcap bytes over a WebSocket: the browser adapter's dial, both
// halves of the keyed-relay rendezvous (ADR-0034), and `@glowcap/relay`. The
// `WebSocket` global is a web standard every supported runtime ships (browser,
// Deno, Bun), so this is runtime-neutral code, not a per-runtime adapter
// seam. Each caller differs only in how it gets the socket: opening it, or
// being handed an accepted one; the byte plumbing is this one module.

import type { Channel } from "./session.ts";
import type { Timer } from "./timer.ts";
import { recordProcessBindingFailure } from "./context.ts";
import { retainSecondaryFailure } from "./errors.ts";
import { cancellationError } from "./internal/cancellation.ts";
import {
	BINDING_WEBSOCKET_CLOSE_TIMEOUT_MS,
	BINDING_WEBSOCKET_DRAIN_POLL_MS,
	BINDING_WEBSOCKET_INBOUND_HIGH_WATER_BYTES,
	BINDING_WEBSOCKET_SEND_HIGH_WATER_BYTES,
} from "@glowcap/abi";

// A `WebSocket` has no drain event, so `write` gates outbound flow by polling
// `bufferedAmount` down below this high-water before it resolves: a producer
// outrunning its partner stops being read from until its send buffer drains,
// which closes the far side's flow-control window instead of growing tab memory.
const wsSendHighWaterBytes = BINDING_WEBSOCKET_SEND_HIGH_WATER_BYTES;
const wsDrainPollMs = BINDING_WEBSOCKET_DRAIN_POLL_MS;
const defaultWsCloseTimeoutMs = BINDING_WEBSOCKET_CLOSE_TIMEOUT_MS;
// A WebSocket message is a transport chunk, not a CapTP frame: it may contain
// several canonical outer frames. Keep this budget independent from the frame
// cap so transport coalescing stays byte-transparent.
const defaultWsInboundHighWaterBytes = BINDING_WEBSOCKET_INBOUND_HIGH_WATER_BYTES;

export interface WebSocketChannelOptions {
	/** Maximum bytes retained while the consumer is behind. Browser WebSockets
	 * cannot be paused, so overflow closes with 1009. This is a transport-message
	 * budget, independent from the CapTP frame cap. */
	inboundHighWaterBytes?: number;
	/** Maximum time to wait for the browser's close event after requesting a
	 * close. The WebSocket API has no force-close primitive, so expiry rejects
	 * the barrier instead of parking Host retirement forever. */
	closeTimeoutMs?: number;
}

export interface WebSocketByteChannel extends Channel {
	/** Request a close and join the browser's close event. Every caller receives
	 * the same barrier; an abnormal close or synchronous refusal rejects it. */
	close(code?: number, reason?: string): Promise<void>;
	cancel(): Promise<void>;
}

function inboundHighWaterBytes(options?: WebSocketChannelOptions): number {
	const value = options?.inboundHighWaterBytes;
	if (value == null) return defaultWsInboundHighWaterBytes;
	if (!Number.isSafeInteger(value) || value <= 0) {
		throw new TypeError("WebSocket inbound high-water must be a positive safe integer");
	}
	return value;
}

function closeTimeoutMs(options?: WebSocketChannelOptions): number {
	const value = options?.closeTimeoutMs;
	if (value == null) return defaultWsCloseTimeoutMs;
	if (!Number.isSafeInteger(value) || value <= 0) {
		throw new TypeError("WebSocket close timeout must be a positive safe integer");
	}
	return value;
}

function waitForSocketEvent(
	ws: WebSocket,
	ms: number,
): Promise<void> {
	return new Promise<void>((resolve, reject) => {
		let done = false;
		const settle = (fn: () => void) => {
			if (done) return;
			done = true;
			clearTimeout(timer);
			ws.removeEventListener("close", onClose);
			ws.removeEventListener("error", onError);
			fn();
		};
		const onClose = () => settle(() => reject(new Error("WebSocket closed")));
		const onError = () => settle(() => reject(new Error("WebSocket error")));
		const timer: Timer = setTimeout(() => settle(resolve), ms);
		ws.addEventListener("close", onClose, { once: true });
		ws.addEventListener("error", onError, { once: true });
	});
}

async function waitForBufferedLow(ws: WebSocket): Promise<void> {
	while (ws.bufferedAmount > wsSendHighWaterBytes) {
		if (ws.readyState != WebSocket.OPEN) throw new Error("WebSocket closed");
		await waitForSocketEvent(ws, wsDrainPollMs);
	}
	if (ws.readyState != WebSocket.OPEN) throw new Error("WebSocket closed");
}

function waitForOpen(ws: WebSocket): Promise<void> {
	return new Promise<void>((resolve, reject) => {
		let done = false;
		const settle = (fn: () => void) => {
			if (done) return;
			done = true;
			ws.removeEventListener("open", onOpen);
			ws.removeEventListener("close", onClose);
			ws.removeEventListener("error", onError);
			fn();
		};
		const onOpen = () => settle(resolve);
		const onClose = () => settle(() => reject(new Error("WebSocket closed")));
		const onError = () => settle(() => reject(new Error("WebSocket error")));
		ws.addEventListener("open", onOpen, { once: true });
		ws.addEventListener("close", onClose, { once: true });
		ws.addEventListener("error", onError, { once: true });
		// The state may have changed between the caller's CONNECTING check and
		// listener installation. Reconcile it after subscribing so neither edge can
		// strand a writer waiting for an event that already happened.
		if (ws.readyState === WebSocket.OPEN) onOpen();
		else if (ws.readyState === WebSocket.CLOSING || ws.readyState === WebSocket.CLOSED) {
			onClose();
		}
	});
}

/** Adapt `ws` (already open, or opening: messages cannot arrive before the
 * open event) to a `Channel`. Inbound frames flow through a `ReadableStream`
 * reader; a close or error ends the stream. Outbound `write` resolves once the
 * socket's send buffer is at or below the high-water, so a fast producer is
 * backpressured rather than growing tab memory unbounded. Since browser
 * WebSockets cannot be paused, inbound messages are admitted only while this
 * adapter's own byte budget has room. */
export function webSocketChannel(
	ws: WebSocket,
	options?: WebSocketChannelOptions,
): WebSocketByteChannel {
	ws.binaryType = "arraybuffer";
	const inboundLimit = inboundHighWaterBytes(options);
	const closeLimitMs = closeTimeoutMs(options);
	let queuedBytes = 0;
	let closeRequested = false;
	let closeSettled = false;
	let closeFailure: { readonly error: unknown } | null = null;
	let resolveClose!: () => void;
	let rejectClose!: (error: unknown) => void;
	let closeTimer: Timer | null = null;
	const closeBarrier = new Promise<void>((resolve, reject) => {
		resolveClose = resolve;
		rejectClose = reject;
	});
	// An unsolicited transport failure can precede the Session's retirement
	// call. Mark this exact promise handled without replacing it; close() still
	// returns it to the lifecycle owner for authoritative observation.
	void closeBarrier.catch(() => {});
	const retainCloseFailure = (error: unknown): void => {
		if (closeSettled) {
			recordProcessBindingFailure("websocket.close.late-settlement", error);
			return;
		}
		closeFailure = closeFailure == null ? { error } : { error: retainSecondaryFailure(closeFailure.error, error) };
	};
	const finishClose = (): void => {
		if (closeSettled) return;
		closeSettled = true;
		if (closeTimer !== null) clearTimeout(closeTimer);
		if (closeFailure == null) resolveClose();
		else rejectClose(closeFailure.error);
	};
	const abnormalClose = (event: CloseEvent): Error => {
		const suffix = event.reason.length === 0 ? "" : `: ${event.reason}`;
		return new Error(`WebSocket closed abnormally (code ${event.code})${suffix}`);
	};
	const requestClose = (code?: number, reason?: string): Promise<void> => {
		if (closeRequested) return closeBarrier;
		if (ws.readyState === WebSocket.CLOSED) {
			if (!closeSettled) finishClose();
			return closeBarrier;
		}
		closeRequested = true;
		try {
			ws.close(code, reason);
		} catch (error) {
			retainCloseFailure(error);
			finishClose();
		}
		if (!closeSettled) {
			closeTimer = setTimeout(() => {
				retainCloseFailure(new Error(`WebSocket close timed out after ${closeLimitMs}ms`));
				finishClose();
			}, closeLimitMs);
		}
		return closeBarrier;
	};
	// `Channel.write` is public and may be called concurrently. Keep one send
	// authority so several callers cannot all cross the browser buffer's
	// high-water before any one observes pressure. The retained call backlog
	// uses the same one-producer-may-cross waterline as the browser send buffer.
	let writing: Promise<void> = Promise.resolve();
	let pendingWriteBytes = 0;
	const reader = new ReadableStream<Uint8Array>({
		start(controller) {
			ws.onmessage = (event: MessageEvent) => {
				try {
					if (!(event.data instanceof ArrayBuffer)) {
						controller.error(new Error("WebSocket text messages are not CapTP bytes"));
						void requestClose(1003, "binary messages required");
						return;
					}
					const chunk = new Uint8Array(event.data);
					if (queuedBytes + chunk.byteLength > inboundLimit) {
						controller.error(new Error("WebSocket inbound queue exceeded"));
						void requestClose(1009, "inbound queue exceeded");
						return;
					}
					queuedBytes += chunk.byteLength;
					controller.enqueue(chunk);
				} catch { /* stream already closed */ }
			};
			ws.onclose = (event: CloseEvent) => {
				const failure = event.wasClean === false ? abnormalClose(event) : null;
				if (failure != null) retainCloseFailure(failure);
				finishClose();
				try {
					if (failure == null) controller.close();
					else controller.error(failure);
				} catch { /* already closed */ }
			};
			ws.onerror = () => {
				const failure = new Error("WebSocket error");
				retainCloseFailure(failure);
				try {
					controller.error(failure);
				} catch { /* already closed */ }
				void requestClose();
			};
			// Adoption normally follows OPEN. Refuse a socket that closed between
			// the caller's check and handler installation instead of returning a
			// barrier whose close event can no longer arrive.
			if (ws.readyState === WebSocket.CLOSED) {
				const failure = new Error("WebSocket closed before channel adoption");
				retainCloseFailure(failure);
				finishClose();
				try {
					controller.error(failure);
				} catch { /* already closed */ }
			}
		},
	}).getReader();
	return {
		async read(): Promise<Uint8Array | null> {
			// A clean close arrives as `done` via `controller.close()` (onclose); a
			// transport error arrives as a rejection via `controller.error()`
			// (onerror). Let the rejection propagate (the FFI adapters do), and
			// `Session.serve` promises to reject on a transport error. Swallowing it
			// into an EOF here would make a dropped socket look like a graceful close.
			const { value, done } = await reader.read();
			if (done || value == null) return null;
			queuedBytes -= value.byteLength;
			return value;
		},
		write(data: Uint8Array): Promise<void> {
			// The promise chain is itself retained memory. Let one producer cross
			// the waterline, then refuse another until queued writes drain. The
			// Session pump serializes writes and never reaches this refusal; it
			// protects direct concurrent Channel callers from building an
			// unbounded closure-and-buffer backlog.
			if (pendingWriteBytes >= wsSendHighWaterBytes) {
				return Promise.reject(new Error("WebSocket outbound queue exceeded"));
			}
			pendingWriteBytes += data.byteLength;
			const current = writing.then(async () => {
				if (ws.readyState === WebSocket.CONNECTING) await waitForOpen(ws);
				if (ws.readyState != WebSocket.OPEN) throw new Error("WebSocket closed");
				if (data.byteLength === 0) {
					ws.send(data as Uint8Array<ArrayBuffer>);
					await waitForBufferedLow(ws);
					return;
				}
				for (let offset = 0; offset < data.byteLength; offset += wsSendHighWaterBytes) {
					const chunk = data.subarray(offset, offset + wsSendHighWaterBytes);
					ws.send(chunk as Uint8Array<ArrayBuffer>);
					await waitForBufferedLow(ws);
				}
			}).finally(() => {
				pendingWriteBytes -= data.byteLength;
			});
			writing = current;
			return current;
		},
		close: requestClose,
		cancel: () => reader.cancel(),
	};
}

/** Open a WebSocket to `url` and adapt it to the byte-`Channel` seam once the
 * socket is open. A failure before the open rejects here; after it, an error
 * or close surfaces through the channel's `read`, which the session's teardown
 * classifies. */
export function openWebSocketChannel(
	url: string,
	options?: WebSocketChannelOptions,
	signal?: AbortSignal,
): Promise<WebSocketByteChannel> {
	return new Promise((resolve, reject) => {
		// Reject configuration before opening a network resource. Pass the checked
		// value onward so construction and the established channel share one fact.
		const checkedInboundHighWaterBytes = inboundHighWaterBytes(options);
		const checkedCloseTimeoutMs = closeTimeoutMs(options);
		if (signal?.aborted) {
			reject(cancellationError(signal));
			return;
		}
		const ws = new WebSocket(url);
		let done = false;
		let cancelFailure: unknown = null;
		let cancelTimer: Timer | null = null;
		const settle = (fn: () => void) => {
			if (done) return;
			done = true;
			if (cancelTimer != null) clearTimeout(cancelTimer);
			signal?.removeEventListener("abort", cancelOpen);
			ws.onerror = null;
			ws.onclose = null;
			ws.onopen = null;
			fn();
		};
		const finishCancellation = (secondary?: unknown): void => {
			if (secondary !== undefined) retainSecondaryFailure(cancelFailure, secondary);
			settle(() => reject(cancelFailure));
		};
		const cancelOpen = (): void => {
			if (done || cancelFailure != null || signal == null) return;
			cancelFailure = cancellationError(signal);
			ws.onopen = null;
			try {
				ws.close();
			} catch (error) {
				finishCancellation(error);
				return;
			}
			if (done) return;
			if (ws.readyState === WebSocket.CLOSED) {
				finishCancellation();
				return;
			}
			cancelTimer = setTimeout(
				() => finishCancellation(new Error(`WebSocket close timed out after ${checkedCloseTimeoutMs}ms`)),
				checkedCloseTimeoutMs,
			);
		};
		// A pre-open error rejects the connect. Once open, `webSocketChannel`
		// re-wires the handlers for the byte lifecycle.
		ws.onerror = () => {
			const failure = new Error(`WebSocket connect failed: ${url}`);
			if (cancelFailure != null) retainSecondaryFailure(cancelFailure, failure);
			else settle(() => reject(failure));
		};
		ws.onclose = (event: CloseEvent) => {
			if (cancelFailure != null) {
				const secondary = event.wasClean === false
					? new Error(`WebSocket closed abnormally during cancellation (code ${event.code})`)
					: undefined;
				finishCancellation(secondary);
			} else settle(() => reject(new Error(`WebSocket closed before open: ${url}`)));
		};
		ws.onopen = () =>
			settle(() =>
				resolve(webSocketChannel(ws, {
					inboundHighWaterBytes: checkedInboundHighWaterBytes,
					closeTimeoutMs: checkedCloseTimeoutMs,
				}))
			);
		signal?.addEventListener("abort", cancelOpen, { once: true });
	});
}
