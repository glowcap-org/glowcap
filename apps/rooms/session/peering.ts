// Durable peering intent realization for one Rooms session.

import { DirectoryPeering, type DurableRoom } from "../lib/peering.ts";
import type { Directory } from "../lib/directory.ts";
import type { RoomsSessionState, WorkspacePeeringIntent } from "../lib/rooms_state.ts";
import type { LiveDirectory } from "./live.ts";
import { retainSecondaryFailure } from "@pancake/runtime";

const RETRY_FLOOR_MS = 1_000;

export type PeeringPublicationPhase = "publishing" | "live" | "revoking" | "failed";
export interface DurablePeeringPublication {
	id: string;
	name: string;
	source: string;
	phase: PeeringPublicationPhase;
}

interface HeldPeering {
	directory: Directory;
	peering: PeeringAuthority;
	swiss: string;
}

interface PublicationLease {
	revoke(): Promise<void>;
	release(): void;
}

interface PeeringAuthority {
	publish(name: string, room: DurableRoom, source: Directory): Promise<PublicationLease>;
	close(): Promise<void>;
}

type OpenPeering = (directory: Directory, swiss: string) => Promise<PeeringAuthority>;

interface HeldPublication {
	intent: WorkspacePeeringIntent;
	lease: PublicationLease | null;
	phase: PeeringPublicationPhase;
	sourceRoom: object;
}

export class DurableRoomsPeering {
	readonly #setIssue: (subject: string, error: unknown | null) => boolean;
	readonly #invalidated: (scope: string) => void;
	readonly #openPeering: OpenPeering;
	readonly #held = new Map<string, HeldPeering>();
	readonly #publications = new Map<string, HeldPublication>();
	readonly #failed = new Set<string>();
	readonly #retryAfter = new Map<string, number>();

	constructor(
		setIssue: (subject: string, error: unknown | null) => boolean,
		invalidated: (scope: string) => void,
		openPeering: OpenPeering = (directory, swiss) => DirectoryPeering.fetch(directory, swiss),
	) {
		this.#setIssue = setIssue;
		this.#invalidated = invalidated;
		this.#openPeering = openPeering;
	}

	async reconcile(
		checkpoint: RoomsSessionState,
		directories: ReadonlyMap<string, LiveDirectory>,
	): Promise<void> {
		const credentials = new Map(
			checkpoint.capabilities.operations.filter((entry) => entry.capability === "peering").map((
				entry,
			) => [entry.scope, entry]),
		);
		for (const [scope, held] of this.#held) {
			const directory = directories.get(scope);
			const saved = credentials.get(scope);
			if (saved != null && directory?.directory === held.directory && saved.swiss === held.swiss) continue;
			// Publication leases are independent of the capability that minted them.
			// Rotating only that capability keeps the leases. Removing it also removes
			// its dependent intents, so those listings must be revoked before the
			// peering authority is released.
			if (saved == null && directory?.directory === held.directory) {
				for (const [id, publication] of this.#publications) {
					if (publication.intent.destination === scope) await this.#revoke(id, publication);
				}
			} else if (directory?.directory !== held.directory) {
				this.#releasePublicationsFor(scope);
			}
			await held.peering.close().catch((error) => this.#setIssue(`peering:${scope}`, error));
			this.#held.delete(scope);
			this.#invalidated(scope);
		}
		for (const [scope, saved] of credentials) {
			if (this.#held.has(scope)) continue;
			const directory = directories.get(scope);
			if (directory == null) {
				this.#setIssue(`peering:${scope}`, "the peering capability scope is not connected");
				continue;
			}
			try {
				const peering = await this.#openPeering(directory.directory, saved.swiss);
				this.#held.set(scope, { directory: directory.directory, peering, swiss: saved.swiss });
				this.#setIssue(`peering:${scope}`, null);
			} catch (error) {
				this.#setIssue(`peering:${scope}`, error);
			}
		}
		const wanted = new Map(checkpoint.peering.map((intent) => [intent.id, intent]));
		for (const id of [...this.#retryAfter.keys()]) {
			if (!wanted.has(id)) {
				this.#retryAfter.delete(id);
				this.#failed.delete(id);
				this.#setIssue(`peering:${id}`, null);
			}
		}
		for (const [id, held] of this.#publications) {
			const saved = wanted.get(id);
			const source = saved == null ? null : this.#sourceRoom(saved, directories);
			if (
				saved != null && JSON.stringify(saved) === JSON.stringify(held.intent) &&
				(source == null || source.room.room === held.sourceRoom)
			) continue;
			if (saved != null && source == null) continue;
			await this.#revoke(id, held);
		}
		for (const intent of checkpoint.peering) {
			if (this.#publications.has(intent.id)) continue;
			if ((this.#retryAfter.get(intent.id) ?? 0) > Date.now()) continue;
			await this.#publish(intent, directories);
		}
	}

	snapshot(intents: readonly WorkspacePeeringIntent[] = []): DurablePeeringPublication[] {
		return intents.map((intent) => ({
			id: intent.id,
			name: intent.name,
			source: intent.source,
			phase: this.#publications.get(intent.id)?.phase ?? (this.#failed.has(intent.id) ? "failed" : "publishing"),
		}));
	}

	/** Retire local occurrences before their directory session is replaced.
	 * Closing that session removes its destination-side listings, so this path
	 * releases leases rather than starting a redundant revoke protocol. */
	async releaseFor(directoryId: string): Promise<void> {
		this.#releasePublicationsFor(directoryId);
		const held = this.#held.get(directoryId);
		if (held == null) return;
		this.#held.delete(directoryId);
		await held.peering.close().catch((error) => this.#setIssue(`peering:${directoryId}`, error));
		this.#invalidated(directoryId);
	}

	async close(): Promise<void> {
		let failure: unknown | null = null;
		for (const [id, held] of this.#publications) {
			if (held.lease == null) {
				this.#publications.delete(id);
				continue;
			}
			try {
				held.lease.release();
				this.#publications.delete(id);
			} catch (error) {
				failure = failure == null ? error : retainSecondaryFailure(failure, error);
			}
		}
		for (const [scope, held] of this.#held) {
			try {
				await held.peering.close();
				this.#held.delete(scope);
			} catch (error) {
				failure = failure == null ? error : retainSecondaryFailure(failure, error);
			}
		}
		if (failure != null) throw failure;
	}

	async #publish(intent: WorkspacePeeringIntent, directories: ReadonlyMap<string, LiveDirectory>): Promise<void> {
		const destination = this.#held.get(intent.destination);
		const sourceConversation = this.#sourceRoom(intent, directories);
		if (destination == null || sourceConversation == null) {
			this.#failed.add(intent.id);
			this.#retryAfter.set(intent.id, Date.now() + RETRY_FLOOR_MS);
			this.#setIssue(`peering:${intent.id}`, "the peering source or destination is not connected");
			return;
		}
		this.#setIssue(`peering:${intent.id}`, null);
		try {
			const lease = await destination.peering.publish(
				intent.name,
				sourceConversation.room.room,
				sourceConversation.directory.directory,
			);
			const currentSource = this.#sourceRoom(intent, directories);
			if (
				this.#held.get(intent.destination) !== destination ||
				currentSource?.room.room !== sourceConversation.room.room
			) {
				let refusal: unknown = new Error(
					"the peering source or destination changed while publication was opening",
				);
				try {
					lease.release();
				} catch (error) {
					refusal = retainSecondaryFailure(refusal, error);
				}
				this.#failed.add(intent.id);
				this.#retryAfter.set(intent.id, Date.now() + RETRY_FLOOR_MS);
				this.#setIssue(`peering:${intent.id}`, refusal);
				return;
			}
			this.#publications.set(intent.id, {
				intent,
				lease,
				phase: "live",
				sourceRoom: sourceConversation.room.room,
			});
			this.#failed.delete(intent.id);
			this.#retryAfter.delete(intent.id);
			this.#invalidated(intent.destination);
		} catch (error) {
			this.#failed.add(intent.id);
			this.#retryAfter.set(intent.id, Date.now() + RETRY_FLOOR_MS);
			this.#setIssue(`peering:${intent.id}`, error);
		}
	}

	#sourceRoom(intent: WorkspacePeeringIntent, directories: ReadonlyMap<string, LiveDirectory>) {
		return [...directories.values()]
			.flatMap((directory) =>
				[...directory.roomRealization.rooms.entries()].map(([id, room]) => ({ directory, id, room }))
			)
			.find(({ id }) => id === intent.source) ?? null;
	}

	async #revoke(id: string, held: HeldPublication): Promise<void> {
		held.phase = "revoking";
		if (held.lease == null) {
			this.#publications.delete(id);
			return;
		}
		try {
			await held.lease.revoke();
			this.#publications.delete(id);
			this.#setIssue(`peering:${id}`, null);
			this.#invalidated(held.intent.destination);
		} catch (error) {
			held.phase = "failed";
			this.#setIssue(`peering:${id}`, error);
		}
	}

	#releasePublicationsFor(scope: string): void {
		for (const [id, publication] of this.#publications) {
			if (publication.intent.destination !== scope) continue;
			try {
				publication.lease?.release();
			} catch (error) {
				console.error(
					`rooms session: could not release publication ${id} before its directory closed: ${
						error instanceof Error ? error.message : error
					}`,
				);
			}
			this.#publications.delete(id);
			this.#failed.delete(id);
			this.#retryAfter.delete(id);
			this.#setIssue(`peering:${id}`, null);
		}
	}
}
