// The byte-fed embedder pump choreography the Session drives: read raw bytes
// off the transport, hand them to the core's stream delimiter
// (`pancake_host_session_feed_bytes`, which owns framing), drain the host's
// action queue, and write what `take_outbound` drains. CapTP verbs, hosting,
// and vows stay on `Session`; this module owns the conn byte path
// (handshake, serve loop, feed, flush, feed-refusal, EOF / `break_far_vows`).

import { driverS } from "./internal/ffi/host.ts";
import { type Ptr } from "./internal/ffi/runtime.ts";
import { ab, readBytes, releaseManagedFrame } from "./internal/seam.ts";
import { enterDeliver, exitDeliver } from "./trampoline.ts";
import {
	type AbortDetail,
	abortDomainLabel,
	checkHost,
	hostError,
	PancakeError,
} from "./errors.ts";
import { L } from "./internal/layout.ts";
import { CLOSED, OK, WOULD_BLOCK } from "@pancake/abi";

const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

/** Live state and callbacks `Session` owns that the pump needs. Session builds
 * one of these from its private fields (getters/setters into `#ptr`,
 * `#closing`, …) so this module never reaches into private class state. */
export interface PumpHandle {
	readonly ptr: Ptr;
	readonly released: boolean;
	/** True once the keyed handshake completed (`pancake_host_session_is_open`). */
	readonly sessionOpen: boolean;
	/** Identity of the Session this pump drives, exposed to every hosted
	 * trampoline as the arriving connection for `currentSession()`. */
	readonly deliverOwner: object;
	/** Host identity that owns the Vat entered by this delivery. */
	readonly deliverHost: object;
	/** The Session `#closing` flag alone (not `#released`). */
	closingFlag: boolean;
	/** Teardown has begun: `closingFlag || released`. */
	readonly closing: boolean;
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
		// Frames that rode behind the handshake's tail wait in the session's
		// own tail; an empty feed dispatches them before parking on the wire.
		await feed(h, new Uint8Array(0));
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

/** Feed freshly read bytes to the core's stream delimiter: the session's
 * codec splits each complete frame off the front — both codecs, both frame
 * shapes, the frame cap enforced during the scan — and dispatches it
 * (behavior trampolines fire and completions queue inside), then the actions
 * the dispatch queued drain. The library owns the unconsumed tail — a
 * partial frame straddling two reads stays buffered in the session — so one
 * borrowed call moves the whole chunk; an empty chunk resumes frames the
 * session held behind its handshake open. */
export async function feed(h: PumpHandle, chunk: Uint8Array): Promise<void> {
	if (h.released) return;
	// Behaviors fire synchronously inside this call, so name the arriving Port for
	// the trampoline across it. Saved and restored (not cleared) to mirror the
	// trampoline's currentTurn idiom and stay correct if feed were ever entered
	// re-entrantly; at this sole synchronous entry prev is null, so the restore
	// is equivalent to clearing. A redeem dial's own handshake feed is not
	// nested inside this bracket: the action drain that runs it (kickActions)
	// fires after exitDeliver, as a separate top-level feed.
	const prevDeliver = enterDeliver(h.deliverOwner, h.deliverHost);
	let rc: number;
	try {
		rc = driverS.pancake_host_session_feed_bytes(
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
	if (rc !== OK) await raiseFeedRefusal(h, rc);
	await h.kickActions();
}

/** The typed cause of this CapTP session's most recent local dispatch failure,
 * or null when none has been recorded. The flat per-feed error code names
 * the failure family; this names the member. */
export function lastAbort(h: PumpHandle): AbortDetail | null {
	if (h.released) return null;
	const buf = new Uint8Array(L.LAST_ABORT_SIZE);
	const rc = driverS.pancake_host_session_last_abort(h.ptr, ab(buf));
	if (rc === WOULD_BLOCK) return null;
	checkHost(rc);
	const dv = new DataView(buf.buffer);
	const text = (off: number, lenOff: number): string =>
		utf8Decoder.decode(
			readBytes(L.getPtr(dv, off), L.getUsize(dv, lenOff)),
		);
	const domainNum = dv.getUint32(L.LAST_ABORT_DOMAIN_OFF, true);
	return {
		domain: abortDomainLabel(domainNum),
		kind: dv.getUint32(L.LAST_ABORT_HAS_KIND_OFF, true) !== 0
			? text(L.LAST_ABORT_KIND_NAME_OFF, L.LAST_ABORT_KIND_NAME_LEN_OFF)
			: null,
		message: text(L.LAST_ABORT_MESSAGE_OFF, L.LAST_ABORT_MESSAGE_LEN_OFF),
		errorName: text(L.LAST_ABORT_ERROR_NAME_OFF, L.LAST_ABORT_ERROR_NAME_LEN_OFF),
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
			const mf = new Uint8Array(L.MANAGED_FRAME_SIZE);
			const rc = driverS.pancake_host_session_take_outbound(h.ptr, ab(mf));
			if (rc === WOULD_BLOCK) return;
			checkHost(rc);
			const dv = new DataView(mf.buffer);
			const frame = readBytes(
				L.getPtr(dv, L.MANAGED_FRAME_BYTES_OFF),
				L.getUsize(dv, L.MANAGED_FRAME_LEN_OFF),
			);
			releaseManagedFrame(mf);
			await h.write(frame);
		}
	} finally {
		release();
	}
}
