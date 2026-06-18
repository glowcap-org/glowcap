export type PresenceEvent =
	| { kind: "roster"; names: string[] }
	| { kind: "join"; name: string }
	| { kind: "leave"; name: string };

export function parsePresenceEvent(text: string): PresenceEvent | null {
	const roster = text.match(/ in the room: (.+)$/);
	if (roster) {
		return {
			kind: "roster",
			names: roster[1].split(", ").filter((name) => name.length > 0),
		};
	}

	const joined = text.match(/^(.+) joined \(\d+ here\)$/);
	if (joined) return { kind: "join", name: joined[1] };

	const left = text.match(/^(.+) left \(\d+ here\)$/);
	if (left) return { kind: "leave", name: left[1] };

	return null;
}

export function applyPresenceEvent(
	members: Map<string, boolean>,
	event: PresenceEvent,
): void {
	if (event.kind === "roster") {
		for (const name of members.keys()) members.set(name, false);
		for (const name of event.names) members.set(name, true);
		return;
	}
	members.set(event.name, event.kind === "join");
}
