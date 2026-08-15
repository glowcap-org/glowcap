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
// `@pancake/runtime/transport`; applications import `@pancake/runtime`.
export { abortable } from "./internal/cancellation.ts";
export * from "./internal/constants.ts";
export { ensureRuntimeReady, ffi, type Ptr } from "./internal/ffi/runtime.ts";
export { outPointer, readBytes, readErrorSlot, releaseManagedFrame } from "./internal/seam.ts";
export { DriverServer } from "./internal/server.ts";
export { DriverListener, DriverLoop, loopTierAvailable, type ProviderTarget } from "./driver_loop.ts";
export { PancakeError, retainCleanupFailures } from "./errors.ts";
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
export { NativeHandle, NativeParent, requireOffThreadFfi, SingleFlight } from "./transport/native_handle.ts";
export { AsyncFfiWriteQueue, checkedMaxFrameBytes } from "./transport/native_frame.ts";
export { checkDiagnosedCall, NativeDiagnostic } from "./transport/diagnostic.ts";
