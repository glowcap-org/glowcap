// Durable application state for room sturdyrefs.
//
// The portable Host owns no filesystem, by design. Its restart contract is
// instead reproducibility: an embedder that restores the same publication name
// and Host identity restores the same sturdyref. Rooms is that embedder. It
// keeps one identity seed, one HMAC key, and the small set of room identities
// for which somebody explicitly asked for a link or minted stewardship. Durable
// room topics follow those identities; live membership remains ephemeral and
// retention has its own storage seam.

import { DURABLE_SWISS_ENTROPY_BYTES } from "@pancake/runtime";
import { NO_SUCH_ROOM, NOT_STEWARD, ROOM_LINKS_FULL, RoomError } from "../lib/errors.ts";
import { isManagedRoomId, MAX_ROOM_LINKS, MAX_TOPIC } from "../lib/limits.ts";
import { roomIsListed, roomPoliciesEqual, type RoomPolicy } from "../lib/room/policy.ts";
import { atomicWrite, readBoundedText } from "../lib/durable_file.ts";
import {
	decodeRoomStateHex,
	encodeRoomStateHex,
	freshRoomServerDocument,
	type ManagedRoomState,
	MAX_ROOM_STATE_BYTES,
	parseRoomServerDocument,
	ROOM_STATE_FILE,
	ROOM_STATE_KEY_BYTES,
	ROOM_STATE_VERSION,
	type RoomServerDiskState,
	type StewardState,
	validateRoomServerDocument,
} from "./room_state_document.ts";

const encoder = new TextEncoder();

const STEWARD_DOMAIN = "steward\u0000";
const MANAGER_DOMAIN = "manager\u0000";
const MANAGED_ROOM_DOMAIN = "managed-room\u0000";
const ROOM_GENERATION_DOMAIN = "room-generation\u0000";

export class RoomServerStateError extends Error {}

/** The state a Rooms server restores. With no directory it is intentionally
 * process-local, preserving the application's existing ephemeral default. */
export class RoomServerState {
	readonly #identitySeed: Uint8Array<ArrayBuffer>;
	#secret: Uint8Array<ArrayBuffer>;
	readonly #directory: string | null;
	readonly #linked = new Map<string, string>();
	readonly #revoked = new Map<string, string>();
	readonly #linkGenerations = new Map<string, number>();
	readonly #stewards = new Map<string, StewardState>();
	readonly #managers = new Map<string, StewardState>();
	readonly #managedRooms = new Map<string, ManagedRoomState>();
	readonly #managedRoomByName = new Map<string, string>();
	readonly #topics = new Map<string, { name: string; topic: string }>();
	#writeTail: Promise<void> = Promise.resolve();
	#changed: () => void;

	private constructor(disk: RoomServerDiskState, directory: string | null, changed: () => void = () => {}) {
		this.#changed = changed;
		this.#identitySeed = decodeRoomStateHex(disk.identitySeed, ROOM_STATE_KEY_BYTES, "identity seed");
		this.#secret = decodeRoomStateHex(disk.roomLinkSecret, ROOM_STATE_KEY_BYTES, "room-link secret");
		this.#directory = directory;
		for (const name of disk.linkedRooms) this.#linked.set(name.toLowerCase(), name);
		for (const name of disk.revokedRooms) this.#revoked.set(name.toLowerCase(), name);
		for (const row of disk.roomLinkGenerations) {
			this.#linkGenerations.set(row.name.toLowerCase(), row.generation);
		}
		for (const steward of disk.stewards) this.#stewards.set(steward.name.toLowerCase(), { ...steward });
		for (const manager of disk.managers) this.#managers.set(manager.name.toLowerCase(), { ...manager });
		for (const room of disk.managedRooms) {
			this.#managedRooms.set(room.id.toLowerCase(), { ...room });
			if (roomIsListed(room.policy)) this.#managedRoomByName.set(room.name.toLowerCase(), room.id);
		}
		for (const topic of disk.topics) this.#topics.set(topic.name.toLowerCase(), { ...topic });
	}

	get identitySeed(): Uint8Array<ArrayBuffer> {
		return this.#identitySeed.slice();
	}

	static async open(directory?: string, changed: () => void = () => {}): Promise<RoomServerState> {
		if (directory == null) return new RoomServerState(freshRoomServerDocument(), null, changed);
		await Deno.mkdir(directory, { recursive: true, mode: 0o700 });
		const path = `${directory}/${ROOM_STATE_FILE}`;
		try {
			return new RoomServerState(
				parseRoomServerDocument(await readBoundedText(path, MAX_ROOM_STATE_BYTES, "rooms state")),
				directory,
				changed,
			);
		} catch (err) {
			if (!(err instanceof Deno.errors.NotFound)) {
				if (err instanceof RoomServerStateError) throw err;
				throw new RoomServerStateError(err instanceof Error ? err.message : String(err), { cause: err });
			}
			const disk = freshRoomServerDocument();
			const state = new RoomServerState(disk, directory, changed);
			await state.#write(disk);
			return state;
		}
	}

	linkedRooms(): string[] {
		return [...this.#linked.values()];
	}

	roomLinkActive(name: string): boolean {
		return this.#linked.has(name.toLowerCase());
	}

	roomLinkGeneration(name: string): number {
		return this.#linkGenerations.get(name.toLowerCase()) ?? 0;
	}

	roomLinkGenerationIsCurrent(name: string, generation: number): boolean {
		return this.roomLinkActive(name) && this.roomLinkGeneration(name) === generation;
	}

	revokedRooms(): string[] {
		return [...this.#revoked.values()];
	}

	stewards(): StewardState[] {
		return [...this.#stewards.values()].map((steward) => ({ ...steward }));
	}

	stewardship(name: string): StewardState | null {
		const steward = this.#stewards.get(name.toLowerCase());
		return steward == null ? null : { ...steward };
	}

	hasSteward(name: string): boolean {
		return this.#stewards.get(name.toLowerCase())?.issued === true;
	}

	stewardGeneration(name: string): number {
		return this.#stewards.get(name.toLowerCase())?.generation ?? 0;
	}

	managers(): StewardState[] {
		return [...this.#managers.values()].map((manager) => ({ ...manager }));
	}

	hasManager(name: string): boolean {
		return this.#managers.get(name.toLowerCase())?.issued === true;
	}

	managerGeneration(name: string): number {
		return this.#managers.get(name.toLowerCase())?.generation ?? 0;
	}

	managedRoom(id: string): ManagedRoomState | null {
		const room = this.#managedRooms.get(id.toLowerCase());
		return room == null ? null : { ...room };
	}

	managedRoomGenerationIsCurrent(id: string, generation: number): boolean {
		return this.#managedRooms.get(id.toLowerCase())?.generation === generation;
	}

	managedRoomIdForName(name: string): string | null {
		return this.#managedRoomByName.get(name.toLowerCase()) ?? null;
	}

	setManagedRoomPolicy(id: string, name: string, policy: RoomPolicy): Promise<void> {
		const run = this.#writeTail.then(async () => {
			const key = id.toLowerCase();
			const current = this.#managedRooms.get(key);
			if (current == null || this.#managers.get(key)?.issued !== true) {
				throw new Error("this manager has no current managed room");
			}
			if (current.name === name && roomPoliciesEqual(current.policy, policy)) return;
			const next = new Map(this.#managedRooms);
			if (current.generation === Number.MAX_SAFE_INTEGER) {
				throw new Error(`room "${current.name}" exhausted public entrance generations`);
			}
			next.set(key, { id: current.id, name, policy, generation: current.generation + 1 });
			await this.#write(this.#document({ managedRooms: [...next.values()] }));
			this.#managedRooms.clear();
			this.#managedRoomByName.clear();
			for (const [roomKey, room] of next) {
				this.#managedRooms.set(roomKey, room);
				if (roomIsListed(room.policy)) this.#managedRoomByName.set(room.name.toLowerCase(), room.id);
			}
			this.#changed();
		});
		this.#writeTail = run.catch(() => {});
		return run;
	}

	topic(name: string): string | null {
		return this.#topics.get(name.toLowerCase())?.topic ?? null;
	}

	setTopic(name: string, topic: string): Promise<void> {
		if (topic.length > MAX_TOPIC) throw new Error(`a topic may be at most ${MAX_TOPIC} characters`);
		const run = this.#writeTail.then(async () => {
			const key = name.toLowerCase();
			const durableName = this.#linked.get(key) ?? (isManagedRoomId(name) ? null : name);
			if (durableName == null || this.#topics.get(key)?.topic === topic) return;
			const nextTopics = new Map(this.#topics);
			if (topic === "") nextTopics.delete(key);
			else {
				if (!nextTopics.has(key) && nextTopics.size === MAX_ROOM_LINKS) {
					throw new Error(`this server remembers topics for at most ${MAX_ROOM_LINKS} rooms`);
				}
				nextTopics.set(key, { name: durableName, topic });
			}
			await this.#write(this.#document({ topics: [...nextTopics.values()] }));
			this.#topics.clear();
			for (const [topicKey, value] of nextTopics) this.#topics.set(topicKey, value);
			this.#changed();
		});
		this.#writeTail = run.catch(() => {});
		return run;
	}

	/** Whether one published steward generation still carries authority.
	 * Behaviors call this for every verb: removing the publication from the
	 * current index would stop only later redemptions, while a holder may
	 * already have enlivened the old reference. */
	stewardGenerationIsCurrent(name: string, generation: number): boolean {
		const steward = this.#stewards.get(name.toLowerCase());
		return steward?.issued === true && steward.generation === generation;
	}

	managerGenerationIsCurrent(name: string, generation: number): boolean {
		const manager = this.#managers.get(name.toLowerCase());
		return manager?.issued === true && manager.generation === generation;
	}

	/** The entropy one room's durable sturdyref is minted from.
	 *
	 * The Host derives a durable swiss name from bytes the embedder supplies, so
	 * deriving those bytes rather than drawing them is what lets a link outlive
	 * the process that minted it with no per-room secret to store: the same room
	 * name under the same stored key rebuilds the same sturdyref. A MAC
	 * truncated to the Host's width stays unguessable without that key, which is
	 * the whole basis of the link's authority.
	 *
	 * The room name is not recoverable from the result, so holding one link
	 * discloses the room it opens and nothing about any other. */
	async roomEntropyFor(
		name: string,
		generation = this.roomLinkGeneration(name),
	): Promise<Uint8Array<ArrayBuffer>> {
		const durable = name.toLowerCase();
		return await this.#entropyFor(
			generation === 0 ? durable : `${ROOM_GENERATION_DOMAIN}${generation}\u0000${durable}`,
		);
	}

	/** A steward's durable name is reproducible with its room but cannot collide
	 * with, reveal, or be substituted for the room publication itself. */
	async stewardEntropyFor(name: string, generation = this.stewardGeneration(name)): Promise<Uint8Array<ArrayBuffer>> {
		const durable = name.toLowerCase();
		const roomGeneration = this.roomLinkGeneration(name);
		const steward = generation === 0 ? STEWARD_DOMAIN + durable : `${STEWARD_DOMAIN}${generation}\u0000${durable}`;
		const message = roomGeneration === 0 ? steward : `${ROOM_GENERATION_DOMAIN}${roomGeneration}\u0000${steward}`;
		return await this.#entropyFor(message);
	}

	async managerEntropyFor(name: string, generation = this.managerGeneration(name)): Promise<Uint8Array<ArrayBuffer>> {
		const durable = name.toLowerCase();
		return await this.#entropyFor(`${MANAGER_DOMAIN}${generation}\u0000${durable}`);
	}

	async managerIdentityFor(name: string): Promise<string> {
		return encodeRoomStateHex(await this.#entropyFor(MANAGED_ROOM_DOMAIN + name.toLowerCase()));
	}

	#generationRows(
		generations = this.#linkGenerations,
		linked = this.#linked,
		revoked = this.#revoked,
	): Array<{ name: string; generation: number }> {
		const rows: Array<{ name: string; generation: number }> = [];
		for (const [key, generation] of generations) {
			if (generation === 0) continue;
			const name = linked.get(key) ?? revoked.get(key);
			if (name != null) rows.push({ name, generation });
		}
		return rows;
	}

	async #entropyFor(message: string): Promise<Uint8Array<ArrayBuffer>> {
		const key = await crypto.subtle.importKey(
			"raw",
			this.#secret,
			{ name: "HMAC", hash: "SHA-256" },
			false,
			["sign"],
		);
		const mac = new Uint8Array(
			await crypto.subtle.sign("HMAC", key, encoder.encode(message)),
		);
		return mac.slice(0, DURABLE_SWISS_ENTROPY_BYTES);
	}

	/** Persist a newly linked name before its sturdyref is handed out. Writes are
	 * serialized and replace one complete file atomically, so two concurrent link
	 * requests cannot lose one another. */
	remember(name: string, topic?: string): Promise<void> {
		return this.#remember(name, false, false, topic);
	}

	rememberSteward(name: string, topic?: string): Promise<void> {
		return this.#remember(name, true, false, topic);
	}

	rememberManager(
		name: string,
		topic?: string,
		managed?: Pick<ManagedRoomState, "name" | "policy">,
	): Promise<void> {
		return this.#remember(name, false, true, topic, managed);
	}

	#remember(
		name: string,
		steward: boolean,
		manager: boolean,
		topic?: string,
		managed?: Pick<ManagedRoomState, "name" | "policy">,
	): Promise<void> {
		const run = this.#writeTail.then(async () => {
			const key = name.toLowerCase();
			const needsTopic = topic != null && topic !== "" && !this.#topics.has(key);
			const existingManaged = this.#managedRooms.get(key);
			const needsManaged = managed != null &&
				(existingManaged == null || existingManaged.name !== managed.name ||
					!roomPoliciesEqual(existingManaged.policy, managed.policy));
			if (
				this.#linked.has(key) && (!steward || this.#stewards.get(key)?.issued === true) &&
				(!manager || this.#managers.get(key)?.issued === true) && !needsTopic && !needsManaged
			) return;
			if (managed != null && !isManagedRoomId(name)) {
				throw new Error("managed room state needs opaque room identity");
			}
			if (
				existingManaged != null && managed != null &&
				(existingManaged.name !== managed.name || !roomPoliciesEqual(existingManaged.policy, managed.policy))
			) throw new Error("managed room creation does not replace existing room state");
			if (
				!this.#linked.has(key) && !this.#revoked.has(key) &&
				this.#linked.size + this.#revoked.size >= MAX_ROOM_LINKS
			) {
				throw new RoomError(
					ROOM_LINKS_FULL,
					`this server has already made ${MAX_ROOM_LINKS} room names durable`,
				);
			}
			const next = new Map(this.#linked);
			const nextRevoked = new Map(this.#revoked);
			const nextGenerations = new Map(this.#linkGenerations);
			if (!next.has(key) && nextRevoked.has(key)) {
				const generation = (nextGenerations.get(key) ?? 0) + 1;
				if (generation > Number.MAX_SAFE_INTEGER) {
					throw new Error(`room "${name}" has exhausted link generations`);
				}
				nextGenerations.set(key, generation);
				nextRevoked.delete(key);
			}
			next.set(key, name);
			const nextStewards = new Map(this.#stewards);
			const nextManagers = new Map(this.#managers);
			const nextManagedRooms = new Map(this.#managedRooms);
			const nextTopics = new Map(this.#topics);
			if (topic != null && topic !== "" && !nextTopics.has(key)) {
				if (nextTopics.size === MAX_ROOM_LINKS) {
					throw new Error(`this server remembers topics for at most ${MAX_ROOM_LINKS} rooms`);
				}
				nextTopics.set(key, { name, topic });
			}
			if (steward && nextStewards.get(key)?.issued !== true) {
				const existing = nextStewards.get(key);
				const generation = existing == null ? 1 : existing.generation + 1;
				if (generation > Number.MAX_SAFE_INTEGER) {
					throw new Error(`room "${name}" has exhausted stewardship generations`);
				}
				nextStewards.set(
					key,
					existing == null ? { name, generation, issued: true } : {
						...existing,
						name,
						generation,
						issued: true,
					},
				);
			}
			if (manager && nextManagers.get(key)?.issued !== true) {
				const existing = nextManagers.get(key);
				const generation = existing == null ? 1 : existing.generation + 1;
				if (generation > Number.MAX_SAFE_INTEGER) {
					throw new Error(`room "${name}" exhausted manager generations`);
				}
				nextManagers.set(key, { name, generation, issued: true });
			}
			if (managed != null) nextManagedRooms.set(key, { id: name, generation: 1, ...managed });
			await this.#write(this.#document({
				linkedRooms: [...next.values()],
				revokedRooms: [...nextRevoked.values()],
				roomLinkGenerations: this.#generationRows(nextGenerations, next, nextRevoked),
				stewards: [...nextStewards.values()],
				managers: [...nextManagers.values()],
				managedRooms: [...nextManagedRooms.values()],
				topics: [...nextTopics.values()],
			}));
			this.#linked.clear();
			for (const [roomKey, room] of next) this.#linked.set(roomKey, room);
			this.#revoked.clear();
			for (const [roomKey, room] of nextRevoked) this.#revoked.set(roomKey, room);
			this.#linkGenerations.clear();
			for (const [roomKey, generation] of nextGenerations) this.#linkGenerations.set(roomKey, generation);
			this.#stewards.clear();
			for (const [roomKey, room] of nextStewards) this.#stewards.set(roomKey, room);
			this.#managers.clear();
			for (const [roomKey, room] of nextManagers) this.#managers.set(roomKey, room);
			this.#managedRooms.clear();
			this.#managedRoomByName.clear();
			for (const [roomKey, room] of nextManagedRooms) {
				this.#managedRooms.set(roomKey, room);
				if (roomIsListed(room.policy)) this.#managedRoomByName.set(room.name.toLowerCase(), room.id);
			}
			this.#topics.clear();
			for (const [topicKey, value] of nextTopics) this.#topics.set(topicKey, value);
			this.#changed();
		});
		this.#writeTail = run.catch(() => {});
		return run;
	}

	/** Tombstone the current room publication generation. The name stays in the
	 * bounded registry until a later issue advances its generation; the old
	 * generation then remains permanently inactive while the new one gets an
	 * unrelated swiss. */
	revokeRoomLink(name: string): Promise<void> {
		const run = this.#writeTail.then(async () => {
			const key = name.toLowerCase();
			const held = this.#linked.get(key);
			if (held == null) throw new RoomError(NO_SUCH_ROOM, `this server has no room link for "${name}"`);
			const linked = new Map(this.#linked);
			linked.delete(key);
			const revoked = new Map(this.#revoked);
			revoked.set(key, held);
			const stewards = new Map(this.#stewards);
			stewards.delete(key);
			const forgetTopic = isManagedRoomId(held) && !this.#managedRooms.has(key);
			const topics = forgetTopic
				? [...this.#topics.values()].filter((value) => value.name.toLowerCase() !== key)
				: [...this.#topics.values()];
			await this.#write(this.#document({
				linkedRooms: [...linked.values()],
				revokedRooms: [...revoked.values()],
				roomLinkGenerations: this.#generationRows(this.#linkGenerations, linked, revoked),
				stewards: [...stewards.values()],
				topics,
			}));
			this.#linked.clear();
			for (const [entryKey, value] of linked) this.#linked.set(entryKey, value);
			this.#revoked.clear();
			for (const [entryKey, value] of revoked) this.#revoked.set(entryKey, value);
			this.#stewards.clear();
			for (const [entryKey, value] of stewards) this.#stewards.set(entryKey, value);
			if (forgetTopic) this.#topics.delete(key);
			this.#changed();
		});
		this.#writeTail = run.catch(() => {});
		return run;
	}

	/** Rotate the durable authority domain and clear its complete registry while
	 * preserving the Host identity. Old links derive from the retired secret and
	 * can never collide with authorities minted after this reset. */
	factoryResetAuthorities(): Promise<void> {
		const run = this.#writeTail.then(async () => {
			const secret = crypto.getRandomValues(new Uint8Array(ROOM_STATE_KEY_BYTES));
			const topics = [...this.#topics.values()].filter((topic) => !isManagedRoomId(topic.name));
			await this.#write(this.#document({
				roomLinkSecret: encodeRoomStateHex(secret),
				linkedRooms: [],
				revokedRooms: [],
				roomLinkGenerations: [],
				stewards: [],
				managers: [],
				managedRooms: [],
				topics,
			}));
			this.#secret = secret;
			this.#linked.clear();
			this.#revoked.clear();
			this.#linkGenerations.clear();
			this.#stewards.clear();
			this.#managers.clear();
			this.#managedRooms.clear();
			this.#managedRoomByName.clear();
			this.#topics.clear();
			for (const topic of topics) this.#topics.set(topic.name.toLowerCase(), topic);
			this.#changed();
		});
		this.#writeTail = run.catch(() => {});
		return run;
	}

	/** Invalidate the issued generation before the operator hears success. The
	 * old durable behavior consults this state on every call, so live imports
	 * and later redemptions lose authority together. A later issue uses the next
	 * generation's unrelated swiss. */
	revokeSteward(name: string): Promise<number> {
		let generation = 0;
		const run = this.#writeTail.then(async () => {
			const key = name.toLowerCase();
			const existing = this.#stewards.get(key);
			if (existing?.issued !== true) {
				throw new RoomError(NOT_STEWARD, `room "${name}" has no issued stewardship`);
			}
			if (existing.generation === Number.MAX_SAFE_INTEGER) {
				throw new Error(`room "${name}" has exhausted stewardship generations`);
			}
			generation = existing.generation + 1;
			const nextStewards = new Map(this.#stewards);
			nextStewards.set(key, { name: existing.name, generation, issued: false });
			await this.#write(this.#document({
				stewards: [...nextStewards.values()],
			}));
			this.#stewards.clear();
			for (const [roomKey, steward] of nextStewards) this.#stewards.set(roomKey, steward);
			this.#changed();
		});
		this.#writeTail = run.catch(() => {});
		return run.then(() => generation);
	}

	revokeManager(name: string): Promise<number> {
		let generation = 0;
		const run = this.#writeTail.then(async () => {
			const key = name.toLowerCase();
			const existing = this.#managers.get(key);
			if (existing?.issued !== true) throw new Error(`room "${name}" has no current manager capability`);
			if (existing.generation === Number.MAX_SAFE_INTEGER) {
				throw new Error(`room "${name}" exhausted manager generations`);
			}
			generation = existing.generation + 1;
			const managers = new Map(this.#managers);
			managers.set(key, { name: existing.name, generation, issued: false });
			await this.#write(this.#document({
				managers: [...managers.values()],
			}));
			this.#managers.clear();
			for (const [roomKey, manager] of managers) this.#managers.set(roomKey, manager);
			this.#changed();
		});
		this.#writeTail = run.catch(() => {});
		return run.then(() => generation);
	}

	#document(overrides: Partial<RoomServerDiskState> = {}): RoomServerDiskState {
		return {
			version: ROOM_STATE_VERSION,
			identitySeed: encodeRoomStateHex(this.#identitySeed),
			roomLinkSecret: encodeRoomStateHex(this.#secret),
			linkedRooms: [...this.#linked.values()],
			revokedRooms: [...this.#revoked.values()],
			roomLinkGenerations: this.#generationRows(),
			stewards: [...this.#stewards.values()],
			managers: [...this.#managers.values()],
			managedRooms: [...this.#managedRooms.values()],
			topics: [...this.#topics.values()],
			...overrides,
		};
	}

	async #write(disk: RoomServerDiskState): Promise<void> {
		const parsed = validateRoomServerDocument(disk, "rooms state change is invalid");
		if (this.#directory === null) return;
		const path = `${this.#directory}/${ROOM_STATE_FILE}`;
		await atomicWrite(path, encoder.encode(JSON.stringify(parsed) + "\n"));
	}
}
