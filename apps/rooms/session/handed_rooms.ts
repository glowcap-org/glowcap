// Runtime custody for room capabilities handed to a durable session.

import { type Ref, type Session } from "@pancake/runtime";
import { MAX_PENDING_INVITES } from "../lib/limits.ts";
import { linkRoomReference } from "../lib/room/client.ts";
import { settleCapabilityCleanup } from "../lib/capability_cleanup.ts";

export interface DurableHandedRoomView {
	id: string;
	directory: string;
	label: string;
	from: string;
}

interface HeldRoom extends DurableHandedRoomView {
	owner: Session;
	room: Ref;
	stopClose: () => void;
}

export class DurableHandedRooms {
	readonly #rooms = new Map<string, HeldRoom>();
	readonly #changed: () => void;
	#sequence = 0n;

	constructor(changed: () => void) {
		this.#changed = changed;
	}

	list(): DurableHandedRoomView[] {
		return [...this.#rooms.values()].map(({ id, directory, label, from }) => ({ id, directory, label, from }));
	}

	has(id: string): boolean {
		return this.#rooms.has(id);
	}

	receive(directory: string, owner: Session, label: string, room: Ref, from: string): void {
		if (this.#rooms.size >= MAX_PENDING_INVITES) {
			settleCapabilityCleanup("a handed room at the session limit would not release", () => owner.release(room));
			throw new Error("this Rooms session has reached its room-invitation limit");
		}
		this.#sequence += 1n;
		const id = `handed-room:${this.#sequence}`;
		const held: HeldRoom = { id, directory, label, from, owner, room, stopClose: () => {} };
		held.stopClose = owner.onClose(() => {
			if (this.#rooms.get(id) !== held) return;
			this.#rooms.delete(id);
			this.#changed();
		});
		this.#rooms.set(id, held);
		this.#changed();
	}

	/** Accepting is the explicit durability act. Ask the handed room's source
	 * for its link, commit that bearer through the caller, then release the
	 * transient occurrence. Arrival alone never mints or stores authority. */
	async accept(id: string, commit: (view: DurableHandedRoomView, link: string) => Promise<number>): Promise<number> {
		const held = this.#rooms.get(id);
		if (held == null) throw new Error("that handed room invitation is no longer available");
		const link = await linkRoomReference(held.owner, held.room);
		const revision = await commit(held, link);
		this.#dispose(id, "accepted handed room");
		return revision;
	}

	drop(id: string): boolean {
		if (!this.#rooms.has(id)) return false;
		this.#dispose(id, "declined handed room");
		return true;
	}

	releaseDirectory(directory: string): void {
		for (const [id, held] of this.#rooms) {
			if (held.directory === directory) this.#dispose(id, "closed handed-room directory");
		}
	}

	close(): void {
		for (const id of [...this.#rooms.keys()]) this.#dispose(id, "closed Rooms session");
	}

	#dispose(id: string, what: string): void {
		const held = this.#rooms.get(id);
		if (held == null) return;
		this.#rooms.delete(id);
		settleCapabilityCleanup(`${what} close observer cleanup failed`, () => held.stopClose());
		settleCapabilityCleanup(`${what} capability release failed`, () => held.owner.release(held.room));
		this.#changed();
	}
}
