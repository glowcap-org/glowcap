/** Resource policy for the trace endpoint as one service, not per socket. */
export const MAX_ROWS_PER_PRODUCER = 1024;
export const MAX_REMOTE_PRODUCERS = 64;
export const MAX_REPLAY_ROWS = 4096;
export const MAX_FIELD_BYTES = 4096;
export const MAX_LINE_BYTES = 1 << 20;
export const MAX_SUBSCRIBERS = 64;
export const MAX_SUBSCRIBER_QUEUE = 256;
export const MAX_SUBSCRIBER_QUEUE_BYTES = 8 << 20;

export class ProducerBudget {
	#remoteProducers = 0;
	#replayRows = 0;

	admitRemote(): boolean {
		if (this.#remoteProducers >= MAX_REMOTE_PRODUCERS) return false;
		this.#remoteProducers += 1;
		return true;
	}

	retireRemote(): void {
		if (this.#remoteProducers === 0) throw new Error("producer budget underflow");
		this.#remoteProducers -= 1;
	}

	retainRow(): boolean {
		if (this.#replayRows >= MAX_REPLAY_ROWS) return false;
		this.#replayRows += 1;
		return true;
	}

	retireRow(): void {
		if (this.#replayRows === 0) throw new Error("replay-row budget underflow");
		this.#replayRows -= 1;
	}

	clear(): void {
		this.#remoteProducers = 0;
		this.#replayRows = 0;
	}
}
