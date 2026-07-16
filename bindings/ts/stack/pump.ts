// The byte-fed embedder pump choreography the Session drives: read raw bytes
// off the transport, hand them to the core's stream delimiter
// (`pancake_host_session_feed_bytes`, which owns framing), drain the host's
// action queue, and write what `take_outbound` drains. CapTP verbs, hosting,
// and vows stay on `Session`; this module owns the conn byte path
// (handshake, serve loop, feed, flush, feed-refusal, EOF / `break_far_vows`).

import { driverS } from "./internal/ffi/driver.ts";
import { type Ptr } from "./internal/ffi/runtime.ts";
import { ab, readBytes, releaseManagedFrame } from "./internal/seam.ts";
import {
	type AbortDetail,
	abortDomainLabel,
	checkHost,
	hostError,
	PancakeError,
} from "./errors.ts";
import {
	CLOSED,
	LAST_ABORT_DOMAIN_OFF,
	LAST_ABORT_ERROR_NAME_OFF,
	LAST_ABORT_HAS_KIND_OFF,
	LAST_ABORT_KIND_NAME_OFF,
	LAST_ABORT_MESSAGE_OFF,
	LAST_ABORT_SIZE,
	MANAGED_FRAME_BYTES_OFF,
	MANAGED_FRAME_LEN_OFF,
	MANAGED_FRAME_SIZE,
	OK,
	WOULD_BLOCK,
} from "./internal/abi.ts";

const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

/** Live state and callbacks `Session` owns that the pump needs. Session builds
 * one of these from its private fields (getters/setters into `#ptr`, `#inbox`,
 * `#closing`, …) so this module never reaches into private class state. */
export interface PumpHandle {
	readonly ptr: Ptr;
	readonly released: boolean;
	/** True once the keyed handshake completed (`pancake_host_session_session_open`). */
	readonly sessionOpen: boolean;
	/** The Session `#closing` flag alone (not `#released`). */
	closingFlag: boolean;
	/** Teardown has begun: `closingFlag || released`. */
	readonly closing: boolean;
	inbox: Uint8Array;
	writing: Promise<void>;
	read(): Promise<Uint8Array | null>;
	write(data: Uint8Array): Promise<void>;
	drainParkedReleases(): void;
	kickActions(): Promise<void>;
	closeTransport(): void;
}

/** Drive a freshly opened connection's keyed handshake to an open session.
 * The signed `op:start-session` was encoded by the open; its FLUSH is on the
 * action queue, so the first kick puts it on the wire. The core stops
 * consuming at the frame that opens the session, so a fast partner's
 * application frames coalesced behind start-session stay buffered until
 * `serve()` — otherwise a pipelined fetch would answer before the object it
 * names exists. Abandonment on failure stays on Session's establish wrapper. */
export async function runHandshake(h: PumpHandle): Promise<void> {
	await h.kickActions();
	while (!h.sessionOpen) {
		const chunk = await h.read();
		if (chunk === null) {
			throw new PancakeError(
				CLOSED,
				"connection closed during the OCapN handshake",
			);
		}
		await feed(h, chunk);
	}
}

/** Run the inbound loop: read raw bytes, hand them to the core's stream
 * delimiter (behaviors run and vow completions queue inside the feed), and
 * drain the action queue. Resolves when the connection closes cleanly;
 * rejects on a transport or protocol error. */
export async function serveLoop(h: PumpHandle): Promise<void> {
	try {
		// Frames that arrived behind the handshake's tail are still buffered;
		// dispatch them before parking on the wire.
		if (h.inbox.length > 0) await feed(h, new Uint8Array(0));
		while (true) {
			if (h.released) return;
			const chunk = await h.read();
			if (chunk === null) return; // clean EOF
			await feed(h, chunk);
		}
	} catch (err) {
		// A read cancelled by our own close is a clean shutdown; any other
		// failure is a real fault a caller's `serve().catch(...)` should see.
		if (!h.closing) throw err;
	} finally {
		// The wire is gone: pending far vows can never settle, so break them
		// (classified as closure — `closingFlag` is set first), drain the FAIL
		// completions the break queued (same spine as Python/Rust/Racket), then
		// release the conn. Idempotent with an application `close()`.
		if (!h.closing) {
			h.closingFlag = true;
			const msg = utf8Encoder.encode("connection closed");
			try {
				checkHost(driverS.pancake_host_session_break_far_vows(
					h.ptr,
					ab(msg),
					BigInt(msg.length),
				));
				await h.kickActions();
			} catch {
				// teardown is best-effort; release still reclaims the rows
			}
			h.closeTransport();
		}
	}
}

/** Append freshly read bytes onto the inbox and feed the core's stream
 * delimiter: the session's codec splits each complete frame off the front —
 * both codecs, both frame shapes, the frame cap enforced during the scan —
 * and dispatches it (behavior trampolines fire and completions queue
 * inside), then the actions the dispatch queued drain. Only the unconsumed
 * tail stays in the inbox. The input buffer is borrowed for exactly one
 * call; the tail is JS-owned storage. */
export async function feed(h: PumpHandle, chunk: Uint8Array): Promise<void> {
	appendInbox(h, chunk);
	// One call: the core delimits and dispatches every complete frame in
	// the buffer itself, stops at a partial tail, and during the handshake
	// stops at the frame that opens the session.
	if (h.inbox.length === 0 || h.released) return;
	const out = new Uint8Array(8);
	const rc = driverS.pancake_host_session_feed_bytes(
		h.ptr,
		ab(h.inbox),
		BigInt(h.inbox.length),
		ab(out),
	);
	if (rc !== OK) await raiseFeedRefusal(h, rc);
	const consumed = Number(new DataView(out.buffer).getBigUint64(0, true));
	h.inbox = h.inbox.subarray(consumed);
	h.drainParkedReleases();
	await h.kickActions();
}

/** Grow or replace the inbox with freshly read bytes. */
export function appendInbox(h: PumpHandle, bytes: Uint8Array): void {
	if (h.inbox.length === 0) {
		// Copy out of the read buffer so the next read can reuse it.
		h.inbox = bytes.slice();
		return;
	}
	const grown = new Uint8Array(h.inbox.length + bytes.length);
	grown.set(h.inbox, 0);
	grown.set(bytes, h.inbox.length);
	h.inbox = grown;
}

/** The typed cause of this CapTP session's most recent local dispatch failure,
 * or null when none has been recorded. The flat per-feed error code names
 * the failure family; this names the member. */
export function lastAbort(h: PumpHandle): AbortDetail | null {
	if (h.released) return null;
	const buf = new Uint8Array(LAST_ABORT_SIZE);
	const rc = driverS.pancake_host_session_last_abort(h.ptr, ab(buf));
	if (rc === WOULD_BLOCK) return null;
	checkHost(rc);
	const dv = new DataView(buf.buffer);
	const text = (off: number): string =>
		utf8Decoder.decode(
			readBytes(dv.getBigUint64(off, true), dv.getBigUint64(off + 8, true)),
		);
	const domainNum = dv.getUint32(LAST_ABORT_DOMAIN_OFF, true);
	return {
		domain: abortDomainLabel(domainNum),
		kind: dv.getUint32(LAST_ABORT_HAS_KIND_OFF, true) !== 0
			? text(LAST_ABORT_KIND_NAME_OFF)
			: null,
		message: text(LAST_ABORT_MESSAGE_OFF),
		errorName: text(LAST_ABORT_ERROR_NAME_OFF),
	};
}

/** Capture last_error / last_abort before another verb can clobber them,
 * then run the shared action drain so the projected op:abort (and any
 * CLOSE/FAIL queued with it) leave through the same spine as a steady
 * FLUSH — not a private `take_outbound` path. */
export async function raiseFeedRefusal(
	h: PumpHandle,
	rc: number,
): Promise<never> {
	const err = hostError(rc);
	err.abort = lastAbort(h);
	try {
		await h.kickActions();
	} catch {
		// the transport may already be gone; the local typed error stands
	}
	throw err;
}

/** Drain every encoded outbound frame on this CapTP session and write it to
 * the transport — how a FLUSH action lands. Writes are serialized, so
 * frames stay whole and in submission order. */
export async function flushOutbound(h: PumpHandle): Promise<void> {
	const prior = h.writing;
	let release!: () => void;
	h.writing = new Promise<void>((r) => (release = r));
	try {
		await prior;
		while (true) {
			if (h.released) return;
			const mf = new Uint8Array(MANAGED_FRAME_SIZE);
			const rc = driverS.pancake_host_session_take_outbound(h.ptr, ab(mf));
			if (rc === WOULD_BLOCK) return;
			checkHost(rc);
			const dv = new DataView(mf.buffer);
			const frame = readBytes(
				dv.getBigUint64(MANAGED_FRAME_BYTES_OFF, true),
				dv.getBigUint64(MANAGED_FRAME_LEN_OFF, true),
			);
			releaseManagedFrame(mf);
			await h.write(frame);
		}
	} finally {
		release();
	}
}
