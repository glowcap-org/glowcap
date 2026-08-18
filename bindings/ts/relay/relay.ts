// @pancake/relay: the byte-transparent relay core. Forward bytes between a
// source/sink pair and a RelayChannel without parsing them, so a keyed CapTP
// session rides through end to end and the relay never holds a capability. This
// is a first-class pancake capability, not app code: an embedder hosting peers
// that cannot open a socket themselves (a browser) runs a relay built from these
// pieces, and the app on top adds only policy — which targets may be dialed.
//
// Transport adapters implement ByteSource/ByteSink and RelayChannel and call
// relayBytes(). Backpressure is the awaited write: a leg reads its next chunk
// only after the previous write settled, so a leg whose sink actually blocks
// propagates its partner's flow control. The WebSocket sink in `ws_relay.ts`
// blocks by gating on `bufferedAmount`; a raw-socket RelayChannel blocks on the
// kernel write. A sink that cannot block (a fire-and-forget send) has no
// backpressure and must be bounded some other way.

import { retainSecondaryFailure } from "@pancake/runtime/transport";

/** A byte source: yields chunks to relay. `read` resolves null on EOF. */
export interface ByteSource {
	read(): Promise<Uint8Array | null>;
}

/** A byte sink: accepts chunks from the relay. `write` throws on error. */
export interface ByteSink {
	write(chunk: Uint8Array): Promise<void>;
}

/** A bidirectional byte channel (the relay's far side, e.g. a TCP or iroh
 * connection). `read` resolves null on EOF; `close` is idempotent. */
export interface RelayChannel {
	read(): Promise<Uint8Array | null>;
	write(chunk: Uint8Array): Promise<void>;
	/** Request closure and join the channel's release barrier. */
	close(): Promise<void>;
}

/** Per-session relay limits. */
export interface RelayConfig {
	/** Idle timeout in milliseconds; 0 disables it. */
	idleTimeoutMs: number;
	/** Maximum bytes relayed per session (both directions); 0 is unlimited.
	 * Instantaneous memory is bounded by the sink's backpressure, so this is a
	 * runaway/abuse backstop over the session's life, not a memory bound. */
	maxBytesPerSession: number;
}

/**
 * Relay bytes between `source`/`sink` and `channel` in both directions until
 * either leg ends (EOF, error, byte cap, or idle timeout).
 *
 * Teardown is pair-atomic: whichever leg ends first, both sides are closed —
 * the channel via `channel.close()` and the source via `closeSource` (the
 * caller's closure over its own transport, e.g. closing the WebSocket) — so
 * the other leg's pending read settles and the session never half-closes.
 * The idle timeout runs the same teardown. Both closes are idempotent here;
 * the caller does not need to close anything again after this settles. EOF,
 * the byte cap, and the idle timeout resolve normally; an I/O or teardown
 * failure rejects with the exact first cause after both legs have stopped.
 */
export async function relayBytes(
	source: ByteSource,
	sink: ByteSink,
	channel: RelayChannel,
	config: RelayConfig,
	closeSource: () => Promise<void>,
): Promise<void> {
	let bytesTransferred = 0;
	let timeoutHandle: number | null = null;
	let teardownBarrier: Promise<void> | null = null;
	const failures: unknown[] = [];

	const retainFailure = (error: unknown) => {
		failures.push(error);
	};

	const teardown = (): Promise<void> => {
		if (teardownBarrier != null) return teardownBarrier;
		// Publish teardown before invoking either close: a synchronous close may
		// settle the sibling leg reentrantly, and that consequence must remain
		// classified as cancellation rather than a second operation failure.
		teardownBarrier = (async () => {
			const outcomes = await Promise.allSettled([
				Promise.resolve().then(() => channel.close()),
				Promise.resolve().then(closeSource),
			]);
			// Record in stable owner order even when the physical closes complete in
			// the opposite order. The operation failure, if any, was retained before
			// teardown started and therefore remains primary.
			for (const outcome of outcomes) {
				if (outcome.status === "rejected") retainFailure(outcome.reason);
			}
		})();
		return teardownBarrier;
	};

	// An inactivity timeout, not a lifetime cap: any chunk in either direction
	// re-arms it. Firing tears both legs down through the shared teardown.
	const resetIdleTimeout = () => {
		if (timeoutHandle !== null) clearTimeout(timeoutHandle);
		if (config.idleTimeoutMs > 0) {
			timeoutHandle = setTimeout(() => void teardown(), config.idleTimeoutMs) as unknown as number;
		}
	};
	resetIdleTimeout();

	const overCap = () => config.maxBytesPerSession > 0 && bytesTransferred > config.maxBytesPerSession;

	const legA = (async () => {
		try {
			while (true) {
				const chunk = await source.read();
				if (chunk === null) break;
				resetIdleTimeout();
				bytesTransferred += chunk.length;
				if (overCap()) break;
				await channel.write(chunk);
			}
		} catch (error) {
			// Teardown deliberately interrupts the sibling's pending read/write. Its
			// resulting transport rejection is cancellation evidence, not a second
			// session failure; only an error observed before teardown owns the result.
			if (teardownBarrier == null) retainFailure(error);
		}
	})();

	const legB = (async () => {
		try {
			while (true) {
				const chunk = await channel.read();
				if (chunk === null) break;
				resetIdleTimeout();
				bytesTransferred += chunk.length;
				if (overCap()) break;
				await sink.write(chunk);
			}
		} catch (error) {
			if (teardownBarrier == null) retainFailure(error);
		}
	})();

	try {
		await Promise.race([legA, legB]);
	} finally {
		if (timeoutHandle !== null) clearTimeout(timeoutHandle);
		await teardown();
		await Promise.allSettled([legA, legB]);
	}
	if (failures.length > 0) {
		let failure = failures[0];
		for (const secondary of failures.slice(1)) {
			failure = retainSecondaryFailure(failure, secondary);
		}
		throw failure;
	}
}
