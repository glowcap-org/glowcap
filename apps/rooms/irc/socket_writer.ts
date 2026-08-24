// Bounded, serialized IRC socket output shared by listener-side sessions.
// A slow client is an edge resource, not permission to retain an unbounded
// promise chain of room traffic. Admission is synchronous; one pump owns the
// socket and retires every waiter on the first write failure.

import { encodeIrcMessage } from "./protocol.ts";

export const IRC_WRITE_QUEUE_LINES = 64;
export const IRC_WRITE_QUEUE_BYTES = 32 * 1024;

interface PendingWrite {
	readonly bytes: Uint8Array;
	readonly resolve: () => void;
	readonly reject: (error: Error) => void;
}

export class IrcSocketWriter {
	readonly #conn: Deno.Conn;
	readonly #onFailure: (error: Error) => void;
	readonly #queue: PendingWrite[] = [];
	#queuedBytes = 0;
	#pumping = false;
	#failure: Error | null = null;

	constructor(conn: Deno.Conn, onFailure: (error: Error) => void) {
		this.#conn = conn;
		this.#onFailure = onFailure;
	}

	get queuedLines(): number {
		return this.#queue.length;
	}

	get queuedBytes(): number {
		return this.#queuedBytes;
	}

	send(command: string, params: readonly string[] = [], prefix?: string): Promise<void> {
		return this.write(encodeIrcMessage(command, params, prefix));
	}

	write(bytes: Uint8Array): Promise<void> {
		if (this.#failure !== null) return Promise.reject(this.#failure);
		if (
			this.#queue.length >= IRC_WRITE_QUEUE_LINES ||
			this.#queuedBytes + bytes.length > IRC_WRITE_QUEUE_BYTES
		) {
			const error = new Error("IRC client output queue is full");
			this.fail(error);
			return Promise.reject(error);
		}
		const result = new Promise<void>((resolve, reject) => {
			this.#queue.push({ bytes, resolve, reject });
			this.#queuedBytes += bytes.length;
		});
		if (!this.#pumping) void this.#pump();
		return result;
	}

	fail(error: Error): void {
		if (this.#failure !== null) return;
		this.#failure = error;
		for (const pending of this.#queue.splice(0)) pending.reject(error);
		this.#queuedBytes = 0;
		this.#onFailure(error);
	}

	async #pump(): Promise<void> {
		this.#pumping = true;
		try {
			while (this.#failure === null) {
				const pending = this.#queue[0];
				if (pending === undefined) break;
				let offset = 0;
				while (offset < pending.bytes.length) {
					const wrote = await this.#conn.write(pending.bytes.subarray(offset));
					if (wrote === 0) throw new Error("IRC connection accepted a zero-byte write");
					offset += wrote;
				}
				if (this.#failure !== null || this.#queue[0] !== pending) break;
				this.#queue.shift();
				this.#queuedBytes -= pending.bytes.length;
				pending.resolve();
			}
		} catch (error) {
			this.fail(error instanceof Error ? error : new Error(String(error)));
		} finally {
			this.#pumping = false;
		}
	}
}
