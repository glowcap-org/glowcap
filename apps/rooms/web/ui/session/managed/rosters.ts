// Room rosters reduced from session activity.
//
// A page that attaches to a session with history reads what already happened
// one event at a time. Each presence event was true of its own moment, so a
// roster drawn between two of them shows a room as it was hours ago and then
// corrects itself in front of the reader. This owner keeps a roster to itself
// while the page catches up and publishes it once the page has read the last
// event that already happened.
import { applyRoomPresence, type Presence, type RoomMemberState } from "../../../../lib/room/presence.ts";
import * as store from "../../store.ts";
import type { PageProjection } from "../../store/projection.ts";

type Roster = ReadonlyMap<string, RoomMemberState>;

export class ActivityRosters {
	readonly #projection: PageProjection;
	readonly #held = new Map<string, Roster>();
	constructor(projection: PageProjection) {
		this.#projection = projection;
	}
	/** Reduce one presence event into its room's roster. A replayed event
	 * changes only the held roster. */
	apply(key: string, presence: Presence, replayed: boolean): void {
		const roster = applyRoomPresence(this.#held.get(key) ?? store.membersOf(this.#projection, key), presence);
		if (replayed) this.#held.set(key, roster);
		else this.#publish(new Map([[key, roster]]));
	}
	/** The membership that heard this room's roster ended. */
	forget(key: string): void {
		this.#held.delete(key);
	}
	/** The page has read everything that already happened. */
	caughtUp(): void {
		if (this.#held.size === 0) return;
		const held = new Map(this.#held);
		this.#held.clear();
		this.#publish(held);
	}
	#publish(rosters: ReadonlyMap<string, Roster>): void {
		const next = new Map(this.#projection.get().members);
		// A conversation closed while the page caught up has no row to count for.
		for (const [key, roster] of rosters) if (store.getConv(this.#projection, key) != null) next.set(key, roster);
		this.#projection.set({ members: next });
	}
}
