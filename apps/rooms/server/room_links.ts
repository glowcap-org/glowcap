// Durable room-link and moderator publications backed by RoomServerState.

import type { Session } from "@pancake/runtime";
import { roomAuthorityIdentity } from "../lib/authority_identity.ts";
import { formatRoomsSturdyref, roomsLocator } from "../lib/locator.ts";
import type { RoomServerState, StewardState } from "./state.ts";

/** How a linked room reaches the Host that will answer for it: mint the durable
 * publication from this room's derived entropy and hand back the swiss name.
 *
 * A room link is Host-wide rather than published onto each accepted session,
 * because a sturdyref is redeemed by whoever holds it — including a peer whose
 * session opened after the link was minted, and who never asks the directory
 * anything. The turn the redemption arrives on names the caller. */
export interface PublishRoomAuthorities {
	room(name: string, entropy: Uint8Array, active: () => boolean): string;
	steward(name: string, roomIdentity: string, entropy: Uint8Array, active: () => boolean): string;
	unpublish(swiss: string): boolean;
}

/** The stable-name index over RoomServerState: which room names this server has
 * made durable, and the swiss each of them answers to. */
export class RoomLinks {
	readonly #state: RoomServerState;
	readonly #publish: PublishRoomAuthorities;
	readonly #advertisedLocation: (session: Session) => string;
	readonly #swiss = new Map<string, string>();
	readonly #stewardSwiss = new Map<string, string>();
	#linkTail: Promise<void> = Promise.resolve();

	private constructor(
		state: RoomServerState,
		publish: PublishRoomAuthorities,
		advertisedLocation: (session: Session) => string,
	) {
		this.#state = state;
		this.#publish = publish;
		this.#advertisedLocation = advertisedLocation;
	}

	/** Republish every room name this server made durable before its last stop.
	 * Deriving each one's entropy from the restored key is what makes these the
	 * same sturdyrefs the previous process handed out. */
	static async restore(
		state: RoomServerState,
		publish: PublishRoomAuthorities,
		advertisedLocation: (session: Session) => string,
	): Promise<RoomLinks> {
		const links = new RoomLinks(state, publish, advertisedLocation);
		for (const name of state.linkedRooms()) {
			links.#swiss.set(
				name.toLowerCase(),
				publish.room(name, await state.roomEntropyFor(name), () => state.roomLinkActive(name)),
			);
		}
		for (const { name, generation, issued } of state.stewards()) {
			if (!issued) continue;
			const roomSwiss = links.#swiss.get(name.toLowerCase());
			if (roomSwiss == null) throw new Error(`stewarded room "${name}" has no room publication`);
			links.#stewardSwiss.set(
				name.toLowerCase(),
				publish.steward(
					name,
					await roomAuthorityIdentity(roomSwiss),
					await state.stewardEntropyFor(name, generation),
					() => state.stewardGenerationIsCurrent(name, generation),
				),
			);
		}
		return links;
	}

	/** The durable names this server has published, with the swiss each answers
	 * to. The inspect capability lists these as real OCapN names, not as labels. */
	named(): ReadonlyArray<{ name: string; swiss: string }> {
		const out: { name: string; swiss: string }[] = [];
		for (const name of this.#state.linkedRooms()) {
			const swiss = this.#swiss.get(name.toLowerCase());
			if (swiss != null) out.push({ name, swiss });
		}
		return out;
	}

	/** Every stewardship this server has issued or revoked. `steward` is present
	 * only for the current issued generation; an unissued row is deliberately
	 * still visible to the operator so it can be granted again. */
	stewardships(session: Session): ReadonlyArray<StewardState & { steward: string | null }> {
		return this.#state.stewards().map((row) => ({
			...row,
			steward: row.issued ? this.#linkFor(session, this.#stewardSwiss.get(row.name.toLowerCase()) ?? null) : null,
		}));
	}

	/** One room's current moderation publication state without rebuilding the
	 * operator's complete sorted inventory. A live room with no durable steward
	 * yet has revision zero and no publication. */
	stewardship(name: string, session: Session): StewardState & { steward: string | null } {
		const row = this.#state.stewardship(name) ?? {
			name,
			generation: 0,
			issued: false,
		};
		return {
			...row,
			steward: row.issued ? this.#linkFor(session, this.#stewardSwiss.get(row.name.toLowerCase()) ?? null) : null,
		};
	}

	/** Compose one publication with the route this Host authors for the calling
	 * session. The Host, not its client, owns both halves of a sturdyref. */
	#linkFor(session: Session, swiss: string): string;
	#linkFor(session: Session, swiss: null): null;
	#linkFor(session: Session, swiss: string | null): string | null;
	#linkFor(session: Session, swiss: string | null): string | null {
		if (swiss === null) return null;
		return formatRoomsSturdyref(roomsLocator(this.#advertisedLocation(session)), swiss);
	}

	/** Persist and publish one room link, answering the same swiss for a name
	 * already linked.
	 *
	 * The promise hop is load-bearing when a directory behavior calls this: the
	 * Host refuses a publication during a turn, so the mint happens only once
	 * this deferred answer has returned to the microtask queue.
	 *
	 * Persisting before publishing is the safe order rather than the tidy one. A
	 * name recorded but not published is answered by the next restart, which
	 * reads it back and publishes it; a name published but not recorded works
	 * until the process stops and then is gone, with a link already handed out
	 * for it. Only one of those two failures heals itself. */
	link(name: string, session: Session, topic?: string): Promise<string> {
		let swiss = "";
		const run = this.#linkTail.then(async () => {
			const key = name.toLowerCase();
			const existing = this.#swiss.get(key);
			if (existing != null) {
				swiss = existing;
				return;
			}
			const entropy = await this.#state.roomEntropyFor(name);
			await this.#state.remember(name, topic);
			swiss = this.#publish.room(name, entropy, () => this.#state.roomLinkActive(name));
			this.#swiss.set(key, swiss);
		});
		this.#linkTail = run.catch(() => {});
		return run.then(() => this.#linkFor(session, swiss));
	}

	/** Mint the room's one durable steward authority. Issuance is persisted
	 * before the secret is returned; a later room generation can therefore tell
	 * that reconnecting first is not a claim on stewardship. */
	steward(
		name: string,
		session: Session,
		topic?: string,
	): Promise<{ room: string; identity: string; steward: string }> {
		let roomSwiss = "";
		let roomIdentity = "";
		let stewardSwiss = "";
		const run = this.#linkTail.then(async () => {
			const key = name.toLowerCase();
			await this.#state.rememberSteward(name, topic);
			const generation = this.#state.stewardGeneration(name);
			roomSwiss = this.#swiss.get(key) ?? "";
			if (roomSwiss === "") {
				roomSwiss = this.#publish.room(
					name,
					await this.#state.roomEntropyFor(name),
					() => this.#state.roomLinkActive(name),
				);
				this.#swiss.set(key, roomSwiss);
			}
			roomIdentity = await roomAuthorityIdentity(roomSwiss);
			stewardSwiss = this.#stewardSwiss.get(key) ?? "";
			if (stewardSwiss === "") {
				stewardSwiss = this.#publish.steward(
					name,
					roomIdentity,
					await this.#state.stewardEntropyFor(name, generation),
					() => this.#state.stewardGenerationIsCurrent(name, generation),
				);
				this.#stewardSwiss.set(key, stewardSwiss);
			}
		});
		this.#linkTail = run.catch(() => {});
		return run.then(() => ({
			room: this.#linkFor(session, roomSwiss),
			identity: roomIdentity,
			steward: this.#linkFor(session, stewardSwiss),
		}));
	}

	topic(name: string): string | null {
		return this.#state.topic(name);
	}

	setTopic(name: string, topic: string): Promise<void> {
		return this.#state.setTopic(name, topic);
	}

	/** Revoke the current steward generation. Serialized with issuance so a
	 * concurrent give and revoke have one durable order, and the current swiss
	 * index cannot retain the old generation after the state has rotated. */
	revokeSteward(name: string): Promise<void> {
		const run = this.#linkTail.then(async () => {
			const key = name.toLowerCase();
			const oldSwiss = this.#stewardSwiss.get(key);
			await this.#state.revokeSteward(name);
			if (oldSwiss != null) this.#publish.unpublish(oldSwiss);
			this.#stewardSwiss.delete(key);
		});
		this.#linkTail = run.catch(() => {});
		return run;
	}

	revokeRoomLink(name: string): Promise<void> {
		const run = this.#linkTail.then(async () => {
			const key = name.toLowerCase();
			const swiss = this.#swiss.get(key);
			const stewardSwiss = this.#stewardSwiss.get(key);
			await this.#state.revokeRoomLink(name);
			if (swiss != null) this.#publish.unpublish(swiss);
			if (stewardSwiss != null) this.#publish.unpublish(stewardSwiss);
			this.#swiss.delete(key);
			this.#stewardSwiss.delete(key);
		});
		this.#linkTail = run.catch(() => {});
		return run;
	}

	factoryReset(): Promise<void> {
		const run = this.#linkTail.then(async () => {
			const published = new Set([...this.#swiss.values(), ...this.#stewardSwiss.values()]);
			await this.#state.factoryResetAuthorities();
			for (const swiss of published) this.#publish.unpublish(swiss);
			this.#swiss.clear();
			this.#stewardSwiss.clear();
		});
		this.#linkTail = run.catch(() => {});
		return run;
	}

	hasSteward(name: string): boolean {
		return this.#state.hasSteward(name);
	}
}
