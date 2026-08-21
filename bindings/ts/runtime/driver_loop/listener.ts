// One generic native-driver listener owner. Transport packages wrap this
// object only to project their own locator metadata.

import { CLOSED } from "@pancake/abi";
import { PancakeError } from "../errors.ts";
import type { Host } from "../host.ts";
import type { Locator } from "../locator.ts";
import type { Session } from "../session.ts";

export interface ListenerLoop {
	wrapperHost(): Host;
	listen(
		transport: string,
		designator: string,
		signal?: AbortSignal,
	): Promise<bigint>;
	listenerLocator(listener: bigint): Locator;
	listenerRestorationState(listener: bigint): Uint8Array;
	advertiseListener(listener: bigint, locator: Locator | string): void;
	selectListener(listener: bigint): void;
	acceptSession(listener: bigint): Promise<Session | null>;
	closeListener(listener: bigint): void;
}

function closedError(): PancakeError {
	return new PancakeError(CLOSED, "the loop is closed");
}

export class DriverListener {
	readonly #loop: ListenerLoop;
	readonly #listener: bigint;
	readonly #host: Host;
	#closed = false;

	private constructor(loop: ListenerLoop, listener: bigint) {
		this.#loop = loop;
		this.#listener = listener;
		this.#host = loop.wrapperHost();
	}

	static async open(
		loop: ListenerLoop,
		transport: string,
		designator: string,
		signal?: AbortSignal,
	): Promise<DriverListener> {
		return new DriverListener(loop, await loop.listen(transport, designator, signal));
	}

	get host(): Host {
		return this.#host;
	}

	locator(): Locator {
		if (this.#closed) throw closedError();
		return this.#loop.listenerLocator(this.#listener);
	}

	restorationState(): Uint8Array {
		if (this.#closed) throw closedError();
		return this.#loop.listenerRestorationState(this.#listener);
	}

	advertise(locator: Locator | string): void {
		if (this.#closed) throw closedError();
		this.#loop.advertiseListener(this.#listener, locator);
	}

	select(): void {
		if (this.#closed) throw closedError();
		this.#loop.selectListener(this.#listener);
	}

	accept(): Promise<Session | null> {
		return this.#closed ? Promise.resolve(null) : this.#loop.acceptSession(this.#listener);
	}

	/** Seal admission while preserving the Host, sibling listeners, and
	 * sessions already transferred to the application. */
	close(): void {
		if (this.#closed) return;
		this.#loop.closeListener(this.#listener);
		this.#closed = true;
	}
}
