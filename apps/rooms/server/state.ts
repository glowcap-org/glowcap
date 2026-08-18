// Durable application state for room sturdyrefs.
//
// The portable Host owns no filesystem, by design. Its restart contract is
// instead reproducibility: an embedder that restores the same publication name
// and Host identity restores the same sturdyref. Rooms is that embedder. It
// keeps one identity seed, one HMAC key, and the small set of room names for
// which somebody explicitly asked for a link. Message history and live room
// membership remain deliberately ephemeral.

import { DURABLE_SWISS_ENTROPY_BYTES } from "@pancake/runtime";
import { ROOM_LINKS_FULL, RoomError } from "../lib/errors.ts";
import { MAX_DURABLE_ROOM, MAX_ROOM_LINKS } from "../lib/limits.ts";

const FILE = "rooms.json";
const VERSION = 1;
const KEY_BYTES = 32;
const encoder = new TextEncoder();

interface DiskState {
	version: typeof VERSION;
	identitySeed: string;
	roomLinkSecret: string;
	linkedRooms: string[];
}

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
	};
}

function parseState(text: string): DiskState {
	const value: unknown = JSON.parse(text);
	if (typeof value !== "object" || value === null) throw new Error("rooms state is not an object");
	const row = value as Partial<DiskState>;
	if (row.version !== VERSION) throw new Error(`rooms state version ${String(row.version)} is not supported`);
	unhex(String(row.identitySeed ?? ""), KEY_BYTES, "identity seed");
	unhex(String(row.roomLinkSecret ?? ""), KEY_BYTES, "room-link secret");
	if (
		!Array.isArray(row.linkedRooms) ||
		row.linkedRooms.length > MAX_ROOM_LINKS ||
		row.linkedRooms.some((name) => typeof name !== "string" || name.length === 0 || name.length > MAX_DURABLE_ROOM)
	) {
		throw new Error("rooms state has invalid linked room names");
	}
	const keys = new Set<string>();
	for (const name of row.linkedRooms) {
		const key = name.toLowerCase();
		if (keys.has(key)) throw new Error(`rooms state repeats linked room "${name}"`);
		keys.add(key);
	}
	return row as DiskState;
}

/** The state a Rooms server restores. With no directory it is intentionally
 * process-local, preserving the application's existing ephemeral default. */
export class RoomServerState {
	readonly identitySeed: Uint8Array<ArrayBuffer>;
	readonly #secret: Uint8Array<ArrayBuffer>;
	readonly #directory: string | null;
	readonly #linked = new Map<string, string>();
	#writeTail: Promise<void> = Promise.resolve();

	private constructor(disk: DiskState, directory: string | null) {
		this.identitySeed = unhex(disk.identitySeed, KEY_BYTES, "identity seed");
		this.#secret = unhex(disk.roomLinkSecret, KEY_BYTES, "room-link secret");
		this.#directory = directory;
		for (const name of disk.linkedRooms) this.#linked.set(name.toLowerCase(), name);
	}

	static async open(directory?: string): Promise<RoomServerState> {
		if (!directory) return new RoomServerState(freshState(), null);
		await Deno.mkdir(directory, { recursive: true, mode: 0o700 });
		const path = `${directory}/${FILE}`;
		try {
			return new RoomServerState(parseState(await Deno.readTextFile(path)), directory);
		} catch (err) {
			if (!(err instanceof Deno.errors.NotFound)) throw err;
			const disk = freshState();
			const state = new RoomServerState(disk, directory);
			await state.#write(disk);
			return state;
		}
	}

	linkedRooms(): string[] {
		return [...this.#linked.values()];
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
	async entropyFor(name: string): Promise<Uint8Array<ArrayBuffer>> {
		const key = await crypto.subtle.importKey(
			"raw",
			this.#secret,
			{ name: "HMAC", hash: "SHA-256" },
			false,
			["sign"],
		);
		const mac = new Uint8Array(
			await crypto.subtle.sign("HMAC", key, encoder.encode(name.toLowerCase())),
		);
		return mac.slice(0, DURABLE_SWISS_ENTROPY_BYTES);
	}

	/** Persist a newly linked name before its sturdyref is handed out. Writes are
	 * serialized and replace one complete file atomically, so two concurrent link
	 * requests cannot lose one another. */
	remember(name: string): Promise<void> {
		const run = this.#writeTail.then(async () => {
			const key = name.toLowerCase();
			if (this.#linked.has(key)) return;
			if (this.#linked.size >= MAX_ROOM_LINKS) {
				throw new RoomError(
					ROOM_LINKS_FULL,
					`this server has already made ${MAX_ROOM_LINKS} room names durable`,
				);
			}
			const next = new Map(this.#linked);
			next.set(key, name);
			await this.#write({
				version: VERSION,
				identitySeed: hex(this.identitySeed),
				roomLinkSecret: hex(this.#secret),
				linkedRooms: [...next.values()],
			});
			this.#linked.clear();
			for (const [roomKey, room] of next) this.#linked.set(roomKey, room);
		});
		this.#writeTail = run.catch(() => {});
		return run;
	}

	async #write(disk: DiskState): Promise<void> {
		if (this.#directory === null) return;
		const path = `${this.#directory}/${FILE}`;
		const temp = `${path}.tmp-${crypto.randomUUID()}`;
		try {
			await Deno.writeTextFile(temp, JSON.stringify(disk) + "\n", {
				createNew: true,
				mode: 0o600,
			});
			await Deno.rename(temp, path);
		} catch (err) {
			await Deno.remove(temp).catch(() => {});
			throw err;
		}
	}
}

/** How a linked room reaches the Host that will answer for it: mint the durable
 * publication from this room's derived entropy and hand back the swiss name.
 *
 * A room link is Host-wide rather than published onto each accepted session,
 * because a sturdyref is redeemed by whoever holds it — including a peer whose
 * session opened after the link was minted, and who never asks the directory
 * anything. The turn the redemption arrives on names the caller. */
type PublishRoomLink = (name: string, entropy: Uint8Array) => string;

/** The stable-name index over RoomServerState: which room names this server has
 * made durable, and the swiss each of them answers to. */
export class RoomLinks {
	readonly #state: RoomServerState;
	readonly #publish: PublishRoomLink;
	readonly #swiss = new Map<string, string>();
	#linkTail: Promise<void> = Promise.resolve();

	private constructor(state: RoomServerState, publish: PublishRoomLink) {
		this.#state = state;
		this.#publish = publish;
	}

	/** Republish every room name this server made durable before its last stop.
	 * Deriving each one's entropy from the restored key is what makes these the
	 * same sturdyrefs the previous process handed out. */
	static async restore(state: RoomServerState, publish: PublishRoomLink): Promise<RoomLinks> {
		const links = new RoomLinks(state, publish);
		for (const name of state.linkedRooms()) {
			links.#swiss.set(name.toLowerCase(), publish(name, await state.entropyFor(name)));
		}
		return links;
	}

	/** The durable names this server has published, with the swiss each answers
	 * to. The inspect capability lists these as real OCapN names, not as labels. */
	named(): ReadonlyArray<{ name: string; swiss: string }> {
		const out: { name: string; swiss: string }[] = [];
		for (const name of this.#state.linkedRooms()) {
			const swiss = this.#swiss.get(name.toLowerCase());
			if (swiss !== undefined) out.push({ name, swiss });
		}
		return out;
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
	link(name: string): Promise<string> {
		let swiss = "";
		const run = this.#linkTail.then(async () => {
			const key = name.toLowerCase();
			const existing = this.#swiss.get(key);
			if (existing !== undefined) {
				swiss = existing;
				return;
			}
			const entropy = await this.#state.entropyFor(name);
			await this.#state.remember(name);
			swiss = this.#publish(name, entropy);
			this.#swiss.set(key, swiss);
		});
		this.#linkTail = run.catch(() => {});
		return run.then(() => swiss);
	}
}
