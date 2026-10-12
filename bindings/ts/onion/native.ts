// Raw onion archive ownership. The public facade and generic-driver provider
// build on these exact handles; no wrapper stands between callers and them.

import {
	AsyncFfiWriteQueue,
	checkDiagnosedCall,
	checkedMaxFrameBytes,
	codecId,
	consumedReleaseFailure,
	ffi,
	GlowcapError,
	MANAGED_FRAME_BYTES_OFF,
	MANAGED_FRAME_LEN_OFF,
	MANAGED_FRAME_SIZE,
	NativeDiagnostic,
	NativeHandle,
	NativeParent,
	outPointer,
	readBytes,
	readErrorSlot,
	releaseManagedFrame,
	requireOffThreadFfi,
	SingleFlight,
} from "@glowcap/runtime/transport";
import type { Codec, Locator, Ptr } from "@glowcap/runtime/transport";
import {
	ONION_AUTH_COOKIE,
	ONION_AUTH_NONE,
	ONION_AUTH_PASSWORD,
	ONION_SERVICE_ID_LEN,
	ONION_SERVICE_KEY_CAP,
	RAW_TRANSPORT_DEFAULT_FRAME_CAP,
	TRANSPORT_ONION,
} from "@glowcap/abi";
import { onionS } from "./ffi.ts";

const encoder = new TextEncoder();

/** A version 3 onion service id is always exactly this many characters. */
export const SERVICE_ID_LENGTH = ONION_SERVICE_ID_LEN;

/** Build the hint-free locator standardized for an onion service. */
export function locator(serviceId: string): Locator {
	return {
		transport: TRANSPORT_ONION,
		designator: serviceId,
		hints: new Map(),
		hintWireForm: "boolean-false",
	};
}

/** How the control endpoint expects to be authenticated.
 *
 * `none` is what an unauthenticated Unix control socket gives, and what upstream
 * Goblins assumes. `cookie` carries the bytes of the file `CookieAuthFile` names,
 * which the transport sends as hexadecimal, and is the common default on a
 * distribution's Tor package. `password` carries the cleartext of a
 * `HashedControlPassword` setup. */
export type Auth =
	| { kind: "none" }
	| { kind: "cookie"; cookie: Uint8Array }
	| { kind: "password"; password: string };

/** Where Tor listens and what to ask it for. */
export interface NetlayerOptions {
	/** Tor's SOCKS endpoint: an absolute Unix socket path, or a `host:port`.
	 * Required: a netlayer that cannot dial is not a netlayer. */
	socks: string;
	/** Tor's control endpoint, in the same two forms. Omit for dial-only. */
	control?: string;
	/** Defaults to `{ kind: "none" }`. */
	auth?: Auth;
	/** The key that restores an existing service, as
	 * `Listener.serviceKey` reported it. Omit to ask for a fresh service. */
	serviceKey?: Uint8Array;
	/** The local endpoint Tor forwards the service's virtual port to. Omit to bind
	 * a loopback port and report the one the OS chose. */
	forward?: string;
	/** Cancel generic driver listener construction before readiness. */
	signal?: AbortSignal;
}

/** Interpret one result through the onion archive's own diagnostic slot. */
export function checkOnion(code: number): void {
	if (code === 0) return;
	throw new GlowcapError(
		code,
		readErrorSlot(onionS.glowcap_onion_last_error) ?? `onion transport call failed (code ${code})`,
	);
}

// `GlowcapOnionConfig`: ptr,len ×2, padded u32 auth kind, then ptr,len ×3.
// Keep every encoded field alive until the constructor returns because the
// native call borrows the pointers held by the transient struct.
function encodeConfig(options: NetlayerOptions): { struct: Uint8Array; keepAlive: Uint8Array[] } {
	const socks = encoder.encode(options.socks);
	const control = encoder.encode(options.control ?? "");
	const auth = options.auth ?? { kind: "none" };
	const secret = auth.kind === "cookie"
		? auth.cookie
		: auth.kind === "password"
		? encoder.encode(auth.password)
		: new Uint8Array(0);
	const authKind = auth.kind === "cookie"
		? ONION_AUTH_COOKIE
		: auth.kind === "password"
		? ONION_AUTH_PASSWORD
		: ONION_AUTH_NONE;
	const serviceKey = options.serviceKey ?? new Uint8Array(0);
	const forward = encoder.encode(options.forward ?? "");
	const struct = new Uint8Array(8 * 11);
	const view = new DataView(struct.buffer);
	const put = (offset: number, bytes: Uint8Array): void => {
		view.setBigUint64(offset, bytes.length === 0 ? 0n : ffi.pointerOf(bytes), true);
		view.setBigUint64(offset + 8, BigInt(bytes.length), true);
	};
	put(0, socks);
	put(16, control);
	view.setUint32(32, authKind, true);
	put(40, secret);
	put(56, serviceKey);
	put(72, forward);
	return { struct, keepAlive: [socks, control, secret, serviceKey, forward] };
}

/** Open one native onion parent. Provider setup releases only its constructor
 * reference after the driver has retained the package. */
export function openNetlayer(options: NetlayerOptions): Ptr {
	requireOffThreadFfi("onion", "native transport lifecycle");
	const { struct, keepAlive } = encodeConfig(options);
	const out = new Uint8Array(8);
	checkOnion(onionS.glowcap_onion_netlayer_new(struct, out));
	void keepAlive;
	return outPointer(out);
}

/** A blocking onion connection: the `glowcap_onion_*` frame shuttle over one
 * circuit. Closed on `close` / `[Symbol.dispose]`. */
export class Connection {
	readonly #native: NativeHandle;
	readonly #parent: NativeParent<Connection | Listener>;
	readonly #reads = new SingleFlight("onion read");
	readonly #writes: AsyncFfiWriteQueue;
	readonly #readDiagnostic = new NativeDiagnostic("onion");
	readonly #writeDiagnostic = new NativeDiagnostic("onion");

	constructor(raw: Ptr, parent: NativeParent<Connection | Listener>, maxFrameBytes: number) {
		this.#parent = parent;
		this.#writes = new AsyncFfiWriteQueue("onion", maxFrameBytes);
		this.#native = new NativeHandle(
			"onion connection",
			raw,
			(pointer) => checkOnion(onionS.glowcap_onion_conn_shutdown(pointer)),
			async (pointer) => {
				try {
					await checkDiagnosedCall(
						"onion",
						"connection release",
						(error, cap, errorLen) => onionS.glowcap_onion_conn_release(pointer, error, cap, errorLen),
					);
				} catch (error) {
					consumedReleaseFailure(error);
				}
			},
			(retirement) => this.#parent.retire(this, retirement),
		);
		if (!parent.adopt(this)) throw new Error("onion netlayer is released");
	}

	close(): void {
		this.#native.close();
	}

	[Symbol.dispose](): void {
		this.close();
	}

	/** Wait for one whole frame. Throws GLOWCAP_ERR_CLOSED on clean EOF.
	 *
	 * The native operation may wait for the rest of a fragmented frame even after
	 * `readinessFd()` reports readable. Deno dispatches this blocking FFI call away
	 * from its event loop; Bun's FFI is synchronous, so Bun callers must keep this
	 * off their event-loop thread. */
	readFrame(): Promise<Uint8Array> {
		requireOffThreadFfi("onion", "readFrame");
		return this.#reads.run(() =>
			this.#native.use(async (raw) => {
				const frame = new Uint8Array(MANAGED_FRAME_SIZE);
				try {
					await this.#readDiagnostic.check("read frame", (error, cap, errorLen) =>
						onionS.glowcap_onion_conn_read_frame(raw, frame, error, cap, errorLen));
					const view = new DataView(frame.buffer);
					return readBytes(
						view.getBigUint64(MANAGED_FRAME_BYTES_OFF, true),
						view.getBigUint64(MANAGED_FRAME_LEN_OFF, true),
					);
				} finally {
					releaseManagedFrame(frame);
				}
			})
		);
	}

	/** The descriptor this connection's bytes flow over, for a loop that polls
	 * rather than blocks. Owned by the connection: do not close it, and do not use
	 * it after `close`. */
	readinessFd(): number {
		const out = new Uint8Array(4);
		checkOnion(onionS.glowcap_onion_conn_readiness_fd(this.#native.borrow(), out));
		return new DataView(out.buffer).getInt32(0, true);
	}

	writeFrame(frame: Uint8Array): Promise<void> {
		requireOffThreadFfi("onion", "writeFrame");
		return this.#writes.run(frame, (owned) =>
			this.#native.use(async (raw) => {
				await this.#writeDiagnostic.check("write frame", (error, cap, errorLen) =>
					onionS.glowcap_onion_conn_write_frame(raw, owned.argument(), error, cap, errorLen));
			}));
	}
}

/** A live onion service: the control session keeping it published plus the local
 * endpoint Tor forwards it to.
 *
 * Closing withdraws the service, so the address stops resolving. That is the one
 * release in this family with an effect a partner can observe. */
export class Listener {
	readonly #native: NativeHandle;
	readonly #parent: NativeParent<Connection | Listener>;
	readonly #operations = new SingleFlight("onion listener");
	readonly #acceptDiagnostic = new NativeDiagnostic("onion");
	readonly #waitDiagnostic = new NativeDiagnostic("onion");
	readonly #releaseDiagnostic = new NativeDiagnostic("onion");
	/** The version 3 service id Tor minted or restored, without its `.onion`
	 * suffix. This is the designator a partner dials. */
	readonly serviceId: string;
	/** The key that restores this exact service, or empty when the service was
	 * restored rather than minted. Store these bytes and pass them back as
	 * `NetlayerOptions.serviceKey` for an address that survives a restart. */
	readonly serviceKey: Uint8Array;

	constructor(
		raw: Ptr,
		serviceId: string,
		serviceKey: Uint8Array,
		parent: NativeParent<Connection | Listener>,
	) {
		this.#parent = parent;
		this.serviceId = serviceId;
		this.serviceKey = serviceKey;
		this.#native = new NativeHandle(
			"onion listener",
			raw,
			(pointer) => onionS.glowcap_onion_listener_shutdown(pointer),
			async (pointer) => {
				try {
					await this.#releaseDiagnostic.check(
						"listener release",
						(error, cap, errorLen) => onionS.glowcap_onion_listener_release(pointer, error, cap, errorLen),
					);
				} catch (error) {
					consumedReleaseFailure(error);
				}
			},
			(retirement) => this.#parent.retire(this, retirement),
		);
		if (!parent.adopt(this)) throw new Error("onion netlayer is released");
	}

	close(): void {
		this.#native.close();
	}

	[Symbol.dispose](): void {
		this.close();
	}

	/** Block until Tor forwards a circuit to this service, returning the
	 * connection framing on `codec`, refusing inbound frames over
	 * `maxFrameBytes`.
	 *
	 * The partner's claimed location is unverified here: Tor tells a hidden
	 * service nothing about who dialed it. */
	accept(codec: Codec = "syrup", maxFrameBytes = RAW_TRANSPORT_DEFAULT_FRAME_CAP): Promise<Connection> {
		requireOffThreadFfi("onion", "accept");
		const frameLimit = checkedMaxFrameBytes(maxFrameBytes);
		return this.#operations.run(() =>
			this.#native.use(async (raw) => {
				const out = new Uint8Array(8);
				await this.#acceptDiagnostic.check("accept", (error, cap, errorLen) =>
					onionS.glowcap_onion_accept(raw, codecId(codec), BigInt(frameLimit), out, error, cap, errorLen));
				return new Connection(outPointer(out), this.#parent, frameLimit);
			})
		);
	}

	/** The descriptor this listener's circuits arrive on, for a loop that polls
	 * rather than blocks.
	 *
	 * This is what keeps an event-driven consumer off the blocking path: wrap it in
	 * a socket your runtime can await, and call `accept` only once it is readable.
	 * Owned by the listener: do not close it, and do not use it after `close`. */
	readinessFd(): number {
		const out = new Uint8Array(4);
		checkOnion(onionS.glowcap_onion_listener_readiness_fd(this.#native.borrow(), out));
		return new DataView(out.buffer).getInt32(0, true);
	}

	/** Wait up to `timeoutMs` for `accept` to be able to make progress. False on
	 * timeout. This lets an accept loop check a stop flag instead of parking or
	 * closing the listener from another thread. */
	wait(timeoutMs: number): Promise<boolean> {
		requireOffThreadFfi("onion", "wait");
		return this.#operations.run(() =>
			this.#native.use(async (raw) => {
				const out = new Uint8Array(4);
				await this.#waitDiagnostic.check("wait for accept", (error, cap, errorLen) =>
					onionS.glowcap_onion_listener_wait(raw, timeoutMs, out, error, cap, errorLen));
				return new DataView(out.buffer).getUint32(0, true) !== 0;
			})
		);
	}
}

/** Owns where Tor listens and the one I/O backend its streams block on; outlives
 * the connections and listeners made from it. */
export class Netlayer {
	readonly #native: NativeParent<Connection | Listener>;

	constructor(options: NetlayerOptions) {
		this.#native = new NativeParent(
			"onion netlayer",
			openNetlayer(options),
			(pointer) => onionS.glowcap_onion_netlayer_shutdown(pointer),
			(pointer) =>
				new NativeDiagnostic("onion").check(
					"netlayer release",
					(error, cap, errorLen) => onionS.glowcap_onion_netlayer_release(pointer, error, cap, errorLen),
				),
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

	/** Ask Tor for an onion service and bind its local end.
	 *
	 * Requires a control endpoint; without one this throws rather than reporting a
	 * service nothing could reach. */
	listen(): Promise<Listener> {
		requireOffThreadFfi("onion", "listen");
		return this.#native.use(async (raw) => {
			const id = new Uint8Array(SERVICE_ID_LENGTH);
			const idLen = new Uint8Array(8);
			const key = new Uint8Array(ONION_SERVICE_KEY_CAP);
			const keyLen = new Uint8Array(8);
			const out = new Uint8Array(8);
			await checkDiagnosedCall(
				"onion",
				"listen",
				(error, cap, errorLen) =>
					onionS.glowcap_onion_listen(
						raw,
						id,
						BigInt(id.length),
						idLen,
						key,
						BigInt(key.length),
						keyLen,
						out,
						error,
						cap,
						errorLen,
					),
			);
			const idBytes = Number(new DataView(idLen.buffer).getBigUint64(0, true));
			const keyBytes = Number(new DataView(keyLen.buffer).getBigUint64(0, true));
			return new Listener(
				outPointer(out),
				new TextDecoder().decode(id.subarray(0, idBytes)),
				key.slice(0, keyBytes),
				this.#native,
			);
		});
	}

	/** Dial the onion service `serviceId` through the configured Tor.
	 *
	 * `serviceId` is the bare 56-character designator. One that is not a
	 * well-formed version 3 address is refused before any socket opens. Blocking:
	 * a circuit takes seconds. */
	connect(
		serviceId: string,
		codec: Codec = "syrup",
		maxFrameBytes = RAW_TRANSPORT_DEFAULT_FRAME_CAP,
	): Promise<Connection> {
		requireOffThreadFfi("onion", "connect");
		const frameLimit = checkedMaxFrameBytes(maxFrameBytes);
		return this.#native.use(async (raw) => {
			const designator = encoder.encode(serviceId);
			const out = new Uint8Array(8);
			await checkDiagnosedCall(
				"onion",
				"connect",
				(error, cap, errorLen) =>
					onionS.glowcap_onion_connect(
						raw,
						designator,
						BigInt(designator.length),
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
