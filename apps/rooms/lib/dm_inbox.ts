// Being reachable by direct message: one inbox per peer, offered to the room.
//
// The inbox is a *giftable* rather than published on one session because the peer
// reaches it by redeeming an introduction, which dials this host, and a giftable
// is what answers on the connection that dial opens. `Session.publishedRef` then
// names the position the directory's own connection granted it.
//
// Removing a Host alias does not reclaim its hosted behavior or any issued
// capability, so publishing one spends a slot for the Host's life. The peer
// asking is the one who chose the name, so `MAX_DM_INBOXES` is the ceiling on
// how many any of them can spend, and an over-long nick is refused outright.
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
	 * and must not inherit their inbox. A published behavior cannot be reclaimed,
	 * so a peer that rejoins costs another Host-lifetime slot. */
	forget(peer: string): void;
}

/** Host-scoped owner of every inbox alias published through it.
 *
 * Publishing a giftable hosts behavior for the Host's whole lifetime, even if
 * its alias is later removed. Directory offerers are children of this owner:
 * reconnecting, leaving, reopening, or adding another directory must not reset
 * the one process-wide ceiling. */
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

const publishers = new WeakMap<Host, InboxPublisher>();

/** Return the one inbox publication owner for `host`.
 *
 * Host identity, not caller discipline, makes the ledger singular: every call
 * with the same Host returns the same owner. Create each directory's offerer
 * through it. */
export function inboxPublisher(host: Host): InboxPublisher {
	const held = publishers.get(host);
	if (held !== undefined) return held;
	// Every name minted so far, and whether `publishGiftable` has taken it. A
	// taken name is spent for good, which is what `MAX_DM_INBOXES` counts; one the
	// host refused is free again.
	const names = new Map<string, boolean>();
	const publisher: InboxPublisher = {
		offerer(opts: InboxOffererOptions): InboxOfferer {
			// The name minted for each peer in this directory. The same spelling in
			// another directory is another authority and gets another alias, but both
			// spend this Host's ledger.
			const minted = new Map<string, string>();
			return {
				offer(peer: string): void {
					const key = peer.toLowerCase();
					if (opts.skip?.(peer)) return;
					const unnameable = nickRefusal(peer);
					if (unnameable !== null) {
						opts.onError?.(peer, new Error(unnameable));
						return;
					}
					let swiss = minted.get(key);
					if (swiss === undefined) {
						if (names.size >= MAX_DM_INBOXES) {
							opts.onError?.(
								peer,
								new Error(`already holding ${MAX_DM_INBOXES} inboxes; not minting another`),
							);
							return;
						}
						// Claim before yielding so two requests cannot race into two
						// aliases. The ledger, rather than probability, owns uniqueness.
						do swiss = mintSwiss(peer); while (names.has(swiss));
						minted.set(key, swiss);
						names.set(swiss, false);
					}
					const name = swiss;
					queueMicrotask(() => {
						const dir = opts.dir();
						if (dir === null || minted.get(key) !== name) {
							// The Host never took this alias. Return its provisional slot;
							// published aliases are permanent and never enter this arm.
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
							// Only a name the Host never took is free again. Once published,
							// forgetting it would mint a second alias while this one answers.
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
					const key = peer.toLowerCase();
					const name = minted.get(key);
					minted.delete(key);
					// A queued publication has no Host authority yet. Return that slot
					// now, not when its microtask eventually notices the forgotten row:
					// the next holder may be offered in this same turn.
					if (name !== undefined && names.get(name) === false) names.delete(name);
				},
			};
		},
	};
	publishers.set(host, publisher);
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
