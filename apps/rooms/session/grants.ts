// Durable, attenuated session grants and their publication lifecycle.

import { DURABLE_SWISS_ENTROPY_BYTES, type Session } from "@glowcap/runtime";
import * as z from "zod/mini";
import {
	type RoomsSessionFacet,
	RoomsSessionFacetSchema,
	RoomsSessionGrantIdSchema,
	RoomsSessionGrantLabelSchema,
	RoomsSessionGrantNoteSchema,
	type RoomsSessionGrantView,
} from "../lib/session/grants.ts";
import { MAX_ACTIVE_SESSION_GRANTS, MAX_LIFETIME_SESSION_GRANTS } from "../lib/limits.ts";
import { decodeSessionDocument, type RoomsSessionDocumentStore, SESSION_DOCUMENT_CEILINGS } from "./documents.ts";

const VERSION = 1;
const MAX_GRANTS_BYTES = SESSION_DOCUMENT_CEILINGS.grants;
const encoder = new TextEncoder();
export const RoomsSessionGrantRecordSchema = z.strictObject({
	id: RoomsSessionGrantIdSchema,
	label: RoomsSessionGrantLabelSchema,
	rights: RoomsSessionFacetSchema,
	history: z.boolean(),
	suspended: z.boolean(),
	note: RoomsSessionGrantNoteSchema,
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
	issue(
		id: string,
		rights: RoomsSessionFacet,
		label: string,
		history: boolean,
		session: Session,
	): Promise<RoomsSessionGrantView>;
	/** Change what a live grant carries, leaving its link alone. Fields left
	 * null keep the answer they had. */
	setPolicy(id: string, patch: RoomsSessionGrantPolicyPatch, session: Session): Promise<RoomsSessionGrantView>;
	revoke(id: string): Promise<boolean>;
	active(id: string): boolean;
	/** What a grant carries now, or null when it carries nothing because it is
	 * gone. Read at the moment a verb is admitted rather than captured when the
	 * facet was published, which is what lets a change reach whoever is already
	 * holding the link. */
	policy(id: string): RoomsSessionGrantPolicy | null;
	onChange(listener: () => void): () => void;
}

/** What a grant carries, as the ledger currently answers it. */
export interface RoomsSessionGrantPolicy {
	readonly rights: RoomsSessionFacet;
	readonly history: boolean;
	readonly suspended: boolean;
	readonly note: string;
}

/** A change to one grant. A null leaves that answer as it was. */
export interface RoomsSessionGrantPolicyPatch {
	readonly rights?: RoomsSessionFacet | null;
	readonly history?: boolean | null;
	readonly suspended?: boolean | null;
	readonly note?: string | null;
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

async function write(documents: RoomsSessionDocumentStore, grants: readonly RoomsSessionGrantRecord[]): Promise<void> {
	const parsed = z.safeParse(RoomsSessionGrantDiskSchema, { version: VERSION, grants });
	if (!parsed.success) {
		throw new Error(`Rooms session refused invalid grant state:\n${z.prettifyError(parsed.error)}`);
	}
	const bytes = encoder.encode(JSON.stringify(parsed.data) + "\n");
	if (bytes.length > MAX_GRANTS_BYTES) {
		throw new Error(`Rooms session grant state exceeds its ${MAX_GRANTS_BYTES}-byte ceiling`);
	}
	await documents.write("grants", bytes);
}

export class DurableRoomsSessionGrants {
	readonly #documents: RoomsSessionDocumentStore;
	readonly #publisher: RoomsSessionGrantPublisher;
	readonly #hmacKey: CryptoKey;
	readonly #grants = new Map<string, RoomsSessionGrantRecord>();
	readonly #swiss = new Map<string, string>();
	readonly #listeners = new Set<() => void>();
	#tail: Promise<void> = Promise.resolve();

	private constructor(
		documents: RoomsSessionDocumentStore,
		grants: readonly RoomsSessionGrantRecord[],
		publisher: RoomsSessionGrantPublisher,
		hmacKey: CryptoKey,
	) {
		this.#documents = documents;
		this.#publisher = publisher;
		this.#hmacKey = hmacKey;
		for (const grant of grants) this.#grants.set(grant.id, grant);
	}

	static async open(
		documents: RoomsSessionDocumentStore,
		rootEntropy: Uint8Array,
		publisher: RoomsSessionGrantPublisher,
	): Promise<DurableRoomsSessionGrants> {
		if (rootEntropy.length !== DURABLE_SWISS_ENTROPY_BYTES) {
			throw new Error("Rooms session grant derivation needs the durable root entropy");
		}
		const raw = await documents.read("grants");
		let disk: GrantDisk;
		if (raw == null) {
			disk = { version: VERSION, grants: [] };
			await write(documents, disk.grants);
		} else {
			disk = parse(decodeSessionDocument(raw, MAX_GRANTS_BYTES, "Rooms session grant state"));
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
		return new DurableRoomsSessionGrants(documents, disk.grants, publisher, hmacKey);
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
			return [this.#view(grant, swiss, session)];
		});
	}

	issue(
		id: string,
		rights: RoomsSessionFacet,
		label: string,
		history: boolean,
		session: Session,
	): Promise<RoomsSessionGrantView> {
		return this.#serialize(async () => {
			const parsed = z.safeParse(RoomsSessionGrantRecordSchema, {
				id,
				rights,
				label,
				history,
				suspended: false,
				note: "",
				revoked: false,
			});
			if (!parsed.success) throw new Error(`Rooms session grant is invalid:\n${z.prettifyError(parsed.error)}`);
			const requested = parsed.data;
			const existing = this.#grants.get(id);
			if (existing != null) {
				if (existing.revoked) {
					throw new Error("that Rooms session grant id has been revoked and cannot be reused");
				}
				if (existing.rights !== rights || existing.label !== label || existing.history !== history) {
					throw new Error("that Rooms session grant id already names a different grant");
				}
				const wasPublished = this.#swiss.has(id);
				const swiss = await this.#ensurePublished(existing);
				if (!wasPublished) this.#notify();
				return this.#view(existing, swiss, session);
			}
			if (this.#grants.size >= MAX_LIFETIME_SESSION_GRANTS) {
				throw new Error("this Rooms session has exhausted its durable grant ledger");
			}
			const active = [...this.#grants.values()].filter((grant) => !grant.revoked).length;
			if (active >= MAX_ACTIVE_SESSION_GRANTS) throw new Error("this Rooms session has too many active grants");
			const next = [...this.#grants.values(), requested];
			await write(this.#documents, next);
			this.#grants.set(id, requested);
			const swiss = await this.#ensurePublished(requested);
			this.#notify();
			return this.#view(requested, swiss, session);
		});
	}

	setPolicy(
		id: string,
		patch: RoomsSessionGrantPolicyPatch,
		session: Session,
	): Promise<RoomsSessionGrantView> {
		return this.#serialize(async () => {
			const existing = this.#grants.get(id);
			if (existing == null) throw new Error("that Rooms session grant id names no grant");
			if (existing.revoked) throw new Error("that Rooms session grant has been revoked");
			const parsed = z.safeParse(RoomsSessionGrantRecordSchema, {
				...existing,
				rights: patch.rights ?? existing.rights,
				history: patch.history ?? existing.history,
				suspended: patch.suspended ?? existing.suspended,
				// A note belongs to the suspension that needed it, so lifting one
				// takes it down rather than leaving a reason for a link that is
				// answering again.
				note: patch.suspended === false ? "" : patch.note ?? existing.note,
			});
			if (!parsed.success) {
				throw new Error(`Rooms session grant policy is invalid:\n${z.prettifyError(parsed.error)}`);
			}
			const next = parsed.data;
			await write(this.#documents, [...this.#grants.values()].map((grant) => grant.id === id ? next : grant));
			this.#grants.set(id, next);
			// The link is a function of the id, so it is the one thing this cannot
			// have changed.
			const swiss = await this.#ensurePublished(next);
			this.#notify();
			return this.#view(next, swiss, session);
		});
	}

	policy(id: string): RoomsSessionGrantPolicy | null {
		const grant = this.#grants.get(id);
		if (grant == null || grant.revoked) return null;
		return { rights: grant.rights, history: grant.history, suspended: grant.suspended, note: grant.note };
	}

	#view(grant: RoomsSessionGrantRecord, swiss: string, session: Session): RoomsSessionGrantView {
		return {
			id: grant.id,
			label: grant.label,
			rights: grant.rights,
			history: grant.history,
			suspended: grant.suspended,
			note: grant.note,
			sturdyref: this.#publisher.sturdyref(session, swiss),
		};
	}

	revoke(id: string): Promise<boolean> {
		return this.#serialize(async () => {
			const existing = this.#grants.get(id);
			if (existing == null || existing.revoked) return false;
			const revoked = { ...existing, revoked: true };
			const next = [...this.#grants.values()].map((grant) => grant.id === id ? revoked : grant);
			await write(this.#documents, next);
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
		// The id alone. It is client-minted, unique, and the one thing about a
		// grant that never changes — which is exactly what a link should be a
		// function of. Deriving from anything mutable makes the link a
		// consequence of policy, so narrowing a grant would silently mint a
		// different link and the old one would die at the next restart. That was
		// the whole reason a grant's access could not be changed at all.
		const material = encoder.encode(`glowcap Rooms session grant\u0000${grant.id}`);
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
