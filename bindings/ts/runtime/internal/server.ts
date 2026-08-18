// Binding-level projection of one generic native-driver listener. Transport
// modules inherit this lifecycle and add only metadata they alone understand.

import { DriverListener, DriverLoop } from "../driver_loop.ts";
import { PancakeError } from "../errors.ts";
import { Host } from "../host.ts";
import { formatLocatorUri, type Locator } from "../locator.ts";
import { Session } from "../session.ts";
import type { Codec } from "../value.ts";
import { INVALID_ARGUMENT } from "@pancake/abi";

/** Shared lifecycle for a driver-owned CapTP server. */
export class DriverServer {
	readonly #listener: DriverListener;
	readonly #ownedLoop: DriverLoop | null;
	#closePromise: Promise<void> | null = null;
	#admissionClosed = false;

	constructor(bound: { listener: DriverListener; ownedLoop?: DriverLoop }) {
		this.#listener = bound.listener;
		this.#ownedLoop = bound.ownedLoop ?? null;
	}

	protected get driverListener(): DriverListener {
		return this.#listener;
	}

	/** The complete canonical locator currently advertised by the driver. */
	get locator(): Locator {
		return this.driverListener.locator();
	}

	/** The canonical URI currently advertised by the driver. */
	get uri(): string {
		return formatLocatorUri(this.locator);
	}

	/** The locator designator currently advertised by the driver. */
	get designator(): string {
		return this.locator.designator;
	}

	get host(): Host {
		return this.driverListener.host;
	}

	/** Select this listener's locator as the Host's acceptable location.
	 *
	 * A Host may retain several live listeners, but exactly one location is
	 * signed into new sessions. Closing the selected listener deliberately does
	 * not guess which sibling should replace it; the process owner chooses by
	 * calling this method on the remaining server. */
	select(): void {
		this.driverListener.select();
	}

	async *[Symbol.asyncIterator](): AsyncGenerator<Session> {
		try {
			while (true) {
				const session = await this.#listener.accept();
				if (session == null) return;
				yield session;
			}
		} finally {
			await this.stopAdmission();
			// Yielded sessions may still be live after iterator close. Request
			// retirement now; the last session completes it without making iterator
			// completion wait on its own consumer.
			if (this.#ownedLoop != null) {
				void this.#ownedLoop.requestClose();
			}
		}
	}

	stopAdmission(): Promise<void> {
		if (this.#admissionClosed) return Promise.resolve();
		this.#admissionClosed = true;
		try {
			this.#listener.close();
			return Promise.resolve();
		} catch (error) {
			return Promise.reject(error);
		}
	}

	/** Stop admission. A server that minted its own loop requests that loop's
	 * retirement without waiting for sessions already returned to the
	 * application. Native release continues in the loop's close task. */
	close(): Promise<void> {
		if (this.#closePromise != null) return this.#closePromise;
		this.#closePromise = (async () => {
			await this.stopAdmission();
			if (this.#ownedLoop != null) {
				void this.#ownedLoop.requestClose();
			}
		})();
		return this.#closePromise;
	}

	async [Symbol.asyncDispose](): Promise<void> {
		await this.close();
	}
}

/** The refusal every native listener surface shares when this runtime cannot
 * park the loop between steps. */
export function listenerLoopUnavailable(): PancakeError {
	return new PancakeError(
		INVALID_ARGUMENT,
		"native driver listeners require a runtime that can park the loop",
	);
}

/** Resolve the loop a native listener binds through: the supplied Host's own
 * loop (adopting the Host on first use, so its identity, publications, and
 * handoff router carry), or a fresh owned loop minted with `seed`/`codec`.
 * `ownsLoop` says whether closing the listener's server should close the
 * loop with it. Shared by every provider package's `listen`, so they cannot
 * disagree about how a Host meets the driver. */
export function prepareListenerLoop(
	host: Host | undefined,
	seed: Uint8Array | undefined,
	codec: Codec | undefined,
): { loop: DriverLoop; ownsLoop: boolean } {
	if (host != null) {
		if (codec != null && codec !== host.codec) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				`codec "${codec}" conflicts with the host's "${host.codec}"; mint the host with it instead`,
			);
		}
		if (seed != null) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"seed and host are alternative identity sources",
			);
		}
		return {
			loop: host.driverLoop != null ? host.driverLoop as DriverLoop : DriverLoop.takeHost(host),
			ownsLoop: false,
		};
	}
	return { loop: DriverLoop.open({ seed, codec }), ownsLoop: true };
}
