import { connectionChanges, offlineMember } from "../../../lib/text/admission.ts";
// Presentation may summarize connection churn. Membership truth is reduced by
// the parent before this owner sees the notice. No timer changes authority.
import { MAX_ROSTER_SEEN } from "../../../lib/limits.ts";
import type { Presence } from "../../../lib/room/presence.ts";

/** How long connection churn for one member folds into one notice. */
export const PRESENCE_WINDOW_MS = 5000;

interface Notice {
	readonly id: number;
	readonly started: number;
	readonly changes: number;
}
export class PresenceNarration {
	readonly #notices = new Map<string, Notice>();
	constructor(readonly windowMs = PRESENCE_WINDOW_MS) {}
	present(
		conversation: string,
		presence: Presence | undefined,
		text: string,
		now: number,
		append: (text: string) => number,
		update: (id: number, text: string) => boolean,
	): void {
		if (presence?.kind === "leave") {
			this.#notices.delete(JSON.stringify([conversation, presence.name]));
		}
		const names = presence?.kind === "join" ? [presence.name] : presence?.kind === "offline" ? presence.names : [];
		if (names.length === 0) {
			append(text);
			return;
		}
		for (const name of names) {
			const key = JSON.stringify([conversation, name]);
			const prior = this.#notices.get(key);
			const online = presence?.kind === "join";
			if (
				prior != null && now >= prior.started && now - prior.started < this.windowMs &&
				update(prior.id, connectionChanges(name, prior.changes + 1, online))
			) {
				this.#notices.set(key, { ...prior, changes: prior.changes + 1 });
				continue;
			}
			if (!this.#notices.has(key) && this.#notices.size >= MAX_ROSTER_SEEN) {
				this.#notices.delete(this.#notices.keys().next().value!);
			}
			const id = append(names.length === 1 ? text : offlineMember(name));
			this.#notices.set(key, { id, started: now, changes: 1 });
		}
	}
}
