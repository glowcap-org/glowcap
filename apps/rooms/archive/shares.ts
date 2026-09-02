// Durable, independently revocable archive-peer shares and their publications.

import { DURABLE_SWISS_ENTROPY_BYTES } from "@glowcap/runtime";
import * as z from "zod/mini";
import { atomicWrite, readBoundedText } from "../lib/durable_file.ts";
import { type ArchiveFilter, archiveFilterRow, parseArchiveFilter } from "../lib/archive/protocol.ts";
import { RoomsSessionGrantIdSchema, RoomsSessionGrantLabelSchema } from "../lib/session/grants.ts";
import { MAX_ACTIVE_ARCHIVE_SHARES, MAX_LIFETIME_ARCHIVE_SHARES } from "../lib/limits.ts";
import type { ArchiveDurableShareView } from "../lib/archive/facet.ts";

const FILE = "shares.json";
const VERSION = 1;
const MAX_FILE_BYTES = 128 * 1024;
const encoder = new TextEncoder();

const ArchiveFilterDiskSchema = z.strictObject({
	source: z.nullable(z.string()),
	generation: z.nullable(z.string()),
	kind: z.nullable(z.enum(["standing", "line"])),
	conversationKind: z.nullable(z.enum(["room", "direct"])),
	directory: z.nullable(z.string()),
	conversation: z.nullable(z.string()),
	digest: z.nullable(z.string()),
});

export const ArchiveShareRecordSchema = z.strictObject({
	id: RoomsSessionGrantIdSchema,
	label: RoomsSessionGrantLabelSchema,
	filter: ArchiveFilterDiskSchema,
	revoked: z.boolean(),
});

const ArchiveShareDiskSchema = z.strictObject({
	version: z.literal(VERSION),
	shares: z.array(ArchiveShareRecordSchema).check(
		z.maxLength(MAX_LIFETIME_ARCHIVE_SHARES),
		z.refine((shares) => new Set(shares.map((share) => share.id)).size === shares.length),
		z.refine((shares) => shares.filter((share) => !share.revoked).length <= MAX_ACTIVE_ARCHIVE_SHARES),
	),
});

export type ArchiveShareRecord = z.infer<typeof ArchiveShareRecordSchema>;

export interface ArchiveSharePublisher {
	publish(share: ArchiveShareRecord, entropy: Uint8Array, active: () => boolean): string;
	unpublish(swiss: string): boolean;
	sturdyref(swiss: string): string;
}

interface ShareDisk {
	version: typeof VERSION;
	shares: ArchiveShareRecord[];
}

function parse(raw: string): ShareDisk {
	let decoded: unknown;
	try {
		decoded = JSON.parse(raw);
	} catch {
		throw new Error("archive share state is not JSON");
	}
	const parsed = z.safeParse(ArchiveShareDiskSchema, decoded);
	if (!parsed.success) throw new Error(`archive share state is invalid:\n${z.prettifyError(parsed.error)}`);
	return parsed.data;
}

function canonicalFilter(filter: ArchiveFilter): ArchiveFilter {
	return parseArchiveFilter(archiveFilterRow(filter));
}

function sameFilter(left: ArchiveFilter, right: ArchiveFilter): boolean {
	return JSON.stringify(archiveFilterRow(left)) === JSON.stringify(archiveFilterRow(right));
}

async function write(directory: string, shares: readonly ArchiveShareRecord[]): Promise<void> {
	const parsed = z.safeParse(ArchiveShareDiskSchema, { version: VERSION, shares });
	if (!parsed.success) {
		throw new Error(`archive peer refused invalid share state:\n${z.prettifyError(parsed.error)}`);
	}
	const bytes = encoder.encode(JSON.stringify(parsed.data) + "\n");
	if (bytes.length > MAX_FILE_BYTES) throw new Error("archive share state exceeds its file ceiling");
	await atomicWrite(`${directory}/${FILE}`, bytes);
}

export class DurableArchiveShares {
	readonly #directory: string;
	readonly #publisher: ArchiveSharePublisher;
	readonly #hmacKey: CryptoKey;
	readonly #shares = new Map<string, ArchiveShareRecord>();
	readonly #swiss = new Map<string, string>();
	#tail: Promise<void> = Promise.resolve();

	private constructor(
		directory: string,
		shares: readonly ArchiveShareRecord[],
		publisher: ArchiveSharePublisher,
		hmacKey: CryptoKey,
	) {
		this.#directory = directory;
		this.#publisher = publisher;
		this.#hmacKey = hmacKey;
		for (const share of shares) this.#shares.set(share.id, share);
	}

	static async open(
		directory: string,
		rootEntropy: Uint8Array,
		publisher: ArchiveSharePublisher,
	): Promise<DurableArchiveShares> {
		if (rootEntropy.length !== DURABLE_SWISS_ENTROPY_BYTES) {
			throw new Error("archive share derivation needs the durable root entropy");
		}
		let disk: ShareDisk;
		try {
			disk = parse(await readBoundedText(`${directory}/${FILE}`, MAX_FILE_BYTES, "archive share state"));
		} catch (error) {
			if (!(error instanceof Deno.errors.NotFound)) throw error;
			disk = { version: VERSION, shares: [] };
			await write(directory, disk.shares);
		}
		const keyBytes = new Uint8Array(rootEntropy.length);
		keyBytes.set(rootEntropy);
		const hmacKey = await crypto.subtle.importKey(
			"raw",
			keyBytes,
			{ name: "HMAC", hash: "SHA-256" },
			false,
			["sign"],
		);
		return new DurableArchiveShares(directory, disk.shares, publisher, hmacKey);
	}

	restore(): Promise<void> {
		return this.#serialize(async () => {
			for (const share of this.#shares.values()) {
				if (!share.revoked) await this.#ensurePublished(share);
			}
		});
	}

	issuer(): {
		issue(id: string, label: string, filter: ArchiveFilter): Promise<string>;
		revoke(id: string): Promise<boolean>;
		list(): Promise<readonly ArchiveDurableShareView[]>;
	} {
		return {
			issue: (id, label, filter) => this.issue(id, label, filter),
			revoke: (id) => this.revoke(id),
			list: () => this.list(),
		};
	}

	list(): Promise<ArchiveDurableShareView[]> {
		return this.#serialize(() => Promise.resolve(this.#snapshot()));
	}

	#snapshot(): ArchiveDurableShareView[] {
		return [...this.#shares.values()].flatMap((share) => {
			if (share.revoked) return [];
			const swiss = this.#swiss.get(share.id);
			if (swiss == null) throw new Error(`archive share ${share.id} is not published`);
			return [{
				id: share.id,
				label: share.label,
				filter: canonicalFilter(share.filter),
				sturdyref: this.#publisher.sturdyref(swiss),
			}];
		});
	}

	issue(id: string, label: string, filter: ArchiveFilter): Promise<string> {
		return this.#serialize(async () => {
			const scoped = canonicalFilter(filter);
			const parsed = z.safeParse(ArchiveShareRecordSchema, {
				id,
				label,
				filter: scoped,
				revoked: false,
			});
			if (!parsed.success) throw new Error(`archive share is invalid:\n${z.prettifyError(parsed.error)}`);
			const requested = parsed.data;
			const existing = this.#shares.get(id);
			if (existing != null) {
				if (existing.revoked) {
					throw new Error("that archive share id has been revoked and cannot be reused");
				}
				if (existing.label !== label || !sameFilter(canonicalFilter(existing.filter), scoped)) {
					throw new Error("that archive share id already names a different share");
				}
				const swiss = await this.#ensurePublished(existing);
				return this.#publisher.sturdyref(swiss);
			}
			if (this.#shares.size >= MAX_LIFETIME_ARCHIVE_SHARES) {
				throw new Error("this archive has exhausted its durable share ledger");
			}
			const active = [...this.#shares.values()].filter((share) => !share.revoked).length;
			if (active >= MAX_ACTIVE_ARCHIVE_SHARES) throw new Error("this archive has too many active shares");
			const next = [...this.#shares.values(), requested];
			await write(this.#directory, next);
			this.#shares.set(id, requested);
			const swiss = await this.#ensurePublished(requested);
			return this.#publisher.sturdyref(swiss);
		});
	}

	revoke(id: string): Promise<boolean> {
		return this.#serialize(async () => {
			const existing = this.#shares.get(id);
			if (existing == null || existing.revoked) return false;
			const revoked = { ...existing, revoked: true };
			const next = [...this.#shares.values()].map((share) => share.id === id ? revoked : share);
			await write(this.#directory, next);
			this.#shares.set(id, revoked);
			const swiss = this.#swiss.get(id);
			let cleanupFailure: unknown | null = null;
			try {
				if (swiss != null) this.#publisher.unpublish(swiss);
			} catch (error) {
				cleanupFailure = error;
			}
			this.#swiss.delete(id);
			if (cleanupFailure != null) {
				throw new Error("the archive share was revoked, but its durable publication cleanup failed", {
					cause: cleanupFailure,
				});
			}
			return true;
		});
	}

	active(id: string): boolean {
		return this.#shares.get(id)?.revoked === false;
	}

	#serialize<T>(work: () => Promise<T>): Promise<T> {
		const run = this.#tail.then(work);
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	async #ensurePublished(share: ArchiveShareRecord): Promise<string> {
		const existing = this.#swiss.get(share.id);
		if (existing != null) return existing;
		const material = encoder.encode(
			`glowcap Rooms archive share\u0000${share.id}\u0000${
				JSON.stringify(archiveFilterRow(canonicalFilter(share.filter)))
			}`,
		);
		const digest = new Uint8Array(await crypto.subtle.sign("HMAC", this.#hmacKey, material));
		const entropy = digest.slice(0, DURABLE_SWISS_ENTROPY_BYTES);
		const swiss = this.#publisher.publish(share, entropy, () => this.active(share.id));
		this.#swiss.set(share.id, swiss);
		return swiss;
	}
}
