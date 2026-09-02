// Durable identity for the member-owned archive peer.
//
// A Host seed retains the peer identity; separate durable-publication entropy
// retains the archive's swiss authority. Both must survive together or a
// restart would produce a locator that looks familiar while answering a
// different capability (or vice versa).

import { DURABLE_SWISS_ENTROPY_BYTES } from "@glowcap/runtime";
import * as z from "zod/mini";
import { readBoundedText } from "../lib/durable_file.ts";
import { fixedHex } from "../lib/schema.ts";
import { atomicWrite } from "./file_io.ts";

const FILE = "peer.json";
const VERSION = 1;
const IDENTITY_BYTES = 32;
const MAX_STATE_BYTES = 4096;

export const ArchivePeerDiskStateSchema = z.strictObject({
	version: z.literal(VERSION),
	identitySeed: fixedHex(IDENTITY_BYTES),
	archiveEntropy: fixedHex(DURABLE_SWISS_ENTROPY_BYTES),
});

type DiskState = z.infer<typeof ArchivePeerDiskStateSchema>;

function hex(bytes: Uint8Array): string {
	return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function unhex(value: unknown, bytes: number, field: string): Uint8Array<ArrayBuffer> {
	if (typeof value !== "string" || value.length !== bytes * 2 || !/^[0-9a-f]+$/.test(value)) {
		throw new Error(`archive peer state has an invalid ${field}`);
	}
	const out = new Uint8Array(bytes);
	for (let at = 0; at < bytes; at += 1) out[at] = Number.parseInt(value.slice(at * 2, at * 2 + 2), 16);
	return out;
}

function fresh(): DiskState {
	return {
		version: VERSION,
		identitySeed: hex(crypto.getRandomValues(new Uint8Array(IDENTITY_BYTES))),
		archiveEntropy: hex(crypto.getRandomValues(new Uint8Array(DURABLE_SWISS_ENTROPY_BYTES))),
	};
}

function parse(text: string): DiskState {
	let decoded: unknown;
	try {
		decoded = JSON.parse(text);
	} catch {
		throw new Error("archive peer state is not JSON");
	}
	if (typeof decoded === "object" && decoded != null && (decoded as { version?: unknown }).version !== VERSION) {
		throw new Error(
			`archive peer state version ${String((decoded as { version?: unknown }).version)} is not supported`,
		);
	}
	const parsed = z.safeParse(ArchivePeerDiskStateSchema, decoded);
	if (!parsed.success) throw new Error(`archive peer state is invalid:\n${z.prettifyError(parsed.error)}`);
	return parsed.data;
}

async function writeAtomic(directory: string, disk: DiskState): Promise<void> {
	await atomicWrite(`${directory}/${FILE}`, new TextEncoder().encode(JSON.stringify(disk) + "\n"));
}

export class ArchivePeerState {
	readonly #identitySeed: Uint8Array<ArrayBuffer>;
	readonly #archiveEntropy: Uint8Array<ArrayBuffer>;

	private constructor(disk: DiskState) {
		this.#identitySeed = unhex(disk.identitySeed, IDENTITY_BYTES, "identity seed");
		this.#archiveEntropy = unhex(
			disk.archiveEntropy,
			DURABLE_SWISS_ENTROPY_BYTES,
			"archive publication entropy",
		);
	}

	get identitySeed(): Uint8Array<ArrayBuffer> {
		return this.#identitySeed.slice();
	}

	get archiveEntropy(): Uint8Array<ArrayBuffer> {
		return this.#archiveEntropy.slice();
	}

	static async open(directory: string): Promise<ArchivePeerState> {
		await Deno.mkdir(directory, { recursive: true, mode: 0o700 });
		try {
			return new ArchivePeerState(
				parse(await readBoundedText(`${directory}/${FILE}`, MAX_STATE_BYTES, "archive peer state")),
			);
		} catch (error) {
			if (!(error instanceof Deno.errors.NotFound)) throw error;
			const disk = fresh();
			await writeAtomic(directory, disk);
			return new ArchivePeerState(disk);
		}
	}
}
