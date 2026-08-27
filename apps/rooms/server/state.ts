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
import * as z from "zod/mini";
import { NO_SUCH_ROOM, NOT_STEWARD, ROOM_LINKS_FULL, RoomError } from "../lib/errors.ts";
import { isPrivateRoomKey, MAX_DURABLE_ROOM, MAX_ROOM_LINKS, MAX_TOPIC } from "../lib/limits.ts";
import { fixedHex, nonemptyText, nonnegativeSafeInteger, positiveSafeInteger } from "../lib/schema.ts";
import { atomicWrite, readBoundedText } from "../lib/durable_file.ts";
import { noteOperatorChange } from "./operator/revision.ts";

const FILE = "rooms.json";
const VERSION = 1;
const KEY_BYTES = 32;
const MAX_STATE_BYTES = 4 * 1024 * 1024;
const encoder = new TextEncoder();

const STEWARD_DOMAIN = "steward\u0000";

export class RoomServerStateError extends Error {}

const durableRoomName = nonemptyText(MAX_DURABLE_ROOM);
const boundedTopic = nonemptyText(MAX_TOPIC);

export const StewardStateSchema = z.strictObject({
	name: durableRoomName,
	generation: nonnegativeSafeInteger,
	issued: z.boolean(),
});

const DurableStewardStateSchema = z.strictObject({
	name: durableRoomName,
	generation: positiveSafeInteger,
	issued: z.boolean(),
});

export const RoomTopicStateSchema = z.strictObject({
	name: durableRoomName,
	topic: boundedTopic,
});

const RoomServerDiskStateShapeSchema = z.strictObject({
	version: z.literal(VERSION),
	identitySeed: fixedHex(KEY_BYTES),
	roomLinkSecret: fixedHex(KEY_BYTES),
	linkedRooms: z.array(durableRoomName).check(z.maxLength(MAX_ROOM_LINKS)),
	revokedRooms: z.array(durableRoomName).check(z.maxLength(MAX_ROOM_LINKS)),
	stewards: z.array(DurableStewardStateSchema).check(z.maxLength(MAX_ROOM_LINKS)),
	topics: z.array(RoomTopicStateSchema).check(z.maxLength(MAX_ROOM_LINKS)),
});

type RoomServerDiskStateShape = z.infer<typeof RoomServerDiskStateShapeSchema>;

function hasValidAuthorityRelations(disk: RoomServerDiskStateShape): boolean {
	const linked = new Set<string>();
	for (const name of disk.linkedRooms) {
		const key = name.toLowerCase();
		if (linked.has(key)) return false;
		linked.add(key);
	}
	const revoked = new Set<string>();
	for (const name of disk.revokedRooms) {
		const key = name.toLowerCase();
		if (linked.has(key) || revoked.has(key)) return false;
		revoked.add(key);
	}
	const stewarded = new Set<string>();
	for (const steward of disk.stewards) {
		const key = steward.name.toLowerCase();
		if (!linked.has(key) || stewarded.has(key)) return false;
		stewarded.add(key);
	}
	const topics = new Set<string>();
	for (const topic of disk.topics) {
		const key = topic.name.toLowerCase();
		if ((isPrivateRoomKey(topic.name) && !linked.has(key)) || topics.has(key)) return false;
		topics.add(key);
	}
	return true;
}

export const RoomServerDiskStateSchema = RoomServerDiskStateShapeSchema.check(
	z.refine(hasValidAuthorityRelations, "linked, revoked, and stewarded room authority is inconsistent"),
);

export type StewardState = z.infer<typeof StewardStateSchema>;
export type RoomTopicState = z.infer<typeof RoomTopicStateSchema>;
type DiskState = z.infer<typeof RoomServerDiskStateSchema>;

function hex(bytes: Uint8Array): string {
	return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function unhex(value: string, bytes: number, field: string): Uint8Array<ArrayBuffer> {
	if (value.length !== bytes * 2 || !/^[0-9a-f]+$/.test(value)) {
		throw new Error(`rooms state has an invalid ${field}`);
	}
	const out = new Uint8Array(bytes);
	for (let i = 0; i < bytes; i++) out[i] = Number.parseInt(value.slice(i * 2, i * 2 + 2), 16);
	return out;
}

function freshState(): DiskState {
	return {
		version: VERSION,
		identitySeed: hex(crypto.getRandomValues(new Uint8Array(KEY_BYTES))),
		roomLinkSecret: hex(crypto.getRandomValues(new Uint8Array(KEY_BYTES))),
		linkedRooms: [],
		revokedRooms: [],
		stewards: [],
		topics: [],
	};
}

function parseState(text: string): DiskState {
	let decoded: unknown;
	try {
		decoded = JSON.parse(text);
	} catch {
		throw new Error("rooms state is not JSON");
	}
	const version = typeof decoded === "object" && decoded != null ? (decoded as { version?: unknown }).version : null;
	if (version !== VERSION) {
		throw new Error(`rooms state version ${String(version)} is not supported`);
	}
	const parsed = z.safeParse(RoomServerDiskStateSchema, decoded);
	if (!parsed.success) throw new Error(`rooms state is invalid:\n${z.prettifyError(parsed.error)}`);
	return parsed.data;
}

/** The state a Rooms server restores. With no directory it is intentionally
 * process-local, preserving the application's existing ephemeral default. */
export class RoomServerState {
	readonly #identitySeed: Uint8Array<ArrayBuffer>;
	#secret: Uint8Array<ArrayBuffer>;
	readonly #directory: string | null;
	readonly #linked = new Map<string, string>();
	readonly #revoked = new Map<string, string>();
	readonly #stewards = new Map<string, StewardState>();
	readonly #topics = new Map<string, { name: string; topic: string }>();
	#writeTail: Promise<void> = Promise.resolve();

	private constructor(disk: DiskState, directory: string | null) {
		this.#identitySeed = unhex(disk.identitySeed, KEY_BYTES, "identity seed");
		this.#secret = unhex(disk.roomLinkSecret, KEY_BYTES, "room-link secret");
		this.#directory = directory;
		for (const name of disk.linkedRooms) this.#linked.set(name.toLowerCase(), name);
		for (const name of disk.revokedRooms) this.#revoked.set(name.toLowerCase(), name);
		for (const steward of disk.stewards) this.#stewards.set(steward.name.toLowerCase(), { ...steward });
		for (const topic of disk.topics) this.#topics.set(topic.name.toLowerCase(), { ...topic });
	}

	get identitySeed(): Uint8Array<ArrayBuffer> {
		return this.#identitySeed.slice();
	}

	static async open(directory?: string): Promise<RoomServerState> {
		if (directory == null) return new RoomServerState(freshState(), null);
		await Deno.mkdir(directory, { recursive: true, mode: 0o700 });
		const path = `${directory}/${FILE}`;
		try {
			return new RoomServerState(
				parseState(await readBoundedText(path, MAX_STATE_BYTES, "rooms state")),
				directory,
			);
		} catch (err) {
			if (!(err instanceof Deno.errors.NotFound)) {
				if (err instanceof RoomServerStateError) throw err;
				throw new RoomServerStateError(err instanceof Error ? err.message : String(err), { cause: err });
			}
			const disk = freshState();
			const state = new RoomServerState(disk, directory);
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

	topic(name: string): string | null {
		return this.#topics.get(name.toLowerCase())?.topic ?? null;
	}

	setTopic(name: string, topic: string): Promise<void> {
		if (topic.length > MAX_TOPIC) throw new Error(`a topic may be at most ${MAX_TOPIC} characters`);
		const run = this.#writeTail.then(async () => {
			const key = name.toLowerCase();
			const durableName = this.#linked.get(key) ?? (isPrivateRoomKey(name) ? null : name);
			if (durableName == null || this.#topics.get(key)?.topic === topic) return;
			const nextTopics = new Map(this.#topics);
			if (topic === "") nextTopics.delete(key);
			else {
				if (!nextTopics.has(key) && nextTopics.size === MAX_ROOM_LINKS) {
					throw new Error(`this server remembers topics for at most ${MAX_ROOM_LINKS} rooms`);
				}
				nextTopics.set(key, { name: durableName, topic });
			}
			await this.#write({
				version: VERSION,
				identitySeed: hex(this.#identitySeed),
				roomLinkSecret: hex(this.#secret),
				linkedRooms: [...this.#linked.values()],
				revokedRooms: [...this.#revoked.values()],
				stewards: [...this.#stewards.values()],
				topics: [...nextTopics.values()],
			});
			this.#topics.clear();
			for (const [topicKey, value] of nextTopics) this.#topics.set(topicKey, value);
			noteOperatorChange();
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
	async roomEntropyFor(name: string): Promise<Uint8Array<ArrayBuffer>> {
		return await this.#entropyFor(name.toLowerCase());
	}

	/** A steward's durable name is reproducible with its room but cannot collide
	 * with, reveal, or be substituted for the room publication itself. */
	async stewardEntropyFor(name: string, generation = this.stewardGeneration(name)): Promise<Uint8Array<ArrayBuffer>> {
		const durable = name.toLowerCase();
		const message = generation === 0 ? STEWARD_DOMAIN + durable : `${STEWARD_DOMAIN}${generation}\u0000${durable}`;
		return await this.#entropyFor(message);
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
		return this.#remember(name, false, topic);
	}

	rememberSteward(name: string, topic?: string): Promise<void> {
		return this.#remember(name, true, topic);
	}

	#remember(name: string, steward: boolean, topic?: string): Promise<void> {
		const run = this.#writeTail.then(async () => {
			const key = name.toLowerCase();
			if (this.#revoked.has(key)) throw new RoomError(NO_SUCH_ROOM, `room link "${name}" was revoked`);
			const needsTopic = topic != null && topic !== "" && !this.#topics.has(key);
			if (this.#linked.has(key) && (!steward || this.#stewards.get(key)?.issued === true) && !needsTopic) return;
			if (!this.#linked.has(key) && this.#linked.size + this.#revoked.size >= MAX_ROOM_LINKS) {
				throw new RoomError(
					ROOM_LINKS_FULL,
					`this server has already made ${MAX_ROOM_LINKS} room names durable`,
				);
			}
			const next = new Map(this.#linked);
			next.set(key, name);
			const nextStewards = new Map(this.#stewards);
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
			await this.#write({
				version: VERSION,
				identitySeed: hex(this.#identitySeed),
				roomLinkSecret: hex(this.#secret),
				linkedRooms: [...next.values()],
				revokedRooms: [...this.#revoked.values()],
				stewards: [...nextStewards.values()],
				topics: [...nextTopics.values()],
			});
			this.#linked.clear();
			for (const [roomKey, room] of next) this.#linked.set(roomKey, room);
			this.#stewards.clear();
			for (const [roomKey, room] of nextStewards) this.#stewards.set(roomKey, room);
			this.#topics.clear();
			for (const [topicKey, value] of nextTopics) this.#topics.set(topicKey, value);
			noteOperatorChange();
		});
		this.#writeTail = run.catch(() => {});
		return run;
	}

	/** Permanently tombstone one room publication. Keeping the name prevents a
	 * later mint from recreating the same derived swiss and reviving old copies. */
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
			const topics = isPrivateRoomKey(held)
				? [...this.#topics.values()].filter((value) => value.name.toLowerCase() !== key)
				: [...this.#topics.values()];
			await this.#write({
				version: VERSION,
				identitySeed: hex(this.#identitySeed),
				roomLinkSecret: hex(this.#secret),
				linkedRooms: [...linked.values()],
				revokedRooms: [...revoked.values()],
				stewards: [...stewards.values()],
				topics,
			});
			this.#linked.clear();
			for (const [entryKey, value] of linked) this.#linked.set(entryKey, value);
			this.#revoked.clear();
			for (const [entryKey, value] of revoked) this.#revoked.set(entryKey, value);
			this.#stewards.clear();
			for (const [entryKey, value] of stewards) this.#stewards.set(entryKey, value);
			if (isPrivateRoomKey(held)) this.#topics.delete(key);
			noteOperatorChange();
		});
		this.#writeTail = run.catch(() => {});
		return run;
	}

	/** Rotate the durable authority domain and clear its complete registry while
	 * preserving the Host identity. Old links derive from the retired secret and
	 * can never collide with authorities minted after this reset. */
	factoryResetAuthorities(): Promise<void> {
		const run = this.#writeTail.then(async () => {
			const secret = crypto.getRandomValues(new Uint8Array(KEY_BYTES));
			const topics = [...this.#topics.values()].filter((topic) => !isPrivateRoomKey(topic.name));
			await this.#write({
				version: VERSION,
				identitySeed: hex(this.#identitySeed),
				roomLinkSecret: hex(secret),
				linkedRooms: [],
				revokedRooms: [],
				stewards: [],
				topics,
			});
			this.#secret = secret;
			this.#linked.clear();
			this.#revoked.clear();
			this.#stewards.clear();
			this.#topics.clear();
			for (const topic of topics) this.#topics.set(topic.name.toLowerCase(), topic);
			noteOperatorChange();
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
			await this.#write({
				version: VERSION,
				identitySeed: hex(this.#identitySeed),
				roomLinkSecret: hex(this.#secret),
				linkedRooms: [...this.#linked.values()],
				revokedRooms: [...this.#revoked.values()],
				stewards: [...nextStewards.values()],
				topics: [...this.#topics.values()],
			});
			this.#stewards.clear();
			for (const [roomKey, steward] of nextStewards) this.#stewards.set(roomKey, steward);
			noteOperatorChange();
		});
		this.#writeTail = run.catch(() => {});
		return run.then(() => generation);
	}

	async #write(disk: DiskState): Promise<void> {
		const parsed = z.safeParse(RoomServerDiskStateSchema, disk);
		if (!parsed.success) throw new Error(`rooms state change is invalid:\n${z.prettifyError(parsed.error)}`);
		if (this.#directory === null) return;
		const path = `${this.#directory}/${FILE}`;
		await atomicWrite(path, encoder.encode(JSON.stringify(parsed.data) + "\n"));
	}
}
