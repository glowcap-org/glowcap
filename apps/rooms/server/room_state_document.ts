// Schema and serialization vocabulary for the durable Rooms server document.

import * as z from "zod/mini";
import { isManagedRoomId, MAX_DURABLE_ROOM, MAX_ROOM, MAX_ROOM_LINKS, MAX_TOPIC } from "../lib/limits.ts";
import { type RoomPolicy, RoomPolicySchema } from "../lib/room/policy.ts";
import { fixedHex, nonemptyText, nonnegativeSafeInteger, positiveSafeInteger } from "../lib/schema.ts";

export const ROOM_STATE_FILE = "rooms.json";
export const ROOM_STATE_VERSION = 1;
export const ROOM_STATE_KEY_BYTES = 32;
export const MAX_ROOM_STATE_BYTES = 4 * 1024 * 1024;

const durableRoomName = nonemptyText(MAX_DURABLE_ROOM);
const boundedTopic = nonemptyText(MAX_TOPIC);
const roomName = nonemptyText(MAX_ROOM);

const StewardStateSchema = z.strictObject({
	name: durableRoomName,
	generation: nonnegativeSafeInteger,
	issued: z.boolean(),
});

const RoomLinkGenerationSchema = z.strictObject({
	name: durableRoomName,
	generation: positiveSafeInteger,
});

const DurableStewardStateSchema = z.strictObject({
	name: durableRoomName,
	generation: positiveSafeInteger,
	issued: z.boolean(),
});

const RoomTopicStateSchema = z.strictObject({
	name: durableRoomName,
	topic: boundedTopic,
});

const ManagedRoomStateSchema = z.strictObject({
	id: durableRoomName.check(z.refine(isManagedRoomId)),
	name: roomName,
	generation: positiveSafeInteger,
	policy: RoomPolicySchema,
});

const RoomServerDiskStateShapeSchema = z.strictObject({
	version: z.literal(ROOM_STATE_VERSION),
	identitySeed: fixedHex(ROOM_STATE_KEY_BYTES),
	roomLinkSecret: fixedHex(ROOM_STATE_KEY_BYTES),
	linkedRooms: z.array(durableRoomName).check(z.maxLength(MAX_ROOM_LINKS)),
	revokedRooms: z.array(durableRoomName).check(z.maxLength(MAX_ROOM_LINKS)),
	roomLinkGenerations: z.array(RoomLinkGenerationSchema).check(z.maxLength(MAX_ROOM_LINKS)),
	stewards: z.array(DurableStewardStateSchema).check(z.maxLength(MAX_ROOM_LINKS)),
	managers: z.array(DurableStewardStateSchema).check(z.maxLength(MAX_ROOM_LINKS)),
	managedRooms: z.array(ManagedRoomStateSchema).check(z.maxLength(MAX_ROOM_LINKS)),
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
	const managed = new Set<string>();
	for (const manager of disk.managers) {
		const key = manager.name.toLowerCase();
		if ((!linked.has(key) && !revoked.has(key)) || managed.has(key)) return false;
		managed.add(key);
	}
	const managedRooms = new Set<string>();
	const listedNames = new Set<string>();
	for (const room of disk.managedRooms) {
		const key = room.id.toLowerCase();
		const publicName = room.name.toLowerCase();
		if (!managed.has(key) || managedRooms.has(key)) return false;
		if (room.policy.visibility === "listed" && listedNames.has(publicName)) return false;
		managedRooms.add(key);
		if (room.policy.visibility === "listed") listedNames.add(publicName);
	}
	const generations = new Set<string>();
	for (const row of disk.roomLinkGenerations) {
		const key = row.name.toLowerCase();
		if ((!linked.has(key) && !revoked.has(key)) || generations.has(key)) return false;
		generations.add(key);
	}
	const topics = new Set<string>();
	for (const topic of disk.topics) {
		const key = topic.name.toLowerCase();
		if ((isManagedRoomId(topic.name) && !linked.has(key)) || topics.has(key)) return false;
		topics.add(key);
	}
	return true;
}

const RoomServerDiskStateSchema = RoomServerDiskStateShapeSchema.check(
	z.refine(hasValidAuthorityRelations, "linked, revoked, and stewarded room authority is inconsistent"),
);

export type StewardState = z.infer<typeof StewardStateSchema>;
export interface ManagedRoomState {
	readonly id: string;
	readonly name: string;
	readonly generation: number;
	readonly policy: RoomPolicy;
}
export type RoomTopicState = z.infer<typeof RoomTopicStateSchema>;
export type RoomServerDiskState = z.infer<typeof RoomServerDiskStateSchema>;

export function encodeRoomStateHex(bytes: Uint8Array): string {
	return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function decodeRoomStateHex(value: string, bytes: number, field: string): Uint8Array<ArrayBuffer> {
	if (value.length !== bytes * 2 || !/^[0-9a-f]+$/.test(value)) {
		throw new Error(`rooms state has an invalid ${field}`);
	}
	const out = new Uint8Array(bytes);
	for (let i = 0; i < bytes; i++) out[i] = Number.parseInt(value.slice(i * 2, i * 2 + 2), 16);
	return out;
}

export function freshRoomServerDocument(): RoomServerDiskState {
	return {
		version: ROOM_STATE_VERSION,
		identitySeed: encodeRoomStateHex(crypto.getRandomValues(new Uint8Array(ROOM_STATE_KEY_BYTES))),
		roomLinkSecret: encodeRoomStateHex(crypto.getRandomValues(new Uint8Array(ROOM_STATE_KEY_BYTES))),
		linkedRooms: [],
		revokedRooms: [],
		roomLinkGenerations: [],
		stewards: [],
		managers: [],
		managedRooms: [],
		topics: [],
	};
}

export function parseRoomServerDocument(text: string): RoomServerDiskState {
	let decoded: unknown;
	try {
		decoded = JSON.parse(text);
	} catch {
		throw new Error("rooms state is not JSON");
	}
	const version = typeof decoded === "object" && decoded != null ? (decoded as { version?: unknown }).version : null;
	if (version !== ROOM_STATE_VERSION) {
		throw new Error(`rooms state version ${String(version)} is not supported`);
	}
	return validateRoomServerDocument(decoded, "rooms state is invalid");
}

export function validateRoomServerDocument(value: unknown, message: string): RoomServerDiskState {
	const parsed = z.safeParse(RoomServerDiskStateSchema, value);
	if (!parsed.success) throw new Error(`${message}:\n${z.prettifyError(parsed.error)}`);
	return parsed.data;
}
