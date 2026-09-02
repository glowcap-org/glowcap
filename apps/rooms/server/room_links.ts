// Durable room-link and moderator publications backed by RoomServerState.

import type { Session } from "@glowcap/runtime";
import { roomAuthorityIdentity } from "../lib/authority_identity.ts";
import { formatRoomsSturdyref, roomsLocator } from "../lib/locator.ts";
import type { RoomAuthorityKind } from "../lib/room/authority.ts";
import { PRIVATE_ROOM_POLICY, roomIsListed, type RoomPolicy } from "../lib/room/policy.ts";
import { MAX_ROOM } from "../lib/limits.ts";
import { ROOM_EXISTS, RoomError } from "../lib/errors.ts";
import type { RoomServerContext } from "./context.ts";
import { notifyLocalRoom, notifyPublicRoom } from "./discovery.ts";
import { type RoomState } from "./registry.ts";
import type { ManagedRoomState, StewardState } from "./room_state_document.ts";
import type { RoomServerState } from "./state.ts";
import { notifyRoomPolicyChanged } from "./presence.ts";

type AuthorityTarget = { readonly name: string } | { readonly token: string };

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
	manager(name: string, entropy: Uint8Array, active: () => boolean): string;
	unpublish(swiss: string): boolean;
}

/** The stable-name index over RoomServerState: which room names this server has
 * made durable, and the swiss each of them answers to. */
export class RoomLinks {
	readonly #ctx: RoomServerContext;
	readonly #state: RoomServerState;
	readonly #publish: PublishRoomAuthorities;
	readonly #advertisedLocation: (session: Session) => string;
	readonly #authorityChanged: (name: string, kind: RoomAuthorityKind, token: string) => void;
	readonly #swiss = new Map<string, string>();
	readonly #stewardSwiss = new Map<string, string>();
	readonly #managerSwiss = new Map<string, string>();
	readonly #roomNameBySwiss = new Map<string, string>();
	readonly #stewardNameBySwiss = new Map<string, string>();
	readonly #managerNameBySwiss = new Map<string, string>();
	readonly #managerIdentityByName = new Map<string, string>();
	readonly #managerNameByIdentity = new Map<string, string>();
	#linkTail: Promise<void> = Promise.resolve();

	private constructor(
		ctx: RoomServerContext,
		state: RoomServerState,
		publish: PublishRoomAuthorities,
		advertisedLocation: (session: Session) => string,
		authorityChanged: (name: string, kind: RoomAuthorityKind, token: string) => void,
	) {
		this.#ctx = ctx;
		this.#state = state;
		this.#publish = publish;
		this.#advertisedLocation = advertisedLocation;
		this.#authorityChanged = authorityChanged;
	}

	/** Republish every room name this server made durable before its last stop.
	 * Deriving each one's entropy from the restored key is what makes these the
	 * same sturdyrefs the previous process handed out. */
	static async restore(
		ctx: RoomServerContext,
		state: RoomServerState,
		publish: PublishRoomAuthorities,
		advertisedLocation: (session: Session) => string,
		authorityChanged: (name: string, kind: RoomAuthorityKind, token: string) => void = () => {},
	): Promise<RoomLinks> {
		const links = new RoomLinks(ctx, state, publish, advertisedLocation, authorityChanged);
		for (const name of state.linkedRooms()) {
			const generation = state.roomLinkGeneration(name);
			links.#setAuthority(
				"room",
				name,
				publish.room(
					name,
					await state.roomEntropyFor(name, generation),
					() => state.roomLinkGenerationIsCurrent(name, generation),
				),
			);
		}
		for (const { name, generation, issued } of state.stewards()) {
			if (!issued) continue;
			const roomGeneration = state.roomLinkGeneration(name);
			const roomSwiss = links.#swiss.get(name.toLowerCase());
			if (roomSwiss == null) throw new Error(`stewarded room "${name}" has no room publication`);
			links.#setAuthority(
				"steward",
				name,
				publish.steward(
					name,
					await roomAuthorityIdentity(roomSwiss),
					await state.stewardEntropyFor(name, generation),
					() =>
						state.roomLinkGenerationIsCurrent(name, roomGeneration) &&
						state.stewardGenerationIsCurrent(name, generation),
				),
			);
		}
		for (const { name, generation, issued } of state.managers()) {
			links.#setManagerIdentity(name, await state.managerIdentityFor(name));
			if (!issued) continue;
			links.#setAuthority(
				"manager",
				name,
				publish.manager(
					name,
					await state.managerEntropyFor(name, generation),
					() => state.managerGenerationIsCurrent(name, generation),
				),
			);
		}
		return links;
	}

	#setAuthority(kind: RoomAuthorityKind, name: string, swiss: string): void {
		const key = name.toLowerCase();
		const [forward, reverse] = this.#authorityMaps(kind);
		const previous = forward.get(key);
		if (previous != null) reverse.delete(previous);
		forward.set(key, swiss);
		reverse.set(swiss, name);
	}

	#dropAuthority(kind: RoomAuthorityKind, name: string): string | null {
		const key = name.toLowerCase();
		const [forward, reverse] = this.#authorityMaps(kind);
		const swiss = forward.get(key) ?? null;
		if (swiss != null) reverse.delete(swiss);
		forward.delete(key);
		return swiss;
	}

	#dropManagerIdentity(name: string): void {
		const key = name.toLowerCase();
		const identity = this.#managerIdentityByName.get(key);
		this.#managerIdentityByName.delete(key);
		if (identity != null) this.#managerNameByIdentity.delete(identity);
	}

	#resolveAuthority(kind: RoomAuthorityKind, target: AuthorityTarget): { name: string; swiss: string } {
		const [forward, reverse] = this.#authorityMaps(kind);
		const name = "name" in target ? target.name : reverse.get(target.token);
		const swiss = name == null ? null : forward.get(name.toLowerCase()) ?? null;
		if (name == null || swiss == null || ("token" in target && swiss !== target.token)) {
			throw new Error(
				`that ${
					kind === "room" ? "room link" : kind === "steward" ? "moderator" : "manager"
				} capability generation is no longer current`,
			);
		}
		return { name, swiss };
	}

	#authorityMaps(kind: RoomAuthorityKind): [Map<string, string>, Map<string, string>] {
		if (kind === "room") return [this.#swiss, this.#roomNameBySwiss];
		if (kind === "steward") return [this.#stewardSwiss, this.#stewardNameBySwiss];
		return [this.#managerSwiss, this.#managerNameBySwiss];
	}

	#setManagerIdentity(name: string, identity: string): void {
		const key = name.toLowerCase();
		const prior = this.#managerIdentityByName.get(key);
		if (prior != null && prior !== identity) throw new Error("a room changed its stable management identity");
		const existing = this.#managerNameByIdentity.get(identity);
		if (existing != null && existing.toLowerCase() !== name.toLowerCase()) {
			throw new Error("two rooms derived the same management identity");
		}
		this.#managerIdentityByName.set(key, identity);
		this.#managerNameByIdentity.set(identity, name);
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

	currentRoomLink(name: string, session: Session): string | null {
		return this.#linkFor(session, this.#swiss.get(name.toLowerCase()) ?? null);
	}

	/** Whether this directory has a durable, name-enterable room. */
	hasRegisteredPublicRoom(name: string): boolean {
		return this.#state.managedRoomIdForName(name) !== null ||
			(this.#state.roomLinkActive(name) && this.#state.managedRoom(name) === null);
	}

	managedRoomForPublicName(name: string): ManagedRoomState | null {
		const id = this.#state.managedRoomIdForName(name);
		return id === null ? null : this.#state.managedRoom(id);
	}

	managedRoom(id: string): ManagedRoomState | null {
		return this.#state.managedRoom(id);
	}

	managedRoomGenerationIsCurrent(id: string, generation: number): boolean {
		return this.#state.managedRoomGenerationIsCurrent(id, generation);
	}

	managerIdentity(name: string): Promise<string> {
		const cached = this.#managerIdentityByName.get(name.toLowerCase());
		if (cached != null) return Promise.resolve(cached);
		return this.#state.managerIdentityFor(name).then((identity) => {
			this.#setManagerIdentity(name, identity);
			return identity;
		});
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
			await this.#state.remember(name, topic);
			const generation = this.#state.roomLinkGeneration(name);
			swiss = this.#publish.room(
				name,
				await this.#state.roomEntropyFor(name, generation),
				() => this.#state.roomLinkGenerationIsCurrent(name, generation),
			);
			this.#setAuthority("room", name, swiss);
		});
		this.#linkTail = run.then(() => {}, () => {});
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
			const roomGeneration = this.#state.roomLinkGeneration(name);
			roomSwiss = this.#swiss.get(key) ?? "";
			if (roomSwiss === "") {
				roomSwiss = this.#publish.room(
					name,
					await this.#state.roomEntropyFor(name, roomGeneration),
					() => this.#state.roomLinkGenerationIsCurrent(name, roomGeneration),
				);
				this.#setAuthority("room", name, roomSwiss);
			}
			roomIdentity = await roomAuthorityIdentity(roomSwiss);
			stewardSwiss = this.#stewardSwiss.get(key) ?? "";
			if (stewardSwiss === "") {
				stewardSwiss = this.#publish.steward(
					name,
					roomIdentity,
					await this.#state.stewardEntropyFor(name, generation),
					() =>
						this.#state.roomLinkGenerationIsCurrent(name, roomGeneration) &&
						this.#state.stewardGenerationIsCurrent(name, generation),
				);
				this.#setAuthority("steward", name, stewardSwiss);
			}
		});
		this.#linkTail = run.then(() => {}, () => {});
		return run.then(() => ({
			room: this.#linkFor(session, roomSwiss),
			identity: roomIdentity,
			steward: this.#linkFor(session, stewardSwiss),
		}));
	}

	/** Issue or recover the passable manager for exactly one durable room. The
	 * manager and room link are committed together; neither retains a live room. */
	manager(
		name: string,
		session: Session,
		topic?: string,
		managed?: Pick<ManagedRoomState, "name" | "policy">,
	): Promise<{ room: string; manager: string }> {
		let roomSwiss = "";
		let managerSwiss = "";
		const run = this.#linkTail.then(async () => {
			const key = name.toLowerCase();
			await this.#state.rememberManager(name, topic, managed);
			this.#setManagerIdentity(name, await this.#state.managerIdentityFor(name));
			const roomGeneration = this.#state.roomLinkGeneration(name);
			roomSwiss = this.#swiss.get(key) ?? "";
			if (roomSwiss === "") {
				roomSwiss = this.#publish.room(
					name,
					await this.#state.roomEntropyFor(name, roomGeneration),
					() => this.#state.roomLinkGenerationIsCurrent(name, roomGeneration),
				);
				this.#setAuthority("room", name, roomSwiss);
			}
			const generation = this.#state.managerGeneration(name);
			managerSwiss = this.#managerSwiss.get(key) ?? "";
			if (managerSwiss === "") {
				managerSwiss = this.#publish.manager(
					name,
					await this.#state.managerEntropyFor(name, generation),
					() => this.#state.managerGenerationIsCurrent(name, generation),
				);
				this.#setAuthority("manager", name, managerSwiss);
			}
		});
		this.#linkTail = run.catch(() => {});
		return run.then(() => ({
			room: this.#linkFor(session, roomSwiss),
			manager: this.#linkFor(session, managerSwiss),
		}));
	}

	managerForIdentity(identity: string, session: Session): Promise<{ room: string; manager: string }> {
		const name = this.#managerNameByIdentity.get(identity);
		if (name == null) throw new Error("that room management identity is not known to this directory");
		return this.manager(name, session);
	}

	/** Change discovery and name admission without replacing room identity or
	 * any bearer generation. The name reservation spans the state write, so a
	 * concurrent open cannot win between collision validation and commit. */
	setPolicy(managerToken: string, policy: RoomPolicy, name: string): Promise<ManagedRoomState> {
		if (name.length === 0 || name.length > MAX_ROOM) {
			return Promise.reject(new Error(`a room name must be between 1 and ${MAX_ROOM} characters`));
		}
		const run = this.#linkTail.then(() => this.#changePolicy(managerToken, policy, name));
		this.#linkTail = run.then(() => {}, () => {});
		return run;
	}

	async #changePolicy(managerToken: string, policy: RoomPolicy, name: string): Promise<ManagedRoomState> {
		const { name: id } = this.#resolveAuthority("manager", { token: managerToken });
		if (this.#state.managedRoom(id) === null) throw new Error("this manager has no room access policy");
		const claimed = this.#state.managedRoomIdForName(name);
		if (
			roomIsListed(policy) &&
			((claimed !== null && claimed.toLowerCase() !== id.toLowerCase()) || this.#state.roomLinkActive(name))
		) throw new RoomError(ROOM_EXISTS, `room "${name}" already exists`);

		const current = this.#ctx.live.rooms.get(id.toLowerCase());
		const priorName = current?.name ?? name;
		const wasListed = current == null ? false : roomIsListed(current.policy);
		const reservation = roomIsListed(policy) ? this.#ctx.live.reservePublicRoomName(name, current) : null;
		let committed = false;
		try {
			await this.#state.setManagedRoomPolicy(id, name, policy);
			if (current != null) committed = this.#ctx.live.commitLocalRoomPolicy(current, policy, name, reservation);
			if (committed && current != null) this.#announcePolicyChange(current, priorName, wasListed);
			const answer = this.#state.managedRoom(id);
			if (answer === null) throw new Error("room policy change lost its managed room");
			return answer;
		} finally {
			if (!committed && reservation !== null) this.#ctx.live.releasePublicRoomName(reservation);
		}
	}

	#announcePolicyChange(live: RoomState, oldName: string, wasListed: boolean): void {
		notifyRoomPolicyChanged(this.#ctx, live);
		const listed = roomIsListed(live.policy);
		const renamed = oldName.toLowerCase() !== live.name.toLowerCase();
		if (wasListed && (!listed || renamed)) {
			notifyPublicRoom(this.#ctx, { kind: "local", id: live.entryId, name: oldName, state: live }, "closed", 0);
		}
		if (listed) notifyLocalRoom(this.#ctx, live, wasListed && !renamed ? "count" : "opened", live.members.length);
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
		return this.#revokeSteward({ name });
	}

	#revokeSteward(target: AuthorityTarget): Promise<void> {
		const run = this.#linkTail.then(async () => {
			const { name, swiss: oldSwiss } = this.#resolveAuthority("steward", target);
			await this.#state.revokeSteward(name);
			this.#publish.unpublish(oldSwiss);
			this.#dropAuthority("steward", name);
			this.#authorityChanged(name, "steward", oldSwiss);
		});
		this.#linkTail = run.catch(() => {});
		return run;
	}

	#revokeManager(target: AuthorityTarget): Promise<void> {
		const run = this.#linkTail.then(async () => {
			const { name, swiss } = this.#resolveAuthority("manager", target);
			await this.#state.revokeManager(name);
			this.#publish.unpublish(swiss);
			this.#dropAuthority("manager", name);
			this.#authorityChanged(name, "manager", swiss);
		});
		this.#linkTail = run.catch(() => {});
		return run;
	}

	revokeRoomLink(name: string): Promise<void> {
		return this.#revokeRoomLink({ name });
	}

	#revokeRoomLink(target: AuthorityTarget): Promise<void> {
		const run = this.#linkTail.then(async () => {
			const { name, swiss } = this.#resolveAuthority("room", target);
			const stewardSwiss = this.#stewardSwiss.get(name.toLowerCase());
			await this.#state.revokeRoomLink(name);
			this.#publish.unpublish(swiss);
			if (stewardSwiss != null) this.#publish.unpublish(stewardSwiss);
			this.#dropAuthority("room", name);
			this.#dropAuthority("steward", name);
			this.#authorityChanged(name, "room", swiss);
		});
		this.#linkTail = run.catch(() => {});
		return run;
	}

	/** Revoke only the generation the caller identified. Resolution happens
	 * inside the serialized authority mutation, so a delayed request for an old
	 * token cannot discover a name and then retire that name's replacement. */
	revokeAuthority(kind: RoomAuthorityKind, token: string): Promise<void> {
		if (token === "") return Promise.reject(new Error("room authority needs a publication token"));
		if (kind === "room") return this.#revokeRoomLink({ token });
		if (kind === "steward") return this.#revokeSteward({ token });
		return this.#revokeManager({ token });
	}

	/** Withdraw one manager-identified public registration without retiring the
	 * manager or the room's other independently held authority. */
	unregisterRoom(managerToken: string): Promise<ManagedRoomState> {
		if (managerToken === "") return Promise.reject(new Error("room unregistration needs a manager token"));
		const run = this.#linkTail.then(() => {
			const { name } = this.#resolveAuthority("manager", { token: managerToken });
			const managed = this.#state.managedRoom(name);
			if (managed == null) throw new Error("this manager has no room access policy");
			return this.#changePolicy(managerToken, PRIVATE_ROOM_POLICY, managed.name);
		});
		this.#linkTail = run.then(() => {}, () => {});
		return run;
	}

	factoryReset(): Promise<void> {
		const run = this.#linkTail.then(async () => {
			const retired = this.#state.linkedRooms().map((name) => {
				const token = this.#swiss.get(name.toLowerCase());
				if (token == null) throw new Error(`room "${name}" has no published room capability`);
				return { name, token };
			});
			const retiredManagers = [...this.#managerSwiss].map(([key, token]) => ({
				name: this.#managerNameBySwiss.get(token) ?? key,
				token,
			}));
			const published = new Set([
				...this.#swiss.values(),
				...this.#stewardSwiss.values(),
				...this.#managerSwiss.values(),
			]);
			await this.#state.factoryResetAuthorities();
			for (const swiss of published) this.#publish.unpublish(swiss);
			this.#swiss.clear();
			this.#stewardSwiss.clear();
			this.#managerSwiss.clear();
			this.#roomNameBySwiss.clear();
			this.#stewardNameBySwiss.clear();
			this.#managerNameBySwiss.clear();
			this.#managerIdentityByName.clear();
			this.#managerNameByIdentity.clear();
			for (const authority of retired) this.#authorityChanged(authority.name, "room", authority.token);
			for (const authority of retiredManagers) {
				this.#authorityChanged(authority.name, "manager", authority.token);
			}
		});
		this.#linkTail = run.catch(() => {});
		return run;
	}

	hasSteward(name: string): boolean {
		return this.#state.hasSteward(name);
	}

	hasManager(name: string): boolean {
		return this.#state.hasManager(name);
	}
}
