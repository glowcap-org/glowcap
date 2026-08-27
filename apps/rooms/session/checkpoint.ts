// Durable file schema for one Rooms session checkpoint and retry ledger.

import { DURABLE_SWISS_ENTROPY_BYTES } from "@pancake/runtime";
import * as z from "zod/mini";
import { atomicWrite, readBoundedText } from "../lib/durable_file.ts";
import { emptyRoomsSessionState, RoomsSessionStateSchema } from "../lib/rooms_state.ts";
import { RoomsSessionWorkspaceAdoptionSchema } from "../lib/rooms_session_adoption.ts";
import { fixedHex, nonnegativeSafeInteger } from "../lib/schema.ts";
import { RECENT_OPERATIONS, RecentOperationSchema } from "./effects.ts";

const FILE = "session.json";
const VERSION = 1;
export const IDENTITY_BYTES = 32;
export const ENTROPY_BYTES = DURABLE_SWISS_ENTROPY_BYTES;
/** The same ceiling is enforced before every write and before every restore.
 * A checkpoint that can be written must therefore be restartable. */
export const MAX_STATE_BYTES = 768 * 1024;

const RoomsSessionDiskStateShapeSchema = z.strictObject({
	version: z.literal(VERSION),
	identitySeed: fixedHex(IDENTITY_BYTES),
	sessionEntropy: fixedHex(ENTROPY_BYTES),
	revision: nonnegativeSafeInteger,
	workspaceAdoption: RoomsSessionWorkspaceAdoptionSchema,
	checkpoint: RoomsSessionStateSchema,
	recent: z.array(RecentOperationSchema).check(z.maxLength(RECENT_OPERATIONS)),
});

export const RoomsSessionDiskStateSchema = RoomsSessionDiskStateShapeSchema.check(
	z.refine(
		(disk) =>
			(disk.workspaceAdoption === "closed" || disk.revision === 0) &&
			new Set(disk.recent.map((operation) => operation.id)).size === disk.recent.length &&
			disk.recent.every((operation) => operation.revision >= 1 && operation.revision <= disk.revision),
		"workspace adoption or recent operations conflict with the checkpoint revision",
	),
);

export type RoomsSessionDiskState = z.infer<typeof RoomsSessionDiskStateSchema>;

/** Freeze validated checkpoint data once at its materialization boundary.
 * Snapshots can then share the graph without exposing an unrevisioned mutation
 * path or cloning it on every read. */
export function freezeCheckpoint(checkpoint: RoomsSessionDiskState["checkpoint"]): RoomsSessionDiskState["checkpoint"] {
	const freeze = (value: unknown): void => {
		if (typeof value !== "object" || value == null || Object.isFrozen(value)) return;
		for (const child of Object.values(value)) freeze(child);
		Object.freeze(value);
	};
	freeze(checkpoint);
	return checkpoint;
}

export function hex(bytes: Uint8Array): string {
	return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function decodeHex(value: unknown, bytes: number, field: string): Uint8Array<ArrayBuffer> {
	if (typeof value !== "string" || value.length !== bytes * 2 || !/^[0-9a-f]+$/.test(value)) {
		throw new Error(`Rooms session state has an invalid ${field}`);
	}
	const out = new Uint8Array(bytes);
	for (let at = 0; at < bytes; at += 1) out[at] = Number.parseInt(value.slice(at * 2, at * 2 + 2), 16);
	return out;
}

function fresh(): RoomsSessionDiskState {
	return {
		version: VERSION,
		identitySeed: hex(crypto.getRandomValues(new Uint8Array(IDENTITY_BYTES))),
		sessionEntropy: hex(crypto.getRandomValues(new Uint8Array(ENTROPY_BYTES))),
		revision: 0,
		workspaceAdoption: "available",
		checkpoint: emptyRoomsSessionState(),
		recent: [],
	};
}

function parse(text: string): RoomsSessionDiskState {
	let decoded: unknown;
	try {
		decoded = JSON.parse(text);
	} catch {
		throw new Error("Rooms session state is not JSON");
	}
	const version = typeof decoded === "object" && decoded != null
		? (decoded as { version?: unknown }).version
		: undefined;
	if (version !== VERSION) {
		throw new Error(`Rooms session state version ${String(version)} is not supported`);
	}
	const parsed = z.safeParse(RoomsSessionDiskStateSchema, decoded);
	if (!parsed.success) throw new Error(`Rooms session state is invalid:\n${z.prettifyError(parsed.error)}`);
	return parsed.data;
}

export async function writeCheckpoint(directory: string, disk: RoomsSessionDiskState): Promise<void> {
	const parsed = z.safeParse(RoomsSessionDiskStateSchema, disk);
	if (!parsed.success) {
		throw new Error(`Rooms session refused invalid checkpoint state:\n${z.prettifyError(parsed.error)}`);
	}
	const bytes = new TextEncoder().encode(JSON.stringify(parsed.data) + "\n");
	if (bytes.length > MAX_STATE_BYTES) {
		throw new Error(`Rooms session state exceeds its ${MAX_STATE_BYTES}-byte ceiling`);
	}
	await atomicWrite(`${directory}/${FILE}`, bytes);
}

export async function openCheckpoint(
	directory: string,
): Promise<{ disk: RoomsSessionDiskState; created: boolean }> {
	try {
		const parsed = parse(await readBoundedText(`${directory}/${FILE}`, MAX_STATE_BYTES, "Rooms session state"));
		const disk = { ...parsed, checkpoint: freezeCheckpoint(parsed.checkpoint) };
		return { disk, created: false };
	} catch (error) {
		if (!(error instanceof Deno.errors.NotFound)) throw error;
		const created = fresh();
		const disk = { ...created, checkpoint: freezeCheckpoint(created.checkpoint) };
		await writeCheckpoint(directory, disk);
		return { disk, created: true };
	}
}
