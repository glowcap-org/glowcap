import type { DriverLoop } from "./driver_loop.ts";
import type { Host } from "./host.ts";
import type { Locator } from "./locator.ts";
import type { Session } from "./session.ts";

/** A configured native provider package installed into the generic driver. */
export interface DriverProvider {
	install(loop: DriverLoop): Promise<void>;
}

export interface ConnectorRequest {
	/** True when this dial realizes a transparent handoff redeem. */
	readonly redeem: boolean;
	/** OCapN handshake budget; `null` or `0` waits without a bound. */
	readonly handshakeTimeoutMs: number | null;
	/** Cancels channel establishment and any partial session. */
	readonly signal?: AbortSignal;
	/** Provider-owned bytes borrowed for this operation only. */
	readonly transportOptions?: Uint8Array;
}

/** A transport package's typed, per-operation provider override. */
export interface TransportOperationOptions {
	readonly transports: readonly string[];
	readonly data: Uint8Array;
}

/** One knob a profile's listen accepts, described so an operator surface can
 * offer a field for it without interpreting it. `hint` is what a blank field
 * means, in words ("127.0.0.1", "an ephemeral port"); an application serving
 * the catalog may replace it with its own configured default. */
export interface ListenOption {
	/** The knob's name, e.g. `bind`, `port`, `relay`. */
	readonly name: string;
	/** What shape a value takes: a host name, a port number, a WebSocket URL. */
	readonly kind: "host" | "port" | "url";
	/** What leaving the field blank means, in words. */
	readonly hint: string;
}

/** One wire profile a transport package advertises, described in its own
 * words for an operator surface. The package is the authority on what its
 * profiles give and cost, so an application lists what its composed packages
 * say instead of keeping a copy of the set. */
export interface ProfileInfo {
	/** The locator transport symbol, e.g. `noise-tcp`. */
	readonly transport: string;
	/** What the profile gives and what it costs, one or two sentences. */
	readonly summary: string;
	/** A page that explains the technology, or empty. */
	readonly reference: string;
	/** What the reference explains, as link text ("Noise", "iroh"); empty
	 * exactly when `reference` is. */
	readonly referenceName: string;
	/** The knobs this profile's listen accepts beside the transport. */
	readonly takes: readonly ListenOption[];
}

type Connect = (
	host: Host,
	locator: Locator,
	request: ConnectorRequest,
) => Promise<Session>;

/** Explicit byte-fed transport composition for an embedder-owned channel. */
export class Connector {
	readonly transports: readonly string[];
	readonly #connect: Connect;

	constructor(transports: readonly string[], connect: Connect) {
		if (transports.length === 0) {
			throw new TypeError("a connector must advertise a transport");
		}
		if (new Set(transports).size !== transports.length) {
			throw new TypeError("a connector cannot advertise a transport twice");
		}
		this.transports = Object.freeze([...transports]);
		this.#connect = connect;
	}

	supports(transport: string): boolean {
		return this.transports.includes(transport);
	}

	connect(host: Host, locator: Locator, request: ConnectorRequest): Promise<Session> {
		return this.#connect(host, locator, request);
	}
}

// Transport-package authoring surface. Keeping it here makes the module name,
// public subpath, and concept agree: companions import
// `@glowcap/runtime/transport`; applications import `@glowcap/runtime`.
export { abortable } from "./internal/cancellation.ts";
export { recordProcessBindingFailure } from "./context.ts";
export * from "./internal/constants.ts";
export { ensureRuntimeReady, ffi, type Ptr } from "./internal/ffi/runtime.ts";
// Read-only layout authority for companion packages that marshal structs from
// their own native archive. Selection remains runtime-owned; companions can
// inspect and use the active target layout but cannot replace it.
export { L as abiLayout } from "./internal/layout.ts";
export { outPointer, readBytes, readErrorSlot, releaseManagedFrame } from "./internal/seam.ts";
export { DriverServer, listenerLoopUnavailable, prepareListenerLoop } from "./internal/server.ts";
export { DriverListener, DriverLoop, loopTierAvailable, type ProviderTarget } from "./driver_loop.ts";
export { GlowcapError, retainCleanupFailures, retainSecondaryFailure } from "./errors.ts";
export type { CarrierFailure, CarrierPhase } from "./carrier_failure.ts";
export { Host } from "./host.ts";
export {
	designatorHostPort,
	formatPeerUri,
	HINT_DIRECT_ADDRESSES,
	type Locator,
	stringHint,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_NOISE_TCP,
	TRANSPORT_TCP,
} from "./locator.ts";
export { Session } from "./session.ts";
export { type Codec, codecId } from "./value.ts";
export { openWebSocketChannel } from "./websocket.ts";
export {
	consumedReleaseFailure,
	NativeHandle,
	NativeParent,
	requireOffThreadFfi,
	SingleFlight,
} from "./transport/native_handle.ts";
export { AsyncFfiWriteQueue, checkedMaxFrameBytes } from "./transport/native_frame.ts";
export { checkDiagnosedCall, NativeDiagnostic } from "./transport/diagnostic.ts";
