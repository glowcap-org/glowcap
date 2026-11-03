import { DESIGNATOR_SCHEME_ADDRESS, DESIGNATOR_SCHEME_KEY } from "@glowcap/abi";
import type { GlowcapError } from "../errors.ts";
import type { Ptr } from "../internal/ffi/runtime.ts";
import type { CloseOptions } from "../lifecycle.ts";
import type { Session } from "../session.ts";

/** How transport packets move for one connection. It is the seam the byte-fed pump
 * reads and the FLUSH drain writes. The core supplies the TCP wrapper below
 * over the runtime's own sockets; the `@glowcap/iroh` companion supplies the
 * iroh one, so the iroh artifact stays out of this core module entirely.
 * Framing is never the channel's job: the Host transport profile owns whether
 * reads are byte-stream chunks or whole message frames. */
export interface Channel {
	/** The next inbound transport packet, or `null` at a clean end of stream. */
	read(): Promise<Uint8Array | null>;
	/** Write every byte of `data`, awaiting the runtime's flush/backpressure. */
	write(data: Uint8Array): Promise<void>;
	/** Stop I/O immediately. A returned promise is the FFI release barrier. */
	close(): void | Promise<void>;
}

/** Generic metadata an embedder-owned listener supplies with one accepted byte
 * channel. The provider, not the binding core, declares how its designator is
 * interpreted; adding a transport therefore adds no name dispatch here. */
export interface AcceptedTransport {
	readonly transport: string;
	readonly designatorScheme:
		| typeof DESIGNATOR_SCHEME_ADDRESS
		| typeof DESIGNATOR_SCHEME_KEY;
	readonly serverDesignator: string;
	readonly channel: Channel;
	readonly localAddress?: string;
	/** The partner key the transport itself authenticated, or `null` when the
	 * transport carries no channel proof. Stated by every provider. */
	readonly verifiedChannelKey: string | null;
}

/** What a loop-minted `Session` needs from the driver loop that owns it
 * (ADR-0024). Declared here and implemented by `driver_loop.ts`'s `DriverLoop`,
 * so the Session arms can dispatch on it without importing the loop tier. */
export interface DriverLoopHandle {
	/** One zero-timeout step plus an event dispatch, on the driving thread. */
	stepNow(): void;
	/** Schedule one step soon: a kick that is legal from inside a turn. */
	scheduleStep(): void;
	/** Schedule one deferred step and join its complete effect drain. */
	settleStep(): Promise<void>;
	/** Release one loop-owned session through the loop's own verb. */
	ffiSessionRelease(ptr: Ptr): void;
	/** Start delivering one loop-owned session's inbound: setup is done. */
	serveSession(ptr: Ptr): void;
	/** Resolve and claim the exporter session for a Host capability. */
	claimReferenceExporter(reference: Uint8Array): Ptr | null;
	/** Close one loop-owned session through the loop's FFI barrier. */
	closeSession(ptr: Ptr, options?: CloseOptions): Promise<void>;
	/** Release the loop and everything it owns, to the FFI barrier. */
	close(options?: CloseOptions): Promise<void>;
	/** Wrap a loop-minted session handle as the public `Session`. */
	adoptSession(ptr: Ptr): Session;
}

/** The loop-backed `Channel` (ADR-0024): the driver loop owns the wire, so it
 * carries no byte verbs the pump would drive. It has only the closed event the serve
 * promise awaits and the loop back-reference the Session arms dispatch on. */
export interface LoopChannel extends Channel {
	readonly driverLoop: DriverLoopHandle;
	waitClosed(): Promise<void>;
	/** Settle the loop-backed serve boundary from the FFI SESSION_CLOSED
	 * event before generic transport retirement runs. */
	finishClosed(error: GlowcapError | null): void;
}
