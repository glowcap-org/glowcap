// Cross-tab invalidation for state changed through a held operations capability.

import type { RoomsPageContext } from "../page.ts";

type Watcher = (scope: string) => void | Promise<void>;

const CHANNEL = "glowcap-rooms-operations";

/** Watchers and a BroadcastChannel identity for one browser page. The channel
 * name is isolate-wide so other tabs still hear a committed mutation. */
export class PageOpsInvalidation {
	readonly watchers = new Set<Watcher>();
	readonly source = crypto.randomUUID();
	readonly #channel: BroadcastChannel | null;

	constructor() {
		this.#channel = typeof BroadcastChannel === "undefined" ? null : new BroadcastChannel(CHANNEL);
		this.#channel?.addEventListener("message", (event) => {
			const message: unknown = event.data;
			if (typeof message !== "object" || message === null) return;
			const row = message as Record<string, unknown>;
			if (row.source === this.source || typeof row.scope !== "string") return;
			void notify(this, row.scope);
		});
	}

	post(scope: string): void {
		this.#channel?.postMessage({ source: this.source, scope });
	}
}

async function notify(invalidation: PageOpsInvalidation, scope: string): Promise<void> {
	await Promise.all([...invalidation.watchers].map((watcher) => watcher(scope)));
}

export function onOperationsInvalidated(page: RoomsPageContext, watcher: Watcher): () => void {
	page.opsInvalidation.watchers.add(watcher);
	return () => page.opsInvalidation.watchers.delete(watcher);
}

/** Refresh this tab before announcing the committed server mutation to peers. */
export async function invalidateOperations(page: RoomsPageContext, scope: string): Promise<void> {
	await notify(page.opsInvalidation, scope);
	page.opsInvalidation.post(scope);
}
