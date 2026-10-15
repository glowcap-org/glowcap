// Idiomatic JavaScript/TypeScript API for `libglowcap_net_transport_inproc`.
// It is glowcap's in-process transport, a composable companion to the core `./mod.ts`
// module (ADR-0059).
//
// This is the socket-free sibling of `./tcp.ts`: two peers in one process wired
// by in-process pipes and no kernel transport. The C listener adds a wake
// descriptor for reactor integration; no application bytes flow through it. It rides its
// own archive (`libglowcap_net_transport_inproc`), symbol-disjoint from the core
// and from the other transports, sharing the frame/context types by layout. The
// lifecycle matches TCP (make the netlayer, bind a listener or dial a
// connection, release the connections, then release the netlayer), but a listener
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
// `glowcap_inproc_last_error`, so a failed call's diagnostic never scrapes the
// core's unrelated `glowcap_last_error`.

import {
	AsyncFfiWriteQueue,
	checkDiagnosedCall,
	checkedMaxFrameBytes,
	codecId,
	consumedReleaseFailure,
	FfiDiagnostic,
	FfiHandle,
	FfiParent,
	GlowcapError,
	MANAGED_FRAME_BYTES_OFF,
	MANAGED_FRAME_LEN_OFF,
	MANAGED_FRAME_SIZE,
	outPointer,
	readBytes,
	readErrorSlot,
	releaseManagedFrame,
	requireOffThreadFfi,
	SingleFlight,
} from "@glowcap/runtime/transport";
import type { Codec, Locator, Ptr } from "@glowcap/runtime/transport";
import { inprocS } from "./ffi.ts";
import { RAW_TRANSPORT_DEFAULT_FRAME_CAP, TRANSPORT_INPROC } from "@glowcap/abi";

const OK = 0;

/** Build a hint-free locator for an in-process switchboard name. */
export function locator(designator: string): Locator {
	return {
		transport: TRANSPORT_INPROC,
		designator,
		hints: new Map(),
		hintWireForm: "boolean-false",
	};
}

// The calling thread's last error from the in-process transport, or null when
// there is none. The transport keeps its own thread-local slot, so a call's
// diagnostic is read here, never from the core's `glowcap_last_error`.
function inprocLastError(): string | null {
	return readErrorSlot(inprocS.glowcap_inproc_last_error);
}

// A failed in-process-transport call: read its diagnostic from the transport's
// own thread-local last-error and pass it explicitly, so `GlowcapError` never
// scrapes the unrelated core-family `glowcap_last_error`.
function checkInproc(code: number): void {
	if (code !== OK) {
		throw new GlowcapError(
			code,
			inprocLastError() ?? `inproc transport call failed (code ${code})`,
		);
	}
}

/** An in-process connection whose potentially blocking operations run off-thread. */
export class Connection {
	readonly #ffi: FfiHandle;
	readonly #parent: FfiParent<Connection | Listener>;
	readonly #reads = new SingleFlight("inproc read");
	readonly #writes: AsyncFfiWriteQueue;
	readonly #readDiagnostic = new FfiDiagnostic("inproc");
	readonly #writeDiagnostic = new FfiDiagnostic("inproc");
	constructor(raw: Ptr, parent: FfiParent<Connection | Listener>, maxFrameBytes: number) {
		this.#parent = parent;
		this.#writes = new AsyncFfiWriteQueue("inproc", maxFrameBytes);
		this.#ffi = new FfiHandle(
			"inproc connection",
			raw,
			(p) => inprocS.glowcap_inproc_conn_shutdown(p),
			(p) => inprocS.glowcap_inproc_conn_release(p),
			(retirement) => this.#parent.retire(this, retirement),
		);
		if (!parent.adopt(this)) throw new Error("inproc netlayer is released");
	}
	close(): void {
		this.#ffi.close();
	}
	[Symbol.dispose](): void {
		this.close();
	}
	/** Wait for one whole frame. Throws GLOWCAP_ERR_CLOSED on clean EOF. */
	readFrame(): Promise<Uint8Array> {
		requireOffThreadFfi("inproc", "readFrame");
		return this.#reads.run(() =>
			this.#ffi.use(async (raw) => {
				const mf = new Uint8Array(MANAGED_FRAME_SIZE);
				try {
					await this.#readDiagnostic.check("read frame", (error, cap, errorLen) =>
						inprocS.glowcap_inproc_conn_read_frame(
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
			this.#ffi.use(async (raw) => {
				await this.#writeDiagnostic.check("write frame", (error, cap, errorLen) =>
					inprocS.glowcap_inproc_conn_write_frame(
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
	readonly #ffi: FfiHandle;
	readonly #parent: FfiParent<Connection | Listener>;
	readonly #accepts = new SingleFlight("inproc accept");
	readonly #acceptDiagnostic = new FfiDiagnostic("inproc");
	readonly #releaseDiagnostic = new FfiDiagnostic("inproc");
	constructor(raw: Ptr, parent: FfiParent<Connection | Listener>) {
		this.#parent = parent;
		this.#ffi = new FfiHandle(
			"inproc listener",
			raw,
			(p) => inprocS.glowcap_inproc_listener_shutdown(p),
			async (p) => {
				try {
					await this.#releaseDiagnostic.check(
						"listener release",
						(error, cap, errorLen) => inprocS.glowcap_inproc_listener_release(p, error, cap, errorLen),
					);
				} catch (error) {
					consumedReleaseFailure(error);
				}
			},
			(retirement) => this.#parent.retire(this, retirement),
		);
		if (!parent.adopt(this)) throw new Error("inproc netlayer is released");
	}
	close(): void {
		this.#ffi.close();
	}
	[Symbol.dispose](): void {
		this.close();
	}
	/** Borrowed wake descriptor for integration with an external reactor. The
	 * listener owns it; do not close it or retain it after `close`. */
	readinessFd(): number {
		const out = new Uint8Array(4);
		checkInproc(inprocS.glowcap_inproc_listener_readiness_fd(this.#ffi.borrow(), out));
		return new DataView(out.buffer).getInt32(0, true);
	}
	/** Block until a dialer connects, returning the in-process connection framing
	 * on `codec`, refusing inbound frames over `maxFrameBytes`. */
	accept(codec: Codec = "syrup", maxFrameBytes = RAW_TRANSPORT_DEFAULT_FRAME_CAP): Promise<Connection> {
		requireOffThreadFfi("inproc", "accept");
		const frameLimit = checkedMaxFrameBytes(maxFrameBytes);
		return this.#accepts.run(() =>
			this.#ffi.use(async (raw) => {
				const out = new Uint8Array(8);
				await this.#acceptDiagnostic.check("accept", (error, cap, errorLen) =>
					inprocS.glowcap_inproc_accept(
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
	readonly #ffi: FfiParent<Connection | Listener>;
	constructor(raw?: Ptr) {
		requireOffThreadFfi("inproc", "FFI transport lifecycle");
		let ptr = raw;
		if (ptr == null) {
			const out = new Uint8Array(8);
			checkInproc(inprocS.glowcap_inproc_netlayer_new(out));
			ptr = outPointer(out);
		}
		this.#ffi = new FfiParent(
			"inproc netlayer",
			ptr,
			undefined,
			(p) => inprocS.glowcap_inproc_netlayer_release(p),
		);
	}

	release(): void {
		this.#ffi.close();
	}
	[Symbol.dispose](): void {
		this.release();
	}
	async [Symbol.asyncDispose](): Promise<void> {
		this.release();
		await this.#ffi.waitClosed();
	}
	/** Bind a listener on `designator` (any opaque token). */
	listen(designator: string): Listener {
		const d = new TextEncoder().encode(designator);
		const out = new Uint8Array(8);
		checkInproc(
			inprocS.glowcap_inproc_listen(this.#ffi.borrow(), d, BigInt(d.length), out),
		);
		return new Listener(outPointer(out), this.#ffi);
	}
	/** Dial the listener bound at `designator` and return an in-process
	 * connection framing on `codec`, refusing inbound frames over
	 * `maxFrameBytes`. */
	connect(
		designator: string,
		codec: Codec = "syrup",
		maxFrameBytes = RAW_TRANSPORT_DEFAULT_FRAME_CAP,
	): Promise<Connection> {
		const frameLimit = checkedMaxFrameBytes(maxFrameBytes);
		const d = new TextEncoder().encode(designator);
		return this.#ffi.use(async (raw) => {
			const out = new Uint8Array(8);
			await checkDiagnosedCall(
				"inproc",
				"connect",
				(error, cap, errorLen) =>
					inprocS.glowcap_inproc_connect(
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
			return new Connection(outPointer(out), this.#ffi, frameLimit);
		});
	}
}
