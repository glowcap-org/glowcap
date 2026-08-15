// Binding-level projection of one generic native-driver listener. Transport
// modules inherit this lifecycle and add only metadata they alone understand.

import { DriverListener, DriverLoop } from "../driver_loop.ts";
import { Host } from "../host.ts";
import { formatLocatorUri, type Locator } from "../locator.ts";
import { Session } from "../session.ts";

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
