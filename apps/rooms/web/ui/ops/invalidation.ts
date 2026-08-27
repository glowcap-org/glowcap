// Cross-tab invalidation for state changed through a held operations capability.

type Watcher = (scope: string) => void | Promise<void>;

const watchers = new Set<Watcher>();
const source = crypto.randomUUID();
const channel = typeof BroadcastChannel === "undefined" ? null : new BroadcastChannel("pancake-rooms-operations");

async function notify(scope: string): Promise<void> {
	await Promise.all([...watchers].map((watcher) => watcher(scope)));
}

channel?.addEventListener("message", (event) => {
	const message: unknown = event.data;
	if (typeof message !== "object" || message === null) return;
	const row = message as Record<string, unknown>;
	if (row.source === source || typeof row.scope !== "string") return;
	void notify(row.scope);
});

export function onOperationsInvalidated(watcher: Watcher): () => void {
	watchers.add(watcher);
	return () => watchers.delete(watcher);
}

/** Refresh this tab before announcing the committed server mutation to peers. */
export async function invalidateOperations(scope: string): Promise<void> {
	await notify(scope);
	channel?.postMessage({ source, scope });
}
