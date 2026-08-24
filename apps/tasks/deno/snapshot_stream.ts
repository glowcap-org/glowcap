/** A bounded latest-value stream. A full snapshot makes the retained value a
 * resync, so intermediate optional updates may be discarded safely. */
export class LatestSnapshotStream<T> {
	readonly readable: ReadableStream<T>;
	#controller: ReadableStreamDefaultController<T> | null = null;
	#pending: T | null = null;
	#closed = false;

	constructor() {
		this.readable = new ReadableStream<T>({
			start: (controller) => {
				this.#controller = controller;
			},
			pull: () => this.#flush(),
			cancel: () => {
				this.#closed = true;
				this.#pending = null;
			},
		});
	}

	push(value: T): void {
		if (this.#closed) return;
		const controller = this.#controller;
		if (controller === null) return;
		if (this.#pending === null && controller.desiredSize !== null && controller.desiredSize > 0) {
			try {
				controller.enqueue(value);
			} catch {
				this.#closed = true;
			}
			return;
		}
		this.#pending = value;
		this.#flush();
	}

	close(): void {
		if (this.#closed) return;
		this.#closed = true;
		this.#pending = null;
		try {
			this.#controller?.close();
		} catch {
			// The consumer already cancelled or closed the stream.
		}
	}

	#flush(): void {
		const controller = this.#controller;
		if (this.#closed || this.#pending === null || controller === null) return;
		if (controller.desiredSize === null || controller.desiredSize <= 0) return;
		const value = this.#pending;
		this.#pending = null;
		try {
			controller.enqueue(value);
		} catch {
			this.#closed = true;
			this.#pending = null;
		}
	}
}
