// One instance-owned invalidation path for a saved operations capability set.

type Watcher = () => void | Promise<void>;

export interface CapabilitySetEventSource {
	watch(watcher: Watcher): () => void;
	note(): Promise<void>;
	broadcast(): void;
	close(): void;
}

/** A rendered Rooms application owns this coordinator and its cross-tab
 * channel. No listener, channel, or source identity outlives that application. */
export class CapabilitySetEvents implements CapabilitySetEventSource {
	readonly #watchers = new Set<Watcher>();
	readonly #source = crypto.randomUUID();
	readonly #channel: BroadcastChannel | null;
	readonly #receive = (event: MessageEvent) => {
		const message: unknown = event.data;
		if (typeof message !== "object" || message === null) return;
		const row = message as Record<string, unknown>;
		if (row.source === this.#source || row.kind !== "changed") return;
		void this.note();
	};

	constructor() {
		this.#channel = typeof BroadcastChannel === "undefined"
			? null
			: new BroadcastChannel("pancake-rooms-capability-set");
		this.#channel?.addEventListener("message", this.#receive);
	}

	watch(watcher: Watcher): () => void {
		this.#watchers.add(watcher);
		return () => this.#watchers.delete(watcher);
	}

	async note(): Promise<void> {
		await Promise.all([...this.#watchers].map((watcher) => watcher()));
	}

	broadcast(): void {
		this.#channel?.postMessage({ source: this.#source, kind: "changed" });
	}

	close(): void {
		this.#watchers.clear();
		this.#channel?.removeEventListener("message", this.#receive);
		this.#channel?.close();
	}
}
