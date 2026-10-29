// The embedder pump choreography the Session drives: read transport packets,
// hand them to the core's transport-packet seam, drain the host's action queue,
// and write what `take_packet` drains. CapTP verbs, hosting, and vows stay
// on `Session`; this module owns only handshake, serve, feed-refusal, flush,
// EOF, and `transport_closed` choreography.
//
// Reading and writing are separate tasks: the session's writer
// (`session/writer.ts`) performs every write. The core bounds each session's
// outbound queue and refuses input past its high-water mark, so the reader
// needs no second bound of its own.

import { hostS } from "./internal/ffi/host.ts";
import type { Ptr } from "./internal/ffi/runtime.ts";
import { ab, outUsize, readBytes, releaseManagedFrame } from "./internal/seam.ts";
import { enterDeliver, exitDeliver, type TurnHostOwner } from "./trampoline.ts";
import { type AbortDetail, abortDomainLabel, checkHost, GlowcapError, hostError } from "./errors.ts";
import { L } from "./internal/layout.ts";
import { CLOSED, OK, TIMEOUT, WOULD_BLOCK } from "@glowcap/abi";

const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

/** Live state and callbacks `Session` owns that the pump needs. Session builds
 * one of these from its private fields (getters/setters into `#ptr`,
 * `#closing`, …) so this module never reaches into private class state. */
export interface PumpHandle {
	readonly ptr: Ptr;
	readonly released: boolean;
	/** True once the keyed handshake completed (`glowcap_host_session_is_open`). */
	readonly sessionOpen: boolean;
	/** Host identity that owns the Vat entered by this delivery. */
	readonly deliverHost: TurnHostOwner;
	/** The Session `#closing` flag alone (not `#released`). */
	closingFlag: boolean;
	/** Teardown has begun: `closingFlag || released`. */
	readonly closing: boolean;
	/** Exact first byte-channel failure retained by the owning Session. */
	readonly wireFailure: { readonly error: unknown } | null;
	/** Record that inbound/protocol teardown already owns the terminal state. */
	markTransportLost(): void;
	/** Retain an exact terminal failure discovered by this pump. */
	recordWireFailure(error: unknown): void;
	/** Retain an outbound failure before retiring the damaged stream. */
	recordOutboundFailure(error: unknown): void;
	/** The core delivered CLOSE, and the writer owns the transport close. */
	readonly closeDelivered: boolean;
	/** Wake the writer; returns the pass that takes every frame queued so far. */
	requestFlush(): number;
	/** Wait until that pass has finished. */
	written(covering: number): Promise<void>;
	/** Resolves once the session's writer has exited. */
	readonly writerExited: Promise<void>;
	/** Session-owned metadata reused by the writer's one drain at a time. */
	readonly outboundScratch: {
		readonly managedFrame: Uint8Array;
		readonly prefix: Uint8Array;
		readonly prefixLen: Uint8Array;
	};
	read(): Promise<Uint8Array | null>;
	write(data: Uint8Array): Promise<void>;
	drainParkedReleases(): void;
	kickActions(): Promise<void>;
	/** Teardown barrier: drain current effects and join all admitted drains. */
	settleActions(): Promise<void>;
	/** Wake any parked close driver after an FFI verb that can advance
	 * close-relevant state returns (`Host.signalCloseActivity`). */
	signalCloseActivity(): void;
	closeTransport(): void | Promise<void>;
}

/** Drive a freshly opened connection's keyed handshake to an open session.
 * The signed `op:start-session` was encoded by the open; its FLUSH is on the
 * action queue, so the first kick puts it on the wire. The core stops
 * consuming at the frame that opens the session, so a fast partner's
 * application frames coalesced behind start-session stay buffered until the
 * Host-owned resume step. Otherwise a pipelined fetch would answer before
 * the object it names exists. Abandonment on failure stays on Session's
 * establish wrapper. */
async function driveHandshake(h: PumpHandle): Promise<void> {
	await h.kickActions();
	while (!h.sessionOpen) {
		const chunk = await h.read();
		if (chunk === null) {
			throw new GlowcapError(
				CLOSED,
				"connection closed during the OCapN handshake",
			);
		}
		await feed(h, chunk);
	}
}

/** Drive the handshake under its caller-selected anti-hang budget. */
export function runHandshake(h: PumpHandle, timeoutMs: number | null): Promise<void> {
	const handshake = driveHandshake(h);
	if (!timeoutMs) return handshake;
	let timer: ReturnType<typeof setTimeout> | undefined;
	const bound = new Promise<never>((_resolve, reject) => {
		timer = setTimeout(
			() =>
				reject(
					new GlowcapError(
						TIMEOUT,
						`the partner did not finish the OCapN handshake within ${timeoutMs}ms`,
					),
				),
			timeoutMs,
		);
	});
	return Promise.race([handshake, bound]).finally(() => clearTimeout(timer));
}

/** Run the inbound loop: read transport packets, hand them to the Host
 * transport-packet seam (behaviors run and vow completions queue inside the
 * feed), and drain the action queue. Resolves when the connection closes
 * cleanly; rejects on a transport or protocol error. */
export async function serveLoop(h: PumpHandle): Promise<void> {
	let failed = false;
	let failure: unknown;
	try {
		await resumeFeed(h);
		while (true) {
			if (h.released || h.closeDelivered) break;
			const chunk = await h.read();
			// Leave the read loop, then run the shared transport-closed and
			// release choreography below. Returning here would resolve serve()
			// while the Host still indexed a dead session.
			if (chunk === null) {
				h.markTransportLost();
				break; // clean EOF
			}
			if (h.closeDelivered) break;
			await feed(h, chunk);
		}
	} catch (err) {
		// A read cancelled by our own close, or one that fails after the core
		// ended the session, is a clean shutdown; any other failure is a real
		// fault a caller's `serve().catch(...)` should see.
		if (h.closeDelivered) {
			h.markTransportLost();
		} else if (!h.closing) {
			h.markTransportLost();
			h.recordWireFailure(err);
			failed = true;
			failure = err;
		}
	}

	// Preserve a feed/read failure as primary. On a clean EOF, failure to tell
	// the core that the wire disappeared is itself the serve failure; it must
	// not look like a successful end of stream. An application-driven close
	// already has its own result path, so its redundant report remains cleanup.
	// A delivered CLOSE already retired the session, and its writer owns the
	// transport close, so serve() resolves once that writer has released it.
	if (h.closeDelivered) {
		await h.writerExited;
	} else if (!h.released) {
		const wasClosing = h.closing;
		h.closingFlag = true;
		const msg = utf8Encoder.encode("connection closed");
		try {
			checkHost(hostS.glowcap_host_session_transport_closed(
				h.ptr,
				ab(msg),
				BigInt(msg.length),
			));
			// The physical loss retires close-relevant session state; wake
			// any parked close driver.
			h.signalCloseActivity();
			await h.settleActions();
			await h.closeTransport();
		} catch (err) {
			if (!failed && !wasClosing) {
				h.recordWireFailure(err);
				failed = true;
				failure = err;
			}
		}
	}

	if (failed) throw failure;
	if (h.wireFailure !== null) throw h.wireFailure.error;
}

/** Feed freshly read transport packets to the core. The Host session decides
 * from transport metadata whether a packet is a byte-stream chunk or one bare
 * frame; the binding never branches on concrete transport names. */
export async function feed(h: PumpHandle, chunk: Uint8Array): Promise<void> {
	while (true) {
		if (h.released) return;
		// Behaviors fire synchronously inside this call, so name the arriving Port for
		// the trampoline across it. Saved and restored (not cleared) to mirror the
		// trampoline's currentTurn idiom and stay correct if feed were ever entered
		// re-entrantly; at this sole synchronous entry prev is null, so the restore
		// is equivalent to clearing. A redeem dial's own handshake feed is not
		// nested inside this bracket: the action drain that runs it (kickActions)
		// fires after exitDeliver, as a separate top-level feed.
		const prevDeliver = enterDeliver(h.deliverHost);
		let rc: number;
		try {
			rc = hostS.glowcap_host_session_feed_packet(
				h.ptr,
				ab(chunk),
				BigInt(chunk.length),
			);
		} finally {
			exitDeliver(prevDeliver);
		}
		// Parked releases drain before the refusal check, matching the Python
		// and Rust pumps, so a mid-feed close's C release never waits behind a
		// refused feed's raise.
		h.drainParkedReleases();
		// The feed dispatched frames and may have advanced close-relevant state
		// even when it queued no action; wake any parked close driver.
		h.signalCloseActivity();
		if (rc === OK) break;
		if (rc === WOULD_BLOCK) {
			await awaitOutboundRoom(h);
			continue;
		}
		await raiseFeedRefusal(h, rc);
	}
	await h.kickActions();
}

/** The core refused input until its outbound queue drains below the
 * high-water mark. Drain queued work into frames, then wait for the writer to
 * take them before the caller feeds again. */
async function awaitOutboundRoom(h: PumpHandle): Promise<void> {
	await h.kickActions();
	await h.written(h.requestFlush());
}

/** Resume input the Host retained during a prior feed. Byte-stream sessions
 * may dispatch a held tail; message-framed sessions have no hidden tail. */
async function resumeFeed(h: PumpHandle): Promise<void> {
	while (true) {
		if (h.released) return;
		const prevDeliver = enterDeliver(h.deliverHost);
		let rc: number;
		try {
			rc = hostS.glowcap_host_session_resume_feed(h.ptr);
		} finally {
			exitDeliver(prevDeliver);
		}
		h.drainParkedReleases();
		h.signalCloseActivity();
		if (rc === OK) break;
		if (rc === WOULD_BLOCK) {
			await awaitOutboundRoom(h);
			continue;
		}
		await raiseFeedRefusal(h, rc);
	}
	await h.kickActions();
}

/** The typed cause of this CapTP session's most recent local dispatch failure,
 * or null when none has been recorded. The flat per-feed error code names
 * the failure family; this names the member. */
export function lastAbort(h: PumpHandle): AbortDetail | null {
	if (h.released) return null;
	const buf = new Uint8Array(L.LAST_ABORT_SIZE);
	const rc = hostS.glowcap_host_session_last_abort(h.ptr, ab(buf));
	if (rc === WOULD_BLOCK) return null;
	checkHost(rc);
	const dv = new DataView(buf.buffer);
	const text = (off: number, lenOff: number): string =>
		utf8Decoder.decode(
			readBytes(L.getPtr(dv, off), L.getUsize(dv, lenOff)),
		);
	const domainNum = dv.getUint32(L.LAST_ABORT_DOMAIN_OFF, true);
	const deliveryErrorLen = L.getUsize(dv, L.LAST_ABORT_ABORT_DELIVERY_ERROR_NAME_LEN_OFF);
	const secondaryErrorLen = L.getUsize(dv, L.LAST_ABORT_SECONDARY_ERROR_NAME_LEN_OFF);
	return {
		domain: abortDomainLabel(domainNum),
		kind: dv.getUint32(L.LAST_ABORT_HAS_KIND_OFF, true) !== 0
			? text(L.LAST_ABORT_KIND_NAME_OFF, L.LAST_ABORT_KIND_NAME_LEN_OFF)
			: null,
		message: text(L.LAST_ABORT_MESSAGE_OFF, L.LAST_ABORT_MESSAGE_LEN_OFF),
		errorName: text(L.LAST_ABORT_ERROR_NAME_OFF, L.LAST_ABORT_ERROR_NAME_LEN_OFF),
		abortDeliveryErrorName: deliveryErrorLen === 0n
			? null
			: text(L.LAST_ABORT_ABORT_DELIVERY_ERROR_NAME_OFF, L.LAST_ABORT_ABORT_DELIVERY_ERROR_NAME_LEN_OFF),
		secondaryErrorName: secondaryErrorLen === 0n
			? null
			: text(L.LAST_ABORT_SECONDARY_ERROR_NAME_OFF, L.LAST_ABORT_SECONDARY_ERROR_NAME_LEN_OFF),
		secondaryErrorCount: dv.getUint32(L.LAST_ABORT_SECONDARY_ERROR_COUNT_OFF, true),
	};
}

/** Capture last_error / last_abort before another verb can clobber them,
 * then run the shared action drain so the projected op:abort (and any
 * CLOSE/FAIL queued with it) leave through the same spine as a steady
 * FLUSH, not a private `take_outbound` path. The serve loop reports the
 * transport closed next, so the abort must be written first. */
export async function raiseFeedRefusal(
	h: PumpHandle,
	rc: number,
): Promise<never> {
	const err = hostError(rc);
	err.abort = lastAbort(h);
	try {
		await h.kickActions();
		await h.written(h.requestFlush());
	} catch (drainFailure) {
		// The local typed refusal remains primary, but projecting its abort and
		// terminal effects is part of the same failed operation. Retain that
		// secondary cause instead of making the diagnostic disappear.
		err.cause = drainFailure;
	}
	throw err;
}

/** Drain every transport-ready packet on this CapTP session and write its
 * prefix/body pair in order, resolving whether any frame left the core. Only
 * the session's writer calls this, so one drain runs at a time. Byte-stream
 * sessions receive an outer-frame prefix; message-framed sessions receive an
 * empty prefix. */
export async function flushOutbound(h: PumpHandle): Promise<boolean> {
	let wrote = false;
	try {
		const { managedFrame: mf, prefix, prefixLen } = h.outboundScratch;
		while (true) {
			if (h.released) return wrote;
			const rc = hostS.glowcap_host_session_take_packet(
				h.ptr,
				ab(mf),
				ab(prefix),
				BigInt(prefix.length),
				ab(prefixLen),
			);
			if (rc === WOULD_BLOCK) return wrote;
			checkHost(rc);
			let frame: Uint8Array;
			try {
				const dv = new DataView(mf.buffer);
				frame = readBytes(
					L.getPtr(dv, L.MANAGED_FRAME_BYTES_OFF),
					L.getUsize(dv, L.MANAGED_FRAME_LEN_OFF),
				);
			} finally {
				releaseManagedFrame(mf);
			}
			wrote = true;
			const prefixBytes = prefix.subarray(0, Number(outUsize(prefixLen)));
			if (prefixBytes.length > 0) await h.write(prefixBytes);
			await h.write(frame);
		}
	} catch (err) {
		// The transferred frame cannot be replayed, and cancellation may
		// have left a prefix on the stream. End this session and settle vows.
		h.recordOutboundFailure(err);
		h.closeTransport();
		throw err;
	}
}
