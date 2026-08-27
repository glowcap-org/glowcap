// Bounded single-consumer delivery for capability-bearing room messages.

import type { Message } from "./room_message.ts";
import { MAX_ROOM_MESSAGE_BACKLOG } from "./limits.ts";

/** Keep unread messages outside the platform stream queue so cancellation can
 * release their capability occurrences. A zero high-water mark means enqueue
 * only satisfies an outstanding read; the explicit queue owns everything else. */
export class RoomMessageStream {
	readonly #drop: (message: Message) => void;
	readonly #queue: Array<Message | undefined> = [];
	readonly #controller: ReadableStreamDefaultController<Message>;
	#head = 0;
	#wake: (() => void) | null = null;
	#closed = false;
	readonly readable: ReadableStream<Message>;

	constructor(drop: (message: Message) => void) {
		this.#drop = drop;
		let controller!: ReadableStreamDefaultController<Message>;
		this.readable = new ReadableStream<Message>({
			start: (started) => controller = started,
			pull: () => this.#pull(),
			cancel: () => this.#retire(),
		}, { highWaterMark: 0 });
		this.#controller = controller;
	}

	push(message: Message): void {
		if (this.#closed) {
			this.#drop(message);
			return;
		}
		const wake = this.#wake;
		if (wake != null) {
			this.#wake = null;
			this.#controller.enqueue(message);
			wake();
			return;
		}
		if (this.#head > 0 && this.#queue.length >= MAX_ROOM_MESSAGE_BACKLOG) {
			this.#queue.splice(0, this.#head);
			this.#head = 0;
		}
		if (this.#queue.length - this.#head === MAX_ROOM_MESSAGE_BACKLOG) {
			this.#queue.push(message);
			this.#fail(new Error(`room message backlog exceeded ${MAX_ROOM_MESSAGE_BACKLOG} lines`));
			return;
		}
		this.#queue.push(message);
	}

	close(): void {
		if (this.#closed) return;
		this.#retire();
		this.#controller.close();
	}

	#pull(): void | Promise<void> {
		const message = this.#queue[this.#head];
		if (message != null) {
			this.#queue[this.#head] = undefined;
			this.#head += 1;
			if (this.#head === this.#queue.length) {
				this.#queue.length = 0;
				this.#head = 0;
			}
			this.#controller.enqueue(message);
			return;
		}
		if (this.#closed) return;
		const waiting = Promise.withResolvers<void>();
		this.#wake = waiting.resolve;
		return waiting.promise;
	}

	#fail(error: Error): void {
		if (this.#closed) return;
		this.#retire();
		this.#controller.error(error);
	}

	#retire(): void {
		if (this.#closed) return;
		this.#closed = true;
		for (let at = this.#head; at < this.#queue.length; at += 1) {
			const message = this.#queue[at];
			if (message != null) this.#drop(message);
		}
		this.#queue.length = 0;
		this.#head = 0;
		const wake = this.#wake;
		this.#wake = null;
		wake?.();
	}
}
