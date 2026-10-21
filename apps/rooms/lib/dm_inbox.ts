// Being reachable by direct message: one inbox per peer, offered to the room.
//
// The inbox is a Host publication and not published on one session, because the
// peer reaches it by redeeming an introduction, which dials this host, and a
// Host publication is what answers on the connection that dial opens.
// `Session.publishedRef` then names the position the directory's connection
// granted it.
//
// Removing a Host alias never retargets an issued capability: the old actor status-allow: replacement state identity
// remains exact while anything still roots it, then its hosted behavior is
// reclaimed. The publisher retires aliases when their peer authority ends, so
// churn does not spend its bounded live-publication ledger.
//
// Used by the direct-message demos.

import type { Behavior, Host, Ref } from "@glowcap/runtime";
import { MAX_DM_INBOXES, nickRefusal } from "./limits.ts";
import { isRegistrationId } from "./directory_publications.ts";
import type { Directory } from "./room/client.ts";

/** Creates and offers direct-message inboxes for live registrations. */
export interface InboxOfferer {
	/** Create an inbox for `peer`'s registration ID if there is none, and offer it
	 * to the directory. Always re-offers across a directory reconnect. */
	offer(peer: string, registrationId: string, opening: string): void;
	/** Forget the inbox created for `registrationId`, so a later `offer` creates a
	 * fresh one. Call it when the registration leaves: the next holder of that name
	 * is someone else and must not inherit their inbox. The old issued capability status-allow: replacement state identity
	 * keeps its revoked or disconnected behavior and is never retargeted. */
	forget(registrationId: string): void;
	/** Retire every alias owned by this offerer. Resolves after unpublication has
	 * run outside any delivering Host turn. */
	close(): Promise<void>;
}

/** Host-scoped owner of every live inbox alias published through it. Directory
 * offerers are children of this owner, so the configured ceiling is one
 * structural ledger and not a per-caller convention. */
export interface InboxPublisher {
	offerer(opts: InboxOffererOptions): InboxOfferer;
}

export interface InboxOffererOptions {
	/** The directory to offer through, read at each offer so a reconnect is
	 * picked up. */
	dir: () => Directory | null;
	/** The inbox behavior for one named peer, which may treat its caller as
	 * `peer` without checking anything in the message. */
	behaviorFor: (peer: string, registrationId: string) => Behavior;
	/** Peers to skip, such as ourselves. */
	skip?: (peer: string) => boolean;
	onError?: (peer: string, err: unknown) => void;
}

interface PublisherState {
	readonly limit: number;
	readonly publisher: InboxPublisher;
}

const publishers = new WeakMap<Host, PublisherState>();

/** Return the inbox publication owner for `host`.
 *
 * Host identity, not caller discipline, makes the ledger singular: every call
 * with the same Host returns the same owner. Create each directory's offerer
 * through it. */
export function inboxPublisher(host: Host, limit = MAX_DM_INBOXES): InboxPublisher {
	if (!Number.isSafeInteger(limit) || limit < 1) throw new Error("inbox publication limit must be positive");
	const held = publishers.get(host);
	if (held !== undefined) {
		if (held.limit !== limit) {
			throw new Error(`Host inbox publisher already owns limit ${held.limit}, not ${limit}`);
		}
		return held.publisher;
	}
	// Every live or provisional alias, and whether `publish` has taken it.
	// Retirement removes a published name only after scheduling unpublication
	// ahead of any replacement publication.
	const names = new Map<string, boolean>();
	const retiringNames = new Set<string>();
	const publisher: InboxPublisher = {
		offerer(opts: InboxOffererOptions): InboxOfferer {
			// The name created for each registration in this directory. The same
			// nickname under a later registration ID gets another alias, and both
			// spend this Host's ledger.
			const minted = new Map<string, string>();
			const retirements = new Set<Promise<void>>();
			let closed = false;

			const retire = (key: string): Promise<void> | null => {
				const name = minted.get(key);
				minted.delete(key);
				if (name === undefined) return null;
				if (names.get(name) !== true) {
					names.delete(name);
					return null;
				}
				// Free logical capacity now. The retirement microtask was queued before
				// any replacement publication, so the alias leaves first.
				names.delete(name);
				retiringNames.add(name);
				const pending = new Promise<void>((resolve) =>
					queueMicrotask(() => {
						try {
							host.unpublish(name);
							retiringNames.delete(name);
						} catch (error) {
							// The alias is still live, so restore the ledger instead of
							// pretending its slot was reclaimed.
							retiringNames.delete(name);
							names.set(name, true);
							opts.onError?.(key, error);
						} finally {
							resolve();
						}
					})
				);
				retirements.add(pending);
				void pending.finally(() => retirements.delete(pending));
				return pending;
			};
			return {
				offer(peer: string, registrationId: string, opening: string): void {
					if (closed) return;
					const key = registrationId;
					if (opts.skip?.(peer)) return;
					const unnameable = nickRefusal(peer);
					if (unnameable != null || !isRegistrationId(registrationId)) {
						opts.onError?.(peer, new Error(unnameable ?? "invalid registration ID"));
						return;
					}
					let swiss = minted.get(key);
					if (swiss === undefined) {
						if (names.size >= limit) {
							opts.onError?.(
								peer,
								new Error(`already holding ${limit} inboxes; not minting another`),
							);
							return;
						}
						// Claim before yielding so two requests cannot race into two
						// aliases. The ledger, not probability, owns uniqueness.
						do swiss = mintSwiss(peer); while (names.has(swiss) || retiringNames.has(swiss));
						minted.set(key, swiss);
						names.set(swiss, false);
					}
					const name = swiss;
					queueMicrotask(() => {
						const dir = opts.dir();
						if (closed || dir === null || minted.get(key) !== name) {
							// The Host never took this alias. Return its provisional slot;
							// published aliases retire through `retire` instead.
							if (names.get(name) === false) names.delete(name);
							if (minted.get(key) === name) minted.delete(key);
							return;
						}
						let ref: Ref | null = null;
						try {
							if (names.get(name) !== true) {
								host.publish(name, opts.behaviorFor(peer, registrationId));
								names.set(name, true);
							}
							ref = dir.session.publishedRef(name);
							if (ref === null) throw new Error("the Host publication has no live capability");
						} catch (err) {
							// A name the Host never took is free immediately. Once published,
							// keep it for a later re-offer; explicit forget/close retires it.
							if (names.get(name) !== true) {
								names.delete(name);
								minted.delete(key);
							}
							opts.onError?.(peer, err);
							return;
						}
						dir.offerInbox(peer, registrationId, opening, ref).catch((err) => opts.onError?.(peer, err));
					});
				},
				forget(registrationId: string): void {
					void retire(registrationId);
				},
				async close(): Promise<void> {
					if (closed) return;
					closed = true;
					for (const key of [...minted.keys()]) void retire(key);
					await Promise.allSettled([...retirements]);
				},
			};
		},
	};
	publishers.set(host, { limit, publisher });
	return publisher;
}

/** An unguessable name for one peer's inbox. A guessable one would let anyone
 * fetch it by name on a connection they opened themselves. */
function mintSwiss(peer: string): string {
	const bytes = new Uint8Array(32);
	crypto.getRandomValues(bytes);
	return `dm-${peer.toLowerCase()}-` +
		[...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}
