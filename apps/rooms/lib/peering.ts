import { Ref, retainCleanupFailures, retainSecondaryFailure, type Session } from "@pancake/runtime";
import { ask } from "./ask.ts";
import type { Directory } from "./directory.ts";
import { roomsLocator } from "./locator.ts";
import { PUBLICATION_READY, PUBLISH_DURABLE_ROOM, REVOKE } from "./protocol.ts";

export interface DurableRoom {
	readonly reference: Ref;
	link(locator: string): Promise<string>;
}

/** Exact revocation authority for one foreign-room publication generation. */
export class RoomPublication {
	#session: Session;
	#lease: Ref | null;
	#revoking: Promise<void> | null = null;

	constructor(session: Session, lease: Ref) {
		this.#session = session;
		this.#lease = lease;
	}

	async revoke(): Promise<void> {
		const lease = this.#lease;
		if (lease === null) return;
		if (this.#revoking !== null) return await this.#revoking;
		const revoking = this.#revokeLease(lease);
		this.#revoking = revoking;
		try {
			await revoking;
		} finally {
			if (this.#revoking === revoking) this.#revoking = null;
		}
	}

	async #revokeLease(lease: Ref): Promise<void> {
		await ask(this.#session, lease, REVOKE, [], "the room publication did not answer revocation");
		this.#session.release(lease);
		this.#lease = null;
	}

	/** Let the lease go without revoking: the publication stays live at the
	 * destination, and this client keeps no way to revoke it later. A no-op
	 * while a revoke is in flight, because that revoke already ends the lease. */
	release(): void {
		if (this.#revoking !== null) return;
		const lease = this.#lease;
		if (lease === null) return;
		this.#lease = null;
		this.#session.release(lease);
	}
}

/** Client for a destination's separately enabled peering capability. */
export class DirectoryPeering {
	#session: Session;
	#authority: Ref | null;
	readonly #sourceRefs: { session: Session; ref: Ref }[] = [];
	#retainedFailure: unknown | null = null;

	private constructor(session: Session, authority: Ref) {
		this.#session = session;
		this.#authority = authority;
	}

	static async fetch(directory: Directory, swiss: string): Promise<DirectoryPeering> {
		return new DirectoryPeering(directory.session, await directory.session.fetch(swiss));
	}

	/** Pin `room` at its source before transferring it to the destination. */
	async publish(name: string, room: DurableRoom, source: Directory): Promise<RoomPublication> {
		const authority = this.#authority;
		if (authority === null) throw new Error("directory peering is closed");
		const advertised = await source.advertisedLocation();
		// This publisher Host knows the source through one concrete session. Record
		// the source's own route claim before gifting an import homed there; the
		// source Host's default independently covers capabilities it later exports
		// while settling that gift.
		source.session.setExporterLocator(roomsLocator(advertised));
		const link = await room.link(advertised);
		const durable = await source.session.host.enliven(link, source.session.profile.captpVersion);
		const held = { session: source.session, ref: durable };
		this.#sourceRefs.push(held);
		let lease: unknown;
		try {
			lease = await ask(
				this.#session,
				authority,
				PUBLISH_DURABLE_ROOM,
				[name, durable],
				`the destination did not answer publishing "${name}"`,
			);
		} catch (error) {
			throw await retainCleanupFailures(error, [() => this.#releaseSource(held)]);
		}
		try {
			this.#releaseSource(held);
		} catch (error) {
			// The destination has already adopted its occurrence. Keep the failed
			// local release for close rather than turn that success into a refusal.
			this.#retainFailure(error);
		}
		if (!(lease instanceof Ref)) throw new Error("publishDurableRoom did not return a lease capability");
		const publication = new RoomPublication(this.#session, lease);
		try {
			await ask(
				this.#session,
				lease,
				PUBLICATION_READY,
				[],
				`the destination did not finish publishing "${name}"`,
			);
		} catch (error) {
			throw await retainCleanupFailures(error, [() => publication.revoke()]);
		}
		return publication;
	}

	#releaseSource(held: { session: Session; ref: Ref }): void {
		held.session.release(held.ref);
		const at = this.#sourceRefs.indexOf(held);
		if (at !== -1) this.#sourceRefs.splice(at, 1);
	}

	#retainFailure(error: unknown): void {
		this.#retainedFailure = this.#retainedFailure === null
			? error
			: retainSecondaryFailure(this.#retainedFailure, error);
	}

	close(): void {
		const authority = this.#authority;
		if (authority === null && this.#sourceRefs.length === 0) return;
		this.#authority = null;
		for (const held of [...this.#sourceRefs]) {
			try {
				this.#releaseSource(held);
			} catch (error) {
				this.#retainFailure(error);
			}
		}
		if (authority !== null) {
			try {
				this.#session.release(authority);
			} catch (error) {
				this.#retainFailure(error);
			}
		}
		if (this.#retainedFailure !== null) throw this.#retainedFailure;
	}
}
