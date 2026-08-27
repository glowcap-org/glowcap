// Durable, attenuated session grants and their publication lifecycle.

import { DURABLE_SWISS_ENTROPY_BYTES, type Session } from "@pancake/runtime";
import * as z from "zod/mini";
import { atomicWrite, readBoundedText } from "../lib/durable_file.ts";
import {
	type RoomsSessionFacet,
	RoomsSessionFacetSchema,
	RoomsSessionGrantIdSchema,
	RoomsSessionGrantLabelSchema,
	type RoomsSessionGrantView,
} from "../lib/rooms_session_grants.ts";
import { MAX_ACTIVE_SESSION_GRANTS, MAX_LIFETIME_SESSION_GRANTS } from "../lib/limits.ts";

const FILE = "grants.json";
const VERSION = 1;
const MAX_FILE_BYTES = 128 * 1024;
const encoder = new TextEncoder();
export const RoomsSessionGrantRecordSchema = z.strictObject({
	id: RoomsSessionGrantIdSchema,
	label: RoomsSessionGrantLabelSchema,
	rights: RoomsSessionFacetSchema,
	revoked: z.boolean(),
});

const RoomsSessionGrantDiskSchema = z.strictObject({
	version: z.literal(VERSION),
	grants: z.array(RoomsSessionGrantRecordSchema).check(
		z.maxLength(MAX_LIFETIME_SESSION_GRANTS),
		z.refine((grants) => new Set(grants.map((grant) => grant.id)).size === grants.length),
		z.refine((grants) => grants.filter((grant) => !grant.revoked).length <= MAX_ACTIVE_SESSION_GRANTS),
	),
});

export type RoomsSessionGrantRecord = z.infer<typeof RoomsSessionGrantRecordSchema>;
export interface RoomsSessionGrantPublisher {
	publish(
		grant: RoomsSessionGrantRecord,
		entropy: Uint8Array,
		active: () => boolean,
	): string;
	unpublish(swiss: string): boolean;
	sturdyref(session: Session, swiss: string): string;
	revokeLive(id: string): Promise<void>;
}

export interface RoomsSessionGrantAuthority {
	restore(): Promise<void>;
	list(session: Session): RoomsSessionGrantView[];
	issue(id: string, rights: RoomsSessionFacet, label: string, session: Session): Promise<RoomsSessionGrantView>;
	revoke(id: string): Promise<boolean>;
	active(id: string): boolean;
	onChange(listener: () => void): () => void;
}

interface GrantDisk {
	version: typeof VERSION;
	grants: RoomsSessionGrantRecord[];
}

function parse(raw: string): GrantDisk {
	let decoded: unknown;
	try {
		decoded = JSON.parse(raw);
	} catch {
		throw new Error("Rooms session grant state is not JSON");
	}
	const parsed = z.safeParse(RoomsSessionGrantDiskSchema, decoded);
	if (!parsed.success) throw new Error(`Rooms session grant state is invalid:\n${z.prettifyError(parsed.error)}`);
	return parsed.data;
}

async function write(directory: string, grants: readonly RoomsSessionGrantRecord[]): Promise<void> {
	const parsed = z.safeParse(RoomsSessionGrantDiskSchema, { version: VERSION, grants });
	if (!parsed.success) {
		throw new Error(`Rooms session refused invalid grant state:\n${z.prettifyError(parsed.error)}`);
	}
	const bytes = encoder.encode(JSON.stringify(parsed.data) + "\n");
	if (bytes.length > MAX_FILE_BYTES) throw new Error("Rooms session grant state exceeds its file ceiling");
	await atomicWrite(`${directory}/${FILE}`, bytes);
}

export class DurableRoomsSessionGrants {
	readonly #directory: string;
	readonly #publisher: RoomsSessionGrantPublisher;
	readonly #hmacKey: CryptoKey;
	readonly #grants = new Map<string, RoomsSessionGrantRecord>();
	readonly #swiss = new Map<string, string>();
	readonly #listeners = new Set<() => void>();
	#tail: Promise<void> = Promise.resolve();

	private constructor(
		directory: string,
		grants: readonly RoomsSessionGrantRecord[],
		publisher: RoomsSessionGrantPublisher,
		hmacKey: CryptoKey,
	) {
		this.#directory = directory;
		this.#publisher = publisher;
		this.#hmacKey = hmacKey;
		for (const grant of grants) this.#grants.set(grant.id, grant);
	}

	static async open(
		directory: string,
		rootEntropy: Uint8Array,
		publisher: RoomsSessionGrantPublisher,
	): Promise<DurableRoomsSessionGrants> {
		if (rootEntropy.length !== DURABLE_SWISS_ENTROPY_BYTES) {
			throw new Error("Rooms session grant derivation needs the durable root entropy");
		}
		let disk: GrantDisk;
		try {
			disk = parse(await readBoundedText(`${directory}/${FILE}`, MAX_FILE_BYTES, "Rooms session grant state"));
		} catch (error) {
			if (!(error instanceof Deno.errors.NotFound)) throw error;
			disk = { version: VERSION, grants: [] };
			await write(directory, disk.grants);
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
		return new DurableRoomsSessionGrants(directory, disk.grants, publisher, hmacKey);
	}

	restore(): Promise<void> {
		return this.#serialize(async () => {
			for (const grant of this.#grants.values()) {
				if (!grant.revoked) await this.#ensurePublished(grant);
			}
		});
	}

	list(session: Session): RoomsSessionGrantView[] {
		return [...this.#grants.values()].flatMap((grant) => {
			if (grant.revoked) return [];
			const swiss = this.#swiss.get(grant.id);
			if (swiss == null) throw new Error(`Rooms session grant ${grant.id} is not published`);
			return [{
				id: grant.id,
				label: grant.label,
				rights: grant.rights,
				sturdyref: this.#publisher.sturdyref(session, swiss),
			}];
		});
	}

	issue(
		id: string,
		rights: RoomsSessionFacet,
		label: string,
		session: Session,
	): Promise<RoomsSessionGrantView> {
		return this.#serialize(async () => {
			const parsed = z.safeParse(RoomsSessionGrantRecordSchema, { id, rights, label, revoked: false });
			if (!parsed.success) throw new Error(`Rooms session grant is invalid:\n${z.prettifyError(parsed.error)}`);
			const requested = parsed.data;
			const existing = this.#grants.get(id);
			if (existing != null) {
				if (existing.revoked) {
					throw new Error("that Rooms session grant id has been revoked and cannot be reused");
				}
				if (existing.rights !== rights || existing.label !== label) {
					throw new Error("that Rooms session grant id already names a different grant");
				}
				const wasPublished = this.#swiss.has(id);
				const swiss = await this.#ensurePublished(existing);
				if (!wasPublished) this.#notify();
				return { id, rights, label, sturdyref: this.#publisher.sturdyref(session, swiss) };
			}
			if (this.#grants.size >= MAX_LIFETIME_SESSION_GRANTS) {
				throw new Error("this Rooms session has exhausted its durable grant ledger");
			}
			const active = [...this.#grants.values()].filter((grant) => !grant.revoked).length;
			if (active >= MAX_ACTIVE_SESSION_GRANTS) throw new Error("this Rooms session has too many active grants");
			const next = [...this.#grants.values(), requested];
			await write(this.#directory, next);
			this.#grants.set(id, requested);
			const swiss = await this.#ensurePublished(requested);
			this.#notify();
			return { id, rights, label, sturdyref: this.#publisher.sturdyref(session, swiss) };
		});
	}

	revoke(id: string): Promise<boolean> {
		return this.#serialize(async () => {
			const existing = this.#grants.get(id);
			if (existing == null || existing.revoked) return false;
			const revoked = { ...existing, revoked: true };
			const next = [...this.#grants.values()].map((grant) => grant.id === id ? revoked : grant);
			await write(this.#directory, next);
			this.#grants.set(id, revoked);
			await this.#publisher.revokeLive(id);
			const swiss = this.#swiss.get(id);
			let cleanupFailure: unknown | null = null;
			try {
				if (swiss != null) this.#publisher.unpublish(swiss);
			} catch (error) {
				cleanupFailure = error;
			}
			this.#swiss.delete(id);
			this.#notify();
			if (cleanupFailure != null) {
				throw new Error("the Rooms session grant was revoked, but its durable publication cleanup failed", {
					cause: cleanupFailure,
				});
			}
			return true;
		});
	}

	active(id: string): boolean {
		return this.#grants.get(id)?.revoked === false;
	}

	onChange(listener: () => void): () => void {
		this.#listeners.add(listener);
		return () => this.#listeners.delete(listener);
	}

	#serialize<T>(work: () => Promise<T>): Promise<T> {
		const run = this.#tail.then(work);
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	async #ensurePublished(grant: RoomsSessionGrantRecord): Promise<string> {
		const existing = this.#swiss.get(grant.id);
		if (existing != null) return existing;
		const material = encoder.encode(`pancake Rooms session grant\u0000${grant.id}\u0000${grant.rights}`);
		const digest = new Uint8Array(await crypto.subtle.sign("HMAC", this.#hmacKey, material));
		const entropy = digest.slice(0, DURABLE_SWISS_ENTROPY_BYTES);
		const swiss = this.#publisher.publish(grant, entropy, () => this.active(grant.id));
		this.#swiss.set(grant.id, swiss);
		return swiss;
	}

	#notify(): void {
		for (const listener of this.#listeners) listener();
	}
}
