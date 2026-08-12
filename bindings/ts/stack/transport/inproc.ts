// Idiomatic JavaScript/TypeScript API for `libpancake_net_transport_inproc` —
// pancake's in-process transport, a composable companion to the core `./mod.ts`
// module (ADR-0059).
//
// This is the socket-free sibling of `./tcp.ts`: two peers in one process wired
// by in-process pipes and no kernel transport. The C listener adds a wake
// descriptor for reactor integration; no application bytes flow through it. It rides its
// own archive (`libpancake_net_transport_inproc`), symbol-disjoint from the core
// and from the other transports, sharing the frame/context types by layout. The
// lifecycle matches TCP — make the netlayer, bind a listener or dial a
// connection, release the connections, then release the netlayer — but a listener
// binds to a string designator (any opaque token, not a host:port) and a dialer
// names that designator.
//
//   using net = new Netlayer();
//   using listener = net.listen("rooms");
//   using client = await net.connect("rooms");
//   using server = await listener.accept();
//   await client.writeFrame(frame);
//   const got = await server.readFrame();
//
// The in-process family keeps its own thread-local last-error, read through
// `pancake_inproc_last_error`, so a failed call's diagnostic never scrapes the
// core's unrelated `pancake_last_error`.

import {
	MANAGED_FRAME_BYTES_OFF,
	MANAGED_FRAME_LEN_OFF,
	MANAGED_FRAME_SIZE,
} from "../internal/constants.ts";
import { inprocS } from "../internal/ffi/inproc.ts";
import { type Ptr } from "../internal/ffi/runtime.ts";
import { outPointer, readBytes, readErrorSlot, releaseManagedFrame } from "../internal/seam.ts";
import { type Codec, codecId } from "../value.ts";
import { PancakeError } from "../errors.ts";
import { NativeHandle, NativeParent, requireOffThreadFfi, SingleFlight } from "./native_handle.ts";
import { AsyncFfiWriteQueue, checkedMaxFrameBytes } from "./native_frame.ts";
import { checkDiagnosedCall, NativeDiagnostic } from "./diagnostic.ts";

const OK = 0;

// The calling thread's last error from the in-process transport, or null when
// there is none. The transport keeps its own thread-local slot, so a call's
// diagnostic is read here, never from the core's `pancake_last_error`.
function inprocLastError(): string | null {
	return readErrorSlot(inprocS.pancake_inproc_last_error);
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

/** An in-process connection whose potentially blocking operations run off-thread. */
export class Connection {
	readonly #native: NativeHandle;
	readonly #parent: NativeParent<Connection | Listener>;
	readonly #reads = new SingleFlight("inproc read");
	readonly #writes: AsyncFfiWriteQueue;
	readonly #readDiagnostic = new NativeDiagnostic("inproc");
	readonly #writeDiagnostic = new NativeDiagnostic("inproc");
	constructor(raw: Ptr, parent: NativeParent<Connection | Listener>, maxFrameBytes: number) {
		this.#parent = parent;
		this.#writes = new AsyncFfiWriteQueue("inproc", maxFrameBytes);
		this.#native = new NativeHandle(
			"inproc connection",
			raw,
			(p) => inprocS.pancake_inproc_conn_shutdown(p),
			(p) => inprocS.pancake_inproc_conn_release(p),
			(retirement) => this.#parent.retire(this, retirement),
		);
		if (!parent.adopt(this)) throw new Error("inproc netlayer is released");
	}
	close(): void {
		this.#native.close();
	}
	[Symbol.dispose](): void {
		this.close();
	}
	/** Wait for one whole frame. Throws PANCAKE_ERR_CLOSED on clean EOF. */
	readFrame(): Promise<Uint8Array> {
		requireOffThreadFfi("inproc", "readFrame");
		return this.#reads.run(() =>
			this.#native.use(async (raw) => {
				const mf = new Uint8Array(MANAGED_FRAME_SIZE);
				try {
					await this.#readDiagnostic.check("read frame", (error, cap, errorLen) =>
						inprocS.pancake_inproc_conn_read_frame_with_diagnostic(
							raw,
							mf,
							error,
							cap,
							errorLen,
						));
					const dv = new DataView(mf.buffer);
					return readBytes(
						dv.getBigUint64(MANAGED_FRAME_BYTES_OFF, true),
						dv.getBigUint64(MANAGED_FRAME_LEN_OFF, true),
					);
				} finally {
					releaseManagedFrame(mf);
				}
			})
		);
	}
	writeFrame(frame: Uint8Array): Promise<void> {
		requireOffThreadFfi("inproc", "writeFrame");
		return this.#writes.run(frame, (owned) =>
			this.#native.use(async (raw) => {
				await this.#writeDiagnostic.check("write frame", (error, cap, errorLen) =>
					inprocS.pancake_inproc_conn_write_frame_with_diagnostic(
						raw,
						owned.argument(),
						error,
						cap,
						errorLen,
					));
			}));
	}
}

/** A bound in-process listener on a string designator. Closed on `close` /
 * `[Symbol.dispose]`. */
export class Listener {
	readonly #native: NativeHandle;
	readonly #parent: NativeParent<Connection | Listener>;
	readonly #accepts = new SingleFlight("inproc accept");
	readonly #acceptDiagnostic = new NativeDiagnostic("inproc");
	constructor(raw: Ptr, parent: NativeParent<Connection | Listener>) {
		this.#parent = parent;
		this.#native = new NativeHandle(
			"inproc listener",
			raw,
			(p) => inprocS.pancake_inproc_listener_shutdown(p),
			(p) => inprocS.pancake_inproc_listener_release(p),
			(retirement) => this.#parent.retire(this, retirement),
		);
		if (!parent.adopt(this)) throw new Error("inproc netlayer is released");
	}
	close(): void {
		this.#native.close();
	}
	[Symbol.dispose](): void {
		this.close();
	}
	/** Borrowed wake descriptor for integration with an external reactor. The
	 * listener owns it; do not close it or retain it after `close`. */
	readinessFd(): number {
		const out = new Uint8Array(4);
		checkInproc(inprocS.pancake_inproc_listener_readiness_fd(this.#native.borrow(), out));
		return new DataView(out.buffer).getInt32(0, true);
	}
	/** Block until a dialer connects, returning the in-process connection framing
	 * on `codec`, refusing inbound frames over `maxFrameBytes`. */
	accept(codec: Codec = "syrup", maxFrameBytes = 4096): Promise<Connection> {
		requireOffThreadFfi("inproc", "accept");
		const frameLimit = checkedMaxFrameBytes(maxFrameBytes);
		return this.#accepts.run(() =>
			this.#native.use(async (raw) => {
				const out = new Uint8Array(8);
				await this.#acceptDiagnostic.check("accept", (error, cap, errorLen) =>
					inprocS.pancake_inproc_accept_with_diagnostic(
						raw,
						codecId(codec),
						BigInt(frameLimit),
						out,
						error,
						cap,
						errorLen,
					));
				return new Connection(outPointer(out), this.#parent, frameLimit);
			})
		);
	}
}

/** Owns the in-process switchboard and its one I/O backend; outlives the
 * connections and listeners made from it. */
export class Netlayer {
	readonly #native: NativeParent<Connection | Listener>;
	constructor(raw?: Ptr) {
		requireOffThreadFfi("inproc", "native transport lifecycle");
		let native = raw;
		if (native == null) {
			const out = new Uint8Array(8);
			checkInproc(inprocS.pancake_inproc_netlayer_new(out));
			native = outPointer(out);
		}
		this.#native = new NativeParent(
			"inproc netlayer",
			native,
			undefined,
			(p) => inprocS.pancake_inproc_netlayer_release(p),
		);
	}

	release(): void {
		this.#native.close();
	}
	[Symbol.dispose](): void {
		this.release();
	}
	async [Symbol.asyncDispose](): Promise<void> {
		this.release();
		await this.#native.waitClosed();
	}
	/** Bind a listener on `designator` (any opaque token). */
	listen(designator: string): Listener {
		const d = new TextEncoder().encode(designator);
		const out = new Uint8Array(8);
		checkInproc(
			inprocS.pancake_inproc_listen(this.#native.borrow(), d, BigInt(d.length), out),
		);
		return new Listener(outPointer(out), this.#native);
	}
	/** Dial the listener bound at `designator` and return an in-process
	 * connection framing on `codec`, refusing inbound frames over
	 * `maxFrameBytes`. */
	connect(
		designator: string,
		codec: Codec = "syrup",
		maxFrameBytes = 4096,
	): Promise<Connection> {
		const frameLimit = checkedMaxFrameBytes(maxFrameBytes);
		const d = new TextEncoder().encode(designator);
		return this.#native.use(async (raw) => {
			const out = new Uint8Array(8);
			await checkDiagnosedCall(
				"inproc",
				"connect",
				(error, cap, errorLen) =>
					inprocS.pancake_inproc_connect_with_diagnostic(
						raw,
						d,
						BigInt(d.length),
						codecId(codec),
						BigInt(frameLimit),
						out,
						error,
						cap,
						errorLen,
					),
			);
			return new Connection(outPointer(out), this.#native, frameLimit);
		});
	}
}
