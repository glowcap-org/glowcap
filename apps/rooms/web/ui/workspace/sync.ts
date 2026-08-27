// Explicit checkpoint replacement across tabs of the same browser profile.

const source = crypto.randomUUID();
const channel = typeof BroadcastChannel === "undefined" ? null : new BroadcastChannel("pancake-rooms-state");

channel?.addEventListener("message", (event) => {
	const message: unknown = event.data;
	if (typeof message !== "object" || message === null) return;
	const row = message as Record<string, unknown>;
	if (row.source === source || row.kind !== "replace") return;
	location.reload();
});

export function announceWorkspaceReplacement(): void {
	channel?.postMessage({ source, kind: "replace" });
}
