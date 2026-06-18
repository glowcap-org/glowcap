// Idiomatic JavaScript/TypeScript API for `libpancake_net_transport_tcp` —
// pancake's blocking-TCP transport, a composable companion to the core
// `./mod.ts` module (ADR-0059).
//
// The split mirrors the archives: `mod.ts` rides `libpancake_ocapn` (the
// pure-Zig codec-neutral CapTP core) and this module rides
// `libpancake_net_transport_tcp`. The two are symbol-disjoint and share the
// frame/context types by layout, so this loads alongside the core, never
// instead of it. A program that drives a peer over the runtime's own networking
// uses only the core's `connect`/`listen`; this module is the blocking frame shuttle
// the C ABI exposes directly — a `Netlayer` that binds a `Listener` and dials
// an `Endpoint`, each a synchronous `readFrame`/`writeFrame` over a real socket.
//
//   using net = new Netlayer();
//   using listener = net.listen("127.0.0.1", 0);
//   using client = net.connect("127.0.0.1", listener.port());
//   using server = listener.accept();
//   client.writeFrame(frame);
//   const got = server.readFrame();
//
// The TCP family keeps its own thread-local last-error, read through
// `pancake_tcp_last_error`, so a failed call's diagnostic never scrapes the
// core's unrelated `pancake_last_error`.

import { FRAME_SHAPE_BYTE } from "../internal/constants.ts";
import { tcpS } from "../internal/ffi/tcp.ts";
import { ffi, NULL, type Ptr } from "../internal/ffi/runtime.ts";
import {
	type Codec,
	codecId,
	Context,
	outPointer,
	PancakeError,
	readBytes,
	releaseManagedFrame,
} from "../mod.ts";

const OK = 0;

// The calling thread's last error from the TCP transport, or null when there is
// none. The transport keeps its own thread-local slot, so a tcp call's
// diagnostic is read here, never from the core's `pancake_last_error`.
function tcpLastError(): string | null {
	const len = Number(tcpS.pancake_tcp_last_error(null, 0n));
	if (len === 0) return null;
	const buf = new Uint8Array(len + 1);
	const written = Number(tcpS.pancake_tcp_last_error(buf, BigInt(buf.length)));
	return new TextDecoder().decode(
		buf.subarray(0, Math.min(written, buf.length)),
	);
}

// A failed TCP-transport call: read its diagnostic from the transport's own
// thread-local last-error and pass it explicitly, so `PancakeError` never
// scrapes the unrelated core-family `pancake_last_error`.
function checkTcp(code: number): void {
	if (code !== OK) {
		throw new PancakeError(
			code,
			tcpLastError() ?? `tcp transport call failed (code ${code})`,
		);
	}
}

/** A blocking TCP endpoint: the `pancake_tcp_*` frame shuttle. Closed on
 * `close` / `[Symbol.dispose]`. */
export class Endpoint {
	#raw: Ptr;
	constructor(raw: Ptr) {
		this.#raw = raw;
	}
	close(): void {
		if (this.#raw !== NULL) {
			tcpS.pancake_tcp_conn_release(this.#raw);
			this.#raw = NULL;
		}
	}
	[Symbol.dispose](): void {
		this.close();
	}
	/** Block for one whole frame. Throws PANCAKE_ERR_CLOSED on clean EOF. */
	readFrame(): Uint8Array {
		const mf = new Uint8Array(40);
		checkTcp(tcpS.pancake_tcp_conn_read_frame(this.#raw, mf));
		const dv = new DataView(mf.buffer);
		const out = readBytes(dv.getBigUint64(0, true), dv.getBigUint64(8, true))
			.slice();
		releaseManagedFrame(mf);
		return out;
	}
	writeFrame(frame: Uint8Array): void {
		const f = new Uint8Array(24);
		const dv = new DataView(f.buffer);
		dv.setBigUint64(0, ffi.pointerOf(frame), true);
		dv.setBigUint64(8, BigInt(frame.length), true);
		dv.setUint32(16, FRAME_SHAPE_BYTE, true);
		checkTcp(tcpS.pancake_tcp_conn_write_frame(this.#raw, f));
	}
}

/** A bound TCP listener. Closed on `close` / `[Symbol.dispose]`. */
export class Listener {
	#raw: Ptr;
	constructor(raw: Ptr) {
		this.#raw = raw;
	}
	close(): void {
		if (this.#raw !== NULL) {
			tcpS.pancake_tcp_listener_release(this.#raw);
			this.#raw = NULL;
		}
	}
	[Symbol.dispose](): void {
		this.close();
	}
	port(): number {
		const out = new Uint8Array(2);
		checkTcp(tcpS.pancake_tcp_listener_port(this.#raw, out));
		return new DataView(out.buffer).getUint16(0, true);
	}
	accept(codec: Codec = "syrup", maxFrameBytes = 4096): Endpoint {
		const out = new Uint8Array(8);
		checkTcp(
			tcpS.pancake_tcp_accept(
				this.#raw,
				codecId(codec),
				BigInt(maxFrameBytes),
				out,
			),
		);
		return new Endpoint(outPointer(out));
	}
}

/** Owns the blocking-TCP I/O backend; outlives the endpoints made from it. */
export class Netlayer {
	#raw: Ptr;
	constructor(raw?: Ptr) {
		if (raw !== undefined) {
			this.#raw = raw;
			return;
		}
		const out = new Uint8Array(8);
		checkTcp(tcpS.pancake_tcp_netlayer_new(out));
		this.#raw = outPointer(out);
	}

	/** A netlayer whose allocations route through `context`; the context must
	 * outlive it and every endpoint made from it. */
	static newIn(context: Context): Netlayer {
		const out = new Uint8Array(8);
		checkTcp(tcpS.pancake_tcp_netlayer_new_in(context.pointer, out));
		return new Netlayer(outPointer(out));
	}
	release(): void {
		if (this.#raw !== NULL) {
			tcpS.pancake_tcp_netlayer_release(this.#raw);
			this.#raw = NULL;
		}
	}
	[Symbol.dispose](): void {
		this.release();
	}
	listen(host: string, port = 0): Listener {
		const h = new TextEncoder().encode(host);
		const out = new Uint8Array(8);
		checkTcp(
			tcpS.pancake_tcp_listen(this.#raw, h, BigInt(h.length), port, out),
		);
		return new Listener(outPointer(out));
	}
	connect(
		host: string,
		port: number,
		codec: Codec = "syrup",
		maxFrameBytes = 4096,
	): Endpoint {
		const h = new TextEncoder().encode(host);
		const out = new Uint8Array(8);
		checkTcp(
			tcpS.pancake_tcp_connect(
				this.#raw,
				h,
				BigInt(h.length),
				port,
				codecId(codec),
				BigInt(maxFrameBytes),
				out,
			),
		);
		return new Endpoint(outPointer(out));
	}
}
