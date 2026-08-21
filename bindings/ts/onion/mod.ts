// Idiomatic JavaScript/TypeScript API for `libpancake_net_transport_onion` —
// pancake's Tor onion transport, a composable companion to the core `./mod.ts`
// module (ADR-0059).
//
// `onion` is the one netlayer the OCapN draft standardizes, and the one upstream
// Spritely Goblins ships, so it is where a pancake peer and a Goblins vat meet on
// ground neither invented. A locator is `ocapn://<serviceid>.onion`, and the
// designator this module takes is that bare service id: 56 base32 characters with
// no `.onion` suffix.
//
// pancake starts no Tor. A `Netlayer` names where an already-running daemon
// listens — its SOCKS endpoint to dial, its control endpoint to host — and never
// spawns, supervises, or configures one. Each endpoint is an absolute Unix socket
// path or a `host:port`. Omit the control endpoint and the netlayer can dial and
// cannot host, which `listen` reports rather than pretending.
//
//   using net = new Netlayer({ socks: "/run/tor/socks", control: "/run/tor/control" });
//   using listener = await net.listen();
//   console.log(`ocapn://${listener.serviceId}.onion`);
//   using server = await listener.accept();
//   const got = await server.readFrame();
//
// Two limits are worth reading before relying on this, both ADR-0108 decisions
// rather than implementation details. A service id is an ADDRESS, not an identity:
// Tor proves the far end of the circuit holds the key the address encodes, but the
// CapTP peer is whoever holds the local endpoint that service forwards to. And an
// accepted circuit carries no client identity at all, because Tor tells a hidden
// service nothing about who dialed it, so a partner's claimed location on that
// side is unverified.
//
// There are two ways to drive this. The raw frame netlayer's Tor-reaching methods
// return promises and require a runtime that actually dispatches native calls away
// from its event loop; Deno does. Bun's FFI is synchronous, so that surface refuses
// before entering a call that could park. The product-level `listen` performs
// provider creation synchronously inside its async setup, then awaits the generic
// driver's listener-ready event before returning. Session acceptance and dial
// completion remain asynchronous. Both live raw handles also expose
// `readinessFd()`: park on that descriptor with a socket your runtime can await,
// and call `accept` once it is readable. A connection descriptor is only a
// byte-readiness hint: if Tor delivers a fragmented frame, `readFrame` may still
// wait for the remaining bytes. An onion connection is an ordinary socket, which
// is why a real descriptor is available here.
//
// The onion family keeps its own thread-local last-error, read through
// `pancake_onion_last_error`, so a failed call's diagnostic never scrapes the
// core's unrelated `pancake_last_error`.

import {
	AsyncFfiWriteQueue,
	checkDiagnosedCall,
	checkedMaxFrameBytes,
	codecId,
	consumedReleaseFailure,
	DriverListener,
	DriverLoop,
	DriverServer,
	ffi,
	Host,
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
	retainCleanupFailures,
	SingleFlight,
	TRANSPORT_PROVIDER_SIZE,
} from "@pancake/runtime/transport";
import type { Codec, DriverProvider, Locator, ProviderTarget, Ptr } from "@pancake/runtime/transport";
import { onionS } from "./ffi.ts";
import {
	ONION_AUTH_COOKIE,
	ONION_AUTH_NONE,
	ONION_AUTH_PASSWORD,
	ONION_SERVICE_ID_LEN,
	ONION_SERVICE_KEY_CAP,
	RAW_TRANSPORT_DEFAULT_FRAME_CAP,
	TRANSPORT_ONION,
} from "@pancake/abi";

const OK = 0;

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

// The three forms a real `torrc` produces, matching PANCAKE_ONION_AUTH_* in
// `include/pancake_net_transport_onion.h`.
const AUTH_NONE = ONION_AUTH_NONE;
const AUTH_COOKIE = ONION_AUTH_COOKIE;
const AUTH_PASSWORD = ONION_AUTH_PASSWORD;

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
	 * Required — a netlayer that cannot dial is not a netlayer. */
	socks: string;
	/** Tor's control endpoint, in the same two forms. Omit for dial-only. */
	control?: string;
	/** Defaults to `{ kind: "none" }`. */
	auth?: Auth;
	/** The key that restores an existing service, exactly as
	 * `Listener.serviceKey` reported it. Omit to ask for a fresh service. */
	serviceKey?: Uint8Array;
	/** The local endpoint Tor forwards the service's virtual port to. Omit to bind
	 * a loopback port and report the one the OS chose. */
	forward?: string;
	/** Cancel generic driver listener construction before readiness. */
	signal?: AbortSignal;
}

// The calling thread's last error from the onion transport, or null when there is
// none. The transport keeps its own thread-local slot, so a call's diagnostic is
// read here, never from the core's `pancake_last_error`.
function onionLastError(): string | null {
	return readErrorSlot(onionS.pancake_onion_last_error);
}

// A failed onion-transport call: read its diagnostic from the transport's own
// thread-local last-error and pass it explicitly, so `PancakeError` never scrapes
// the unrelated core-family `pancake_last_error`.
function checkOnion(code: number): void {
	if (code !== OK) {
		throw new PancakeError(
			code,
			onionLastError() ?? `onion transport call failed (code ${code})`,
		);
	}
}

const encoder = new TextEncoder();

// The C config struct, laid out to match `PancakeOnionConfig`: eleven fields,
// alternating pointer and length except for the auth kind. The buffers are kept
// alive in the returned tuple, because a `Uint8Array` the caller drops could be
// collected while the native side still holds its pointer.
function encodeConfig(options: NetlayerOptions): { struct: Uint8Array; keepAlive: Uint8Array[] } {
	const socks = encoder.encode(options.socks);
	const control = encoder.encode(options.control ?? "");
	const auth = options.auth ?? { kind: "none" };
	const secret = auth.kind === "cookie"
		? auth.cookie
		: auth.kind === "password"
		? encoder.encode(auth.password)
		: new Uint8Array(0);
	const authKind = auth.kind === "cookie" ? AUTH_COOKIE : auth.kind === "password" ? AUTH_PASSWORD : AUTH_NONE;
	const serviceKey = options.serviceKey ?? new Uint8Array(0);
	const forward = encoder.encode(options.forward ?? "");

	// ptr,len ×2, then u32 kind (padded to 8), then ptr,len ×3.
	const struct = new Uint8Array(8 * 11);
	const dv = new DataView(struct.buffer);
	const put = (offset: number, bytes: Uint8Array) => {
		dv.setBigUint64(offset, bytes.length === 0 ? 0n : ffi.pointerOf(bytes), true);
		dv.setBigUint64(offset + 8, BigInt(bytes.length), true);
	};
	put(0, socks);
	put(16, control);
	dv.setUint32(32, authKind, true);
	put(40, secret);
	put(56, serviceKey);
	put(72, forward);

	return { struct, keepAlive: [socks, control, secret, serviceKey, forward] };
}

function openNetlayer(options: NetlayerOptions): Ptr {
	requireOffThreadFfi("onion", "native transport lifecycle");
	const { struct, keepAlive } = encodeConfig(options);
	const out = new Uint8Array(8);
	checkOnion(onionS.pancake_onion_netlayer_new(struct, out));
	void keepAlive;
	return outPointer(out);
}

/** Install one configured onion package into a native driver.
 *
 * Registration retains the package before this function releases only the
 * constructor's reference. It deliberately does not call netlayer shutdown:
 * the driver lease keeps the callback runtime live until driver teardown. */
export async function installProvider(loop: ProviderTarget, options: NetlayerOptions): Promise<void> {
	const raw = openNetlayer(options);
	try {
		const packageBytes = new Uint8Array(TRANSPORT_PROVIDER_SIZE);
		checkOnion(onionS.pancake_onion_transport_provider(raw, packageBytes));
		loop.installProvider((register) => register(packageBytes));
	} finally {
		await new NativeDiagnostic("onion").check(
			"netlayer release",
			(error, cap, errorLen) => onionS.pancake_onion_netlayer_release(raw, error, cap, errorLen),
		);
	}
}

/** Configure one native onion provider package for generic `connect`. */
export function provider(options: NetlayerOptions): DriverProvider {
	return {
		install(loop) {
			return installProvider(loop, options);
		},
	};
}

/** A driver-owned onion service. The generic listener owns admission and CapTP
 * sessions; only this transport package interprets its restoration bytes as a
 * Tor service key. */
export class OnionServer extends DriverServer {
	readonly #serviceKey: Uint8Array;

	constructor(listener: DriverListener, ownedLoop?: DriverLoop) {
		let serviceKey: Uint8Array;
		try {
			serviceKey = listener.restorationState();
		} catch (error) {
			listener.close();
			throw error;
		}
		super({ listener, ownedLoop });
		this.#serviceKey = serviceKey;
	}

	get serviceKey(): Uint8Array {
		return this.#serviceKey.slice();
	}
}

/** Host CapTP on a Tor onion service through the generic native driver.
 * Tor's control exchange and constructor-release barrier complete before this returns. */
export async function listen(options: NetlayerOptions, host?: Host): Promise<OnionServer> {
	const existingLoop = host?.driverLoop;
	const loop = existingLoop == null
		? host == null ? DriverLoop.open() : DriverLoop.takeHost(host)
		: existingLoop as DriverLoop;
	let listener: DriverListener | null = null;
	try {
		await installProvider(loop, options);
		listener = await DriverListener.open(loop, TRANSPORT_ONION, "", options.signal);
		listener.select();
		const server = new OnionServer(listener, host == null ? loop : undefined);
		listener = null;
		return server;
	} catch (error) {
		const cleanups: Array<() => void | Promise<void>> = [];
		const failedListener = listener;
		if (failedListener != null) cleanups.push(() => failedListener.close());
		if (host == null) cleanups.push(() => loop.close());
		await retainCleanupFailures(error, cleanups);
		throw error;
	}
}

/** A blocking onion connection: the `pancake_onion_*` frame shuttle over one
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
			(p) => checkOnion(onionS.pancake_onion_conn_shutdown(p)),
			async (p) => {
				try {
					await checkDiagnosedCall(
						"onion",
						"connection release",
						(error, cap, errorLen) => onionS.pancake_onion_conn_release(p, error, cap, errorLen),
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
	/** Wait for one whole frame. Throws PANCAKE_ERR_CLOSED on clean EOF.
	 *
	 * The native operation may wait for the rest of a fragmented frame even after
	 * `readinessFd()` reports readable. Deno dispatches this blocking FFI call away
	 * from its event loop; Bun's FFI is synchronous, so Bun callers must keep this
	 * off their event-loop thread. */
	readFrame(): Promise<Uint8Array> {
		requireOffThreadFfi("onion", "readFrame");
		return this.#reads.run(() =>
			this.#native.use(async (raw) => {
				const mf = new Uint8Array(MANAGED_FRAME_SIZE);
				try {
					await this.#readDiagnostic.check("read frame", (error, cap, errorLen) =>
						onionS.pancake_onion_conn_read_frame(
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
	/** The descriptor this connection's bytes flow over, for a loop that polls
	 * rather than blocks. Owned by the connection: do not close it, and do not use
	 * it after `close`. */
	readinessFd(): number {
		const out = new Uint8Array(4);
		checkOnion(onionS.pancake_onion_conn_readiness_fd(this.#native.borrow(), out));
		return new DataView(out.buffer).getInt32(0, true);
	}
	writeFrame(frame: Uint8Array): Promise<void> {
		requireOffThreadFfi("onion", "writeFrame");
		return this.#writes.run(frame, (owned) =>
			this.#native.use(async (raw) => {
				await this.#writeDiagnostic.check("write frame", (error, cap, errorLen) =>
					onionS.pancake_onion_conn_write_frame(
						raw,
						owned.argument(),
						error,
						cap,
						errorLen,
					));
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
			(p) => onionS.pancake_onion_listener_shutdown(p),
			async (p) => {
				try {
					await this.#releaseDiagnostic.check(
						"listener release",
						(error, cap, errorLen) => onionS.pancake_onion_listener_release(p, error, cap, errorLen),
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
					onionS.pancake_onion_accept(
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
	/** The descriptor this listener's circuits arrive on, for a loop that polls
	 * rather than blocks.
	 *
	 * This is what keeps an event-driven consumer off the blocking path: wrap it in
	 * a socket your runtime can await, and call `accept` only once it is readable.
	 * Owned by the listener: do not close it, and do not use it after `close`. */
	readinessFd(): number {
		const out = new Uint8Array(4);
		checkOnion(onionS.pancake_onion_listener_readiness_fd(this.#native.borrow(), out));
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
					onionS.pancake_onion_listener_wait(
						raw,
						timeoutMs,
						out,
						error,
						cap,
						errorLen,
					));
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
			(p) => onionS.pancake_onion_netlayer_shutdown(p),
			(p) =>
				new NativeDiagnostic("onion").check(
					"netlayer release",
					(error, cap, errorLen) => onionS.pancake_onion_netlayer_release(p, error, cap, errorLen),
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
					onionS.pancake_onion_listen(
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
			const d = encoder.encode(serviceId);
			const out = new Uint8Array(8);
			await checkDiagnosedCall(
				"onion",
				"connect",
				(error, cap, errorLen) =>
					onionS.pancake_onion_connect(
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

/** This package's one profile, in its own words (`ProfileInfo`). */
export const profiles = [
	{
		transport: "onion",
		summary: "A Tor onion service, published through a running Tor.",
		reference: "https://community.torproject.org/onion-services/",
		referenceName: "onion services",
		takes: [],
	},
] as const satisfies readonly import("@pancake/runtime/transport").ProfileInfo[];
