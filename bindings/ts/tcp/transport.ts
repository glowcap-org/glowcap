// Framed transport API for `libpancake_net_transport_tcp`, beside
// this package's dependency-free locator constructors in `mod.ts` (ADR-0059).
//
// The transport subpath opens only the TCP archive and builds on `@pancake/runtime`'s
// shared frame/context types. Applications normally use the package root to
// construct locators and the runtime's `connect`/`listen`; this subpath exposes
// provider installation and the C ABI's direct frame shuttle. Deno offloads
// every potentially blocking call;
// runtimes with synchronous FFI refuse those methods before entering native code.
//
//   using net = new Netlayer();
//   using listener = net.listen("127.0.0.1", 0);
//   using client = await net.connect("127.0.0.1", listener.port());
//   using server = await listener.accept();
//   await client.writeFrame(frame);
//   const got = await server.readFrame();
//
// The TCP archive keeps its own thread-local last-error, read through
// `pancake_tcp_last_error`, so a failed call's diagnostic never scrapes the
// core's unrelated `pancake_last_error`.

import {
	AsyncFfiWriteQueue,
	checkDiagnosedCall,
	checkedMaxFrameBytes,
	codecId,
	consumedReleaseFailure,
	MANAGED_FRAME_BYTES_OFF,
	MANAGED_FRAME_LEN_OFF,
	MANAGED_FRAME_SIZE,
	NativeDiagnostic,
	NativeHandle,
	NativeParent,
	outPointer,
	PancakeError,
	readBytes,
	readErrorSlot,
	releaseManagedFrame,
	requireOffThreadFfi,
	SingleFlight,
	TCP_CONFIG_SIZE,
	TCP_CONFIG_STREAM_OFF,
	TCP_STREAM_OPTIONS_KEEPALIVE_COUNT_OFF,
	TCP_STREAM_OPTIONS_KEEPALIVE_IDLE_SEC_OFF,
	TCP_STREAM_OPTIONS_KEEPALIVE_INTERVAL_SEC_OFF,
	TCP_STREAM_OPTIONS_SIZE,
	TRANSPORT_PROVIDER_SIZE,
} from "@pancake/runtime/transport";
import type { Codec, ProviderTarget, Ptr } from "@pancake/runtime/transport";
import { tcpS } from "./ffi.ts";
import { TRANSPORT_KEYED_TCP, TRANSPORT_NOISE_TCP, TRANSPORT_TCP } from "@pancake/abi";

const OK = 0;

export interface Keepalive {
	readonly idleSeconds: number;
	readonly intervalSeconds: number;
	readonly count: number;
}

export interface StreamOptions {
	readonly keepalive?: Keepalive;
}

export interface Config {
	readonly stream?: StreamOptions;
}

/** Per-dial TCP policy overriding the provider's inherited Config. */
export interface OperationOptions {
	readonly stream?: StreamOptions;
}

function u32(value: number, name: string): number {
	if (!Number.isInteger(value) || value < 0 || value > 0xffff_ffff) {
		throw new RangeError(`${name} must fit an unsigned 32-bit integer`);
	}
	return value;
}

function encodeStreamOptions(options: StreamOptions = {}): Uint8Array {
	const raw = new Uint8Array(TCP_STREAM_OPTIONS_SIZE);
	const keepalive = options.keepalive;
	if (keepalive == null) return raw;
	const view = new DataView(raw.buffer);
	view.setUint32(
		TCP_STREAM_OPTIONS_KEEPALIVE_IDLE_SEC_OFF,
		u32(keepalive.idleSeconds, "keepalive.idleSeconds"),
		true,
	);
	view.setUint32(
		TCP_STREAM_OPTIONS_KEEPALIVE_INTERVAL_SEC_OFF,
		u32(keepalive.intervalSeconds, "keepalive.intervalSeconds"),
		true,
	);
	view.setUint32(
		TCP_STREAM_OPTIONS_KEEPALIVE_COUNT_OFF,
		u32(keepalive.count, "keepalive.count"),
		true,
	);
	return raw;
}

function encodeConfig(config: Config): Uint8Array {
	const raw = new Uint8Array(TCP_CONFIG_SIZE);
	raw.set(encodeStreamOptions(config.stream), TCP_CONFIG_STREAM_OFF);
	return raw;
}

/** Build a typed per-operation override for `Runtime.connect`. */
export function options(
	value: OperationOptions = {},
): import("@pancake/runtime").TransportOperationOptions {
	return {
		transports: [TRANSPORT_TCP, TRANSPORT_KEYED_TCP, TRANSPORT_NOISE_TCP],
		data: encodeStreamOptions(value.stream),
	};
}

// The calling thread's last error from the TCP transport, or null when there is
// none. The transport keeps its own thread-local slot, so a tcp call's
// diagnostic is read here, never from the core's `pancake_last_error`.
function tcpLastError(): string | null {
	return readErrorSlot(tcpS.pancake_tcp_last_error);
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

/** A TCP connection whose potentially blocking operations run off-thread. */
export class Connection {
	readonly #native: NativeHandle;
	readonly #parent: NativeParent<Connection | Listener>;
	readonly #reads = new SingleFlight("tcp read");
	readonly #writes: AsyncFfiWriteQueue;
	readonly #readDiagnostic = new NativeDiagnostic("tcp");
	readonly #writeDiagnostic = new NativeDiagnostic("tcp");
	constructor(raw: Ptr, parent: NativeParent<Connection | Listener>, maxFrameBytes: number) {
		this.#parent = parent;
		this.#writes = new AsyncFfiWriteQueue("tcp", maxFrameBytes);
		this.#native = new NativeHandle(
			"tcp connection",
			raw,
			(p) => checkTcp(tcpS.pancake_tcp_conn_shutdown(p)),
			async (p) => {
				try {
					await checkDiagnosedCall(
						"tcp",
						"connection release",
						(error, cap, errorLen) => tcpS.pancake_tcp_conn_release(p, error, cap, errorLen),
					);
				} catch (error) {
					consumedReleaseFailure(error);
				}
			},
			(retirement) => this.#parent.retire(this, retirement),
		);
		if (!parent.adopt(this)) throw new Error("tcp netlayer is released");
	}
	close(): void {
		this.#native.close();
	}
	[Symbol.dispose](): void {
		this.close();
	}
	/** Wait for one whole frame. Throws PANCAKE_ERR_CLOSED on clean EOF. */
	readFrame(): Promise<Uint8Array> {
		requireOffThreadFfi("tcp", "readFrame");
		return this.#reads.run(() =>
			this.#native.use(async (raw) => {
				const mf = new Uint8Array(MANAGED_FRAME_SIZE);
				try {
					await this.#readDiagnostic.check("read frame", (error, cap, errorLen) =>
						tcpS.pancake_tcp_conn_read_frame(
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
		requireOffThreadFfi("tcp", "writeFrame");
		return this.#writes.run(frame, (owned) =>
			this.#native.use(async (raw) => {
				await this.#writeDiagnostic.check("write frame", (error, cap, errorLen) =>
					tcpS.pancake_tcp_conn_write_frame(
						raw,
						owned.argument(),
						error,
						cap,
						errorLen,
					));
			}));
	}
}

/** A bound TCP listener. Closed on `close` / `[Symbol.dispose]`. */
export class Listener {
	readonly #native: NativeHandle;
	readonly #parent: NativeParent<Connection | Listener>;
	readonly #accepts = new SingleFlight("tcp accept");
	readonly #acceptDiagnostic = new NativeDiagnostic("tcp");
	constructor(raw: Ptr, parent: NativeParent<Connection | Listener>) {
		this.#parent = parent;
		this.#native = new NativeHandle(
			"tcp listener",
			raw,
			(p) => tcpS.pancake_tcp_listener_shutdown(p),
			(p) => tcpS.pancake_tcp_listener_release(p),
			(retirement) => this.#parent.retire(this, retirement),
		);
		if (!parent.adopt(this)) throw new Error("tcp netlayer is released");
	}
	close(): void {
		this.#native.close();
	}
	[Symbol.dispose](): void {
		this.close();
	}
	port(): number {
		const out = new Uint8Array(2);
		checkTcp(tcpS.pancake_tcp_listener_port(this.#native.borrow(), out));
		return new DataView(out.buffer).getUint16(0, true);
	}
	/** Borrowed listening descriptor for integration with an external reactor.
	 * The listener owns it; do not close it or retain it after `close`. */
	readinessFd(): number {
		const out = new Uint8Array(4);
		checkTcp(tcpS.pancake_tcp_listener_readiness_fd(this.#native.borrow(), out));
		return new DataView(out.buffer).getInt32(0, true);
	}
	accept(
		codec: Codec = "syrup",
		maxFrameBytes = 4096,
		options?: StreamOptions,
	): Promise<Connection> {
		requireOffThreadFfi("tcp", "accept");
		const frameLimit = checkedMaxFrameBytes(maxFrameBytes);
		return this.#accepts.run(() =>
			this.#native.use(async (raw) => {
				const out = new Uint8Array(8);
				await this.#acceptDiagnostic.check("accept", (error, cap, errorLen) =>
					tcpS.pancake_tcp_accept(
						raw,
						options == null ? null : encodeStreamOptions(options),
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

/** Owns the blocking-TCP I/O backend; outlives the connections made from it. */
export class Netlayer {
	readonly #native: NativeParent<Connection | Listener>;
	constructor(config: Config = {}) {
		requireOffThreadFfi("tcp", "native transport lifecycle");
		const out = new Uint8Array(8);
		checkTcp(tcpS.pancake_tcp_netlayer_new(encodeConfig(config), out));
		const native = outPointer(out);
		this.#native = new NativeParent(
			"tcp netlayer",
			native,
			(p) => tcpS.pancake_tcp_netlayer_shutdown(p),
			(p) => tcpS.pancake_tcp_netlayer_release(p),
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
	listen(host: string, port = 0): Listener {
		const h = new TextEncoder().encode(host);
		const out = new Uint8Array(8);
		checkTcp(
			tcpS.pancake_tcp_listen(this.#native.borrow(), h, BigInt(h.length), port, out),
		);
		return new Listener(outPointer(out), this.#native);
	}
	connect(
		host: string,
		port: number,
		codec: Codec = "syrup",
		maxFrameBytes = 4096,
		options?: StreamOptions,
	): Promise<Connection> {
		requireOffThreadFfi("tcp", "connect");
		const frameLimit = checkedMaxFrameBytes(maxFrameBytes);
		const h = new TextEncoder().encode(host);
		return this.#native.use(async (raw) => {
			const out = new Uint8Array(8);
			await checkDiagnosedCall(
				"tcp",
				"connect",
				(error, cap, errorLen) =>
					tcpS.pancake_tcp_connect(
						raw,
						h,
						BigInt(h.length),
						port,
						options == null ? null : encodeStreamOptions(options),
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

/** Install this archive's tcp/keyed-tcp/noise-tcp package once per driver.
 * Registration acquires the native lease before this function drops the
 * construction reference; no binding-side owner is retained. */
export function installProvider(loop: ProviderTarget, config: Config = {}): void {
	const out = new Uint8Array(8);
	checkTcp(tcpS.pancake_tcp_netlayer_new(encodeConfig(config), out));
	const raw = outPointer(out);
	try {
		const packageBytes = new Uint8Array(TRANSPORT_PROVIDER_SIZE);
		checkTcp(tcpS.pancake_tcp_transport_provider(raw, packageBytes));
		loop.installProvider((register) => register(packageBytes));
	} finally {
		// This is a reference drop, not connection shutdown. On success the driver
		// owns the remaining lease; on failure this retires the uninstalled runtime.
		tcpS.pancake_tcp_netlayer_release(raw);
	}
}

/** Configure this archive's tcp/keyed-tcp/noise-tcp package for `connect`. */
export function provider(config: Config = {}): import("@pancake/runtime").DriverProvider {
	return {
		install(loop) {
			installProvider(loop, config);
			return Promise.resolve();
		},
	};
}
