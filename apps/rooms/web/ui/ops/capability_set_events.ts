// One invalidation path for the saved operations capability set.

type Watcher = () => void | Promise<void>;

const watchers = new Set<Watcher>();
const source = crypto.randomUUID();
const channel = typeof BroadcastChannel === "undefined" ? null : new BroadcastChannel("pancake-rooms-capability-set");

async function notify(): Promise<void> {
	await Promise.all([...watchers].map((watcher) => watcher()));
}

channel?.addEventListener("message", (event) => {
	const message: unknown = event.data;
	if (typeof message !== "object" || message === null) return;
	const row = message as Record<string, unknown>;
	if (row.source === source || row.kind !== "changed") return;
	void notify();
});

export function onCapabilitySetChanged(watcher: Watcher): () => void {
	watchers.add(watcher);
	return () => watchers.delete(watcher);
}

/** A session checkpoint already reached this view, so refresh local readers. */
export function noteCapabilitySetChanged(): Promise<void> {
	return notify();
}

/** A local controller committed here, so sibling tabs need to refresh. */
export function broadcastCapabilitySetChanged(): void {
	channel?.postMessage({ source, kind: "changed" });
}
