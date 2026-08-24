// Being reachable by direct message: one inbox per peer, offered to the room.
//
// The inbox is a *giftable* rather than published on one session because the peer
// reaches it by redeeming an introduction, which dials this host, and a giftable
// is what answers on the connection that dial opens. `Session.publishedRef` then
// names the position the directory's own connection granted it.
//
// Removing a Host alias never retargets an issued capability: the old actor
// remains exact while anything still roots it, then its hosted behavior is
// reclaimed. The publisher retires aliases when their peer authority ends, so
// churn does not spend its bounded live-publication ledger.
//
// Shared by the browser UI and the direct-message demos.

import type { Behavior, Host, Ref } from "@pancake/runtime";
import { MAX_DM_INBOXES, nickRefusal } from "./limits.ts";
import type { Directory } from "./room_client.ts";

/** Mints and offers direct-message inboxes for named peers. */
export interface InboxOfferer {
	/** Mint an inbox for `peer` if there is none, and offer it to the directory.
	 * Always re-offers: the directory forgets a member's offers whenever the name
	 * either side holds changes hands, and the only way back is to say it again. */
	offer(peer: string): void;
	/** Forget the inbox minted for `peer`, so a later `offer` mints a fresh one.
	 * Call it when the peer leaves: the next holder of that name is someone else
	 * and must not inherit their inbox. The old issued capability keeps its exact
	 * revoked/disconnected behavior; it is never retargeted. */
	forget(peer: string): void;
	/** Retire every alias owned by this offerer. Resolves after unpublication has
	 * run outside any delivering Host turn. */
	close(): Promise<void>;
}

/** Host-scoped owner of every live inbox alias published through it. Directory
 * offerers are children of this owner, so the configured ceiling is one
 * structural ledger rather than a per-caller convention. */
export interface InboxPublisher {
	offerer(opts: InboxOffererOptions): InboxOfferer;
}

export interface InboxOffererOptions {
	/** The directory to offer through, read at each offer so a reconnect is
	 * picked up. */
	dir: () => Directory | null;
	/** The inbox behavior for one named peer, which may treat its caller as
	 * `peer` without checking anything in the message. */
	behaviorFor: (peer: string) => Behavior;
	/** Peers to skip, such as ourselves. */
	skip?: (peer: string) => boolean;
	onError?: (peer: string, err: unknown) => void;
}

interface PublisherState {
	readonly limit: number;
	readonly publisher: InboxPublisher;
}

const publishers = new WeakMap<Host, PublisherState>();

/** Return the one inbox publication owner for `host`.
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
	// Every live or provisional alias, and whether `publishGiftable` has taken
	// it. Retirement removes a published name only after scheduling native
	// unpublication ahead of any replacement publication.
	const names = new Map<string, boolean>();
	const retiringNames = new Set<string>();
	const publisher: InboxPublisher = {
		offerer(opts: InboxOffererOptions): InboxOfferer {
			// The name minted for each peer in this directory. The same spelling in
			// another directory is another authority and gets another alias, but both
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
				// any replacement publication, so the native alias leaves first.
				names.delete(name);
				retiringNames.add(name);
				const pending = new Promise<void>((resolve) =>
					queueMicrotask(() => {
						try {
							host.unpublishGiftable(name);
							retiringNames.delete(name);
						} catch (error) {
							// The native alias is still live, so restore the ledger rather than
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
				offer(peer: string): void {
					if (closed) return;
					const key = peer.toLowerCase();
					if (opts.skip?.(peer)) return;
					const unnameable = nickRefusal(peer);
					if (unnameable !== null) {
						opts.onError?.(peer, new Error(unnameable));
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
						// aliases. The ledger, rather than probability, owns uniqueness.
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
								host.publishGiftable(name, opts.behaviorFor(peer));
								names.set(name, true);
							}
							ref = dir.session.publishedRef(name);
							if (ref === null) throw new Error("the giftable has no live capability");
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
						dir.offerInbox(peer, ref).catch((err) => opts.onError?.(peer, err));
					});
				},
				forget(peer: string): void {
					void retire(peer.toLowerCase());
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

/** An unguessable name for one peer's inbox: a guessable one would let anyone
 * fetch it by name on a connection they opened themselves. */
function mintSwiss(peer: string): string {
	const bytes = new Uint8Array(32);
	crypto.getRandomValues(bytes);
	return `dm-${peer.toLowerCase()}-` +
		[...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}
