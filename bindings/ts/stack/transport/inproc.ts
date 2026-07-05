// Idiomatic JavaScript/TypeScript API for `libpancake_net_transport_inproc` —
// pancake's in-process transport, a composable companion to the core `./mod.ts`
// module (ADR-0059).
//
// This is the socket-free sibling of `./tcp.ts`: two peers in one process wired
// by in-process pipes, no kernel transport and no file descriptors. It rides its
// own archive (`libpancake_net_transport_inproc`), symbol-disjoint from the core
// and from the other transports, sharing the frame/context types by layout. The
// lifecycle matches TCP — make the netlayer, bind a listener or dial a
// connection, release the endpoints, then release the netlayer — but a listener
// binds to a string designator (any opaque token, not a host:port) and a dialer
// names that designator.
//
//   using net = new Netlayer();
//   using listener = net.listen("rooms");
//   using client = net.connect("rooms");
//   using server = listener.accept();
//   client.writeFrame(frame);
//   const got = server.readFrame();
//
// The in-process family keeps its own thread-local last-error, read through
// `pancake_inproc_last_error`, so a failed call's diagnostic never scrapes the
// core's unrelated `pancake_last_error`.

import {
	FRAME_BYTES_OFF,
	FRAME_LEN_OFF,
	FRAME_SHAPE_BYTE,
	FRAME_SHAPE_OFF,
	FRAME_SIZE,
	MANAGED_FRAME_BYTES_OFF,
	MANAGED_FRAME_LEN_OFF,
	MANAGED_FRAME_SIZE,
} from "../internal/constants.ts";
import { inprocS } from "../internal/ffi/inproc.ts";
import { ffi, NULL, type Ptr } from "../internal/ffi/runtime.ts";
import { ab, outPointer, readBytes, releaseManagedFrame } from "../internal/seam.ts";
import { type Codec, codecId, PancakeError } from "../mod.ts";

const OK = 0;

// The calling thread's last error from the in-process transport, or null when
// there is none. The transport keeps its own thread-local slot, so a call's
// diagnostic is read here, never from the core's `pancake_last_error`.
function inprocLastError(): string | null {
	const len = Number(inprocS.pancake_inproc_last_error(null, 0n));
	if (len === 0) return null;
	const buf = new Uint8Array(len + 1);
	const written = Number(
		inprocS.pancake_inproc_last_error(buf, BigInt(buf.length)),
	);
	return new TextDecoder().decode(
		buf.subarray(0, Math.min(written, buf.length)),
	);
}

// A failed in-process-transport call: read its diagnostic from the transport's
// own thread-local last-error and pass it explicitly, so `PancakeError` never
// scrapes the unrelated core-family `pancake_last_error`.
function checkInproc(code: number): void {
	if (code !== OK) {
		throw new PancakeError(
			code,
			inprocLastError() ?? `inproc transport call failed (code ${code})`,
		);
	}
}

/** A blocking in-process endpoint: the `pancake_inproc_*` frame shuttle over a
 * pair of pipes. Closed on `close` / `[Symbol.dispose]`. */
export class Endpoint {
	#raw: Ptr;
	constructor(raw: Ptr) {
		this.#raw = raw;
	}
	close(): void {
		if (this.#raw !== NULL) {
			inprocS.pancake_inproc_conn_release(this.#raw);
			this.#raw = NULL;
		}
	}
	[Symbol.dispose](): void {
		this.close();
	}
	/** Block for one whole frame. Throws PANCAKE_ERR_CLOSED on clean EOF. */
	readFrame(): Uint8Array {
		const mf = new Uint8Array(MANAGED_FRAME_SIZE);
		checkInproc(inprocS.pancake_inproc_conn_read_frame(this.#raw, mf));
		const dv = new DataView(mf.buffer);
		const out = readBytes(
			dv.getBigUint64(MANAGED_FRAME_BYTES_OFF, true),
			dv.getBigUint64(MANAGED_FRAME_LEN_OFF, true),
		).slice();
		releaseManagedFrame(mf);
		return out;
	}
	writeFrame(frame: Uint8Array): void {
		const f = new Uint8Array(FRAME_SIZE);
		const dv = new DataView(f.buffer);
		dv.setBigUint64(FRAME_BYTES_OFF, ffi.pointerOf(frame), true);
		dv.setBigUint64(FRAME_LEN_OFF, BigInt(frame.length), true);
		dv.setUint32(FRAME_SHAPE_OFF, FRAME_SHAPE_BYTE, true);
		checkInproc(inprocS.pancake_inproc_conn_write_frame(this.#raw, f));
	}
}

/** A bound in-process listener on a string designator. Closed on `close` /
 * `[Symbol.dispose]`. */
export class Listener {
	#raw: Ptr;
	constructor(raw: Ptr) {
		this.#raw = raw;
	}
	close(): void {
		if (this.#raw !== NULL) {
			inprocS.pancake_inproc_listener_release(this.#raw);
			this.#raw = NULL;
		}
	}
	[Symbol.dispose](): void {
		this.close();
	}
	/** Block until a dialer connects, returning the in-process connection framing
	 * on `codec`, refusing inbound frames over `maxFrameBytes`. */
	accept(codec: Codec = "syrup", maxFrameBytes = 4096): Endpoint {
		const out = new Uint8Array(8);
		checkInproc(
			inprocS.pancake_inproc_accept(
				this.#raw,
				codecId(codec),
				BigInt(maxFrameBytes),
				out,
			),
		);
		return new Endpoint(outPointer(out));
	}
}

/** Owns the in-process switchboard and its one I/O backend; outlives the
 * endpoints and listeners made from it. */
export class Netlayer {
	#raw: Ptr;
	constructor(raw?: Ptr) {
		if (raw !== undefined) {
			this.#raw = raw;
			return;
		}
		const out = new Uint8Array(8);
		checkInproc(inprocS.pancake_inproc_netlayer_new(out));
		this.#raw = outPointer(out);
	}

	release(): void {
		if (this.#raw !== NULL) {
			inprocS.pancake_inproc_netlayer_release(this.#raw);
			this.#raw = NULL;
		}
	}
	[Symbol.dispose](): void {
		this.release();
	}
	/** Bind a listener on `designator` (any opaque token). */
	listen(designator: string): Listener {
		const d = new TextEncoder().encode(designator);
		const out = new Uint8Array(8);
		checkInproc(
			inprocS.pancake_inproc_listen(this.#raw, ab(d), BigInt(d.length), out),
		);
		return new Listener(outPointer(out));
	}
	/** Dial the listener bound at `designator` and return an in-process
	 * connection framing on `codec`, refusing inbound frames over
	 * `maxFrameBytes`. */
	connect(
		designator: string,
		codec: Codec = "syrup",
		maxFrameBytes = 4096,
	): Endpoint {
		const d = new TextEncoder().encode(designator);
		const out = new Uint8Array(8);
		checkInproc(
			inprocS.pancake_inproc_connect(
				this.#raw,
				ab(d),
				BigInt(d.length),
				codecId(codec),
				BigInt(maxFrameBytes),
				out,
			),
		);
		return new Endpoint(outPointer(out));
	}
}
