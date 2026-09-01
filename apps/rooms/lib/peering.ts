import { Ref, retainSecondaryFailure, type Session } from "@pancake/runtime";
import { ask } from "./ask.ts";
import { Unanswered } from "./deadline.ts";
import type { Directory } from "./directory.ts";
import { REQUEST_TIMEOUT_MS } from "./limits.ts";
import { PUBLICATION_READY, PUBLISH_DURABLE_ROOM, REVOKE } from "./protocol.ts";

export interface DurableRoom {
	readonly reference: Ref;
	link(): Promise<string>;
}

/** Exact revocation authority for one foreign-room publication generation. */
export class RoomPublication {
	#session: Session;
	#lease: Ref | null;
	#revoking: Promise<void> | null = null;
	#releaseAfterRevoke = false;

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
		let failure: unknown | null = null;
		try {
			await revoking;
		} catch (error) {
			failure = error;
		}
		// The reset and the release run on both outcomes, but out of a `finally`:
		// a `throw` there would silently override the revoke failure this method
		// still has to report. So record the revoke error, do the cleanup as
		// ordinary code, and re-raise the revoke failure last.
		if (this.#revoking === revoking) this.#revoking = null;
		if (this.#releaseAfterRevoke && this.#lease !== null) {
			try {
				this.#releaseLease();
			} catch (cleanup) {
				if (failure === null) throw cleanup;
				retainSecondaryFailure(failure, cleanup);
			}
		}
		if (failure !== null) throw failure;
	}

	async #revokeLease(lease: Ref): Promise<void> {
		await ask(this.#session, lease, REVOKE, [], "the room publication did not answer revocation");
		this.#releaseLease();
	}

	#releaseLease(): void {
		const lease = this.#lease;
		if (lease === null) return;
		// Commit the native release before dropping the only retry owner.
		this.#session.release(lease);
		this.#lease = null;
	}

	/** Let the lease go without revoking: the publication stays live at the
	 * destination until its publisher Session ends, and this client keeps no way
	 * to revoke it later. During an in-flight revoke, record the release intent
	 * and commit it after that attempt settles. */
	release(): void {
		if (this.#revoking !== null) {
			this.#releaseAfterRevoke = true;
			return;
		}
		this.#releaseLease();
	}
}

interface SourceHold {
	session: Session;
	ref: Ref;
}

/** Client for a destination's separately enabled peering capability. */
export class DirectoryPeering {
	#session: Session;
	#authority: Ref | null;
	#closed = false;
	/** Holds exist here only when their deterministic release refused. The
	 * admitted PUBLISH send owns its occurrence, so the ordinary path keeps no
	 * parallel application retain while waiting for the answer. */
	readonly #failedSourceRefs = new Set<SourceHold>();
	/** Publication owners whose compensating revoke refused. They remain here
	 * until close can release the lease; the publisher Session is the server's
	 * final cleanup boundary for their listing. */
	readonly #failedPublications = new Set<RoomPublication>();
	readonly #inFlight = new Set<Promise<void>>();
	#closePromise: Promise<void> | null = null;
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
		let finish!: () => void;
		const settled = new Promise<void>((resolve) => (finish = resolve));
		this.#inFlight.add(settled);
		try {
			return await this.#publish(name, room, source);
		} finally {
			this.#inFlight.delete(settled);
			finish();
		}
	}

	async #publish(name: string, room: DurableRoom, source: Directory): Promise<RoomPublication> {
		const authority = this.#authority;
		if (this.#closed || authority === null) throw new Error("directory peering is closed");
		const link = await room.link();
		if (this.#closed) throw new Error("directory peering is closed");
		// Enlivenment verifies the complete source-authored sturdyref and retains
		// its canonical locator on the actual exporter session for later gives.
		const durable = await source.session.host.enliven(link);
		const held: SourceHold = { session: source.session, ref: durable };
		if (this.#closed) {
			this.#releaseOrRetainSource(held);
			throw new Error("directory peering is closed");
		}
		let answer: Promise<unknown>;
		try {
			answer = this.#publicationAnswer(
				this.#session,
				authority,
				[name, durable],
				`the destination did not answer publishing "${name}"`,
			);
		} catch (error) {
			this.#releaseOrRetainSource(held);
			throw error;
		}
		// `send` admitted the occurrence before `ask` returned. The core now owns
		// the staged handoff; keeping this wrapper until the reply would be a second
		// retain with no authority role.
		this.#releaseOrRetainSource(held);
		const lease = await answer;
		if (!(lease instanceof Ref)) throw new Error("publishDurableRoom did not return a lease capability");
		const publication = new RoomPublication(this.#session, lease);
		if (this.#closed) {
			await this.#cancelClosedPublication(publication);
			throw new Error("directory peering closed while the room was publishing");
		}
		try {
			await ask(
				this.#session,
				lease,
				PUBLICATION_READY,
				[],
				`the destination did not finish publishing "${name}"`,
			);
		} catch (error) {
			try {
				await publication.revoke();
			} catch (cleanup) {
				this.#failedPublications.add(publication);
				retainSecondaryFailure(error, cleanup);
			}
			throw error;
		}
		if (this.#closed) {
			await this.#cancelClosedPublication(publication);
			throw new Error("directory peering closed while the room was publishing");
		}
		return publication;
	}

	async #cancelClosedPublication(publication: RoomPublication): Promise<void> {
		try {
			await publication.revoke();
		} catch (error) {
			this.#failedPublications.add(publication);
			this.#retainFailure(error);
			throw error;
		}
	}

	/** Await PUBLISH without losing a lease that arrives after the reader-facing
	 * deadline. A late lease is immediately revoked and remains owned here if
	 * that compensation refuses. */
	async #publicationAnswer(
		session: Session,
		authority: Ref,
		args: Parameters<Session["send"]>[2],
		what: string,
	): Promise<unknown> {
		let abandoned = false;
		let timer: ReturnType<typeof setTimeout> | undefined;
		const sent = session.send(authority, PUBLISH_DURABLE_ROOM, args) as Promise<unknown>;
		const observed = sent.then((value) => {
			if (abandoned && value instanceof Ref) this.#retireLatePublication(value);
			return value;
		});
		const deadline = new Promise<never>((_, reject) => {
			timer = setTimeout(() => {
				abandoned = true;
				reject(new Unanswered(what));
			}, REQUEST_TIMEOUT_MS);
		});
		try {
			return await Promise.race([observed, deadline]);
		} finally {
			clearTimeout(timer);
		}
	}

	#retireLatePublication(lease: Ref): void {
		const publication = new RoomPublication(this.#session, lease);
		this.#failedPublications.add(publication);
		void publication.revoke().then(
			() => this.#failedPublications.delete(publication),
			(error) => {
				this.#retainFailure(error);
				if (!this.#closed) return;
				try {
					publication.release();
					this.#failedPublications.delete(publication);
				} catch (cleanup) {
					this.#retainFailure(cleanup);
				}
			},
		);
	}

	#releaseSource(held: SourceHold): void {
		try {
			held.session.release(held.ref);
			this.#failedSourceRefs.delete(held);
		} catch (error) {
			this.#failedSourceRefs.add(held);
			throw error;
		}
	}

	#releaseOrRetainSource(held: SourceHold): void {
		try {
			this.#releaseSource(held);
		} catch (error) {
			// Keep the failed local release for close. Once a send was admitted,
			// the destination owns the argument occurrence independently.
			this.#retainFailure(error);
		}
	}

	#retainFailure(error: unknown): void {
		this.#retainedFailure = this.#retainedFailure === null
			? error
			: retainSecondaryFailure(this.#retainedFailure, error);
	}

	/** Stop new publications, cancel any whose lease is still arriving, and
	 * deterministically release every local owner. Server-side listings whose
	 * leases were deliberately released remain scoped to the destination
	 * Session; closing this capability does not rename release as revoke. */
	close(): Promise<void> {
		if (this.#closePromise !== null) return this.#closePromise;
		this.#closed = true;
		const closing = this.#close();
		this.#closePromise = closing;
		void closing.finally(() => {
			if (this.#closePromise === closing) this.#closePromise = null;
		}).catch(() => {});
		return closing;
	}

	async #close(): Promise<void> {
		const authority = this.#authority;
		// Stop new sends first. An operation already admitted owns its argument
		// occurrence and will observe #closed when its lease arrives.
		if (authority !== null) {
			try {
				this.#session.release(authority);
				this.#authority = null;
			} catch (error) {
				this.#retainFailure(error);
			}
		}
		while (this.#inFlight.size > 0) await Promise.race(this.#inFlight);
		for (const publication of this.#failedPublications) {
			try {
				await publication.revoke();
				this.#failedPublications.delete(publication);
			} catch (error) {
				this.#retainFailure(error);
				try {
					publication.release();
					this.#failedPublications.delete(publication);
				} catch (cleanup) {
					this.#retainFailure(cleanup);
				}
			}
		}
		for (const held of this.#failedSourceRefs) {
			try {
				this.#releaseSource(held);
			} catch (error) {
				this.#retainFailure(error);
			}
		}
		if (this.#authority !== null) {
			try {
				this.#session.release(this.#authority);
				this.#authority = null;
			} catch (error) {
				this.#retainFailure(error);
			}
		}
		if (this.#retainedFailure !== null) {
			const failure = this.#retainedFailure;
			this.#retainedFailure = null;
			throw failure;
		}
	}
}
