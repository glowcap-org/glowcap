// Being reachable by direct message: one inbox per peer, offered to the room.
//
// The inbox is a *giftable* rather than published on one session because the peer
// reaches it by redeeming an introduction, which dials this host, and a giftable
// is what answers on the connection that dial opens. `Session.publishedRef` then
// names the position the directory's own connection granted it.
//
// Nothing unpublishes a giftable, so a name taken here is taken for the life of
// the process: one Host alias and one actor, plus a lazy export on each Port that
// discovers or receives it. The peer asking is the one who chose the name, so
// `MAX_DM_INBOXES` is the ceiling on how many any of them can spend, and an
// over-long nick is refused outright.
//
// Shared by the browser UI and the direct-message demos.

import type { Behavior, Host, Ref } from "@pancake/stack";
import { MAX_DM_INBOXES, MAX_NICK } from "./limits.ts";
import type { Directory } from "./room_client.ts";

/** Mints and offers direct-message inboxes for named peers. */
export interface InboxOfferer {
	/** Mint an inbox for `peer` if there is none, and offer it to the directory.
	 * Always re-offers: the directory forgets a member's offers whenever the name
	 * either side holds changes hands, and the only way back is to say it again. */
	offer(peer: string): void;
	/** Forget the inbox minted for `peer`, so a later `offer` mints a fresh one.
	 * Call it when the peer leaves: the next holder of that name is someone else
	 * and must not inherit their inbox. The published name stays published,
	 * because nothing withdraws one, so a peer that rejoins costs another. */
	forget(peer: string): void;
}

export interface InboxOffererOptions {
	/** The host the inboxes are published on. It must be the one that accepts a
	 * peer's redeem dial, or the withdraw finds nothing to answer. */
	host: Host;
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

/** Build an {@link InboxOfferer} over `opts`. Pass its `offer` as the
 * `onMintInboxFor` hook of `Directory.register` to answer the directory's
 * requests; call it directly to offer a peer an inbox before they ask. */
export function inboxOfferer(opts: InboxOffererOptions): InboxOfferer {
	// The name of the inbox minted for each peer, by lowercased nick. Never
	// re-minted while present: a second inbox for one peer leaves the first still
	// answering, published under a name nothing can withdraw.
	const minted = new Map<string, string>();
	// Every name minted so far, and whether `publishGiftable` has taken it. A
	// taken name is spent for good, which is what `MAX_DM_INBOXES` counts; one the
	// host refused is free again.
	const names = new Map<string, boolean>();
	return {
		offer(peer: string): void {
			const key = peer.toLowerCase();
			if (opts.skip?.(peer)) return;
			if (peer.length > MAX_NICK) {
				opts.onError?.(peer, new Error(`a name may be at most ${MAX_NICK} characters`));
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
				// Claim the slot before yielding: two requests for one peer must not
				// race into two inboxes.
				swiss = mintSwiss(peer);
				minted.set(key, swiss);
				names.set(swiss, false);
			}
			const name = swiss;
			// `publishGiftable` is refused inside a turn, and the request that brings
			// us here arrives in one.
			queueMicrotask(() => {
				const dir = opts.dir();
				if (dir === null || minted.get(key) !== name) return;
				let ref: Ref | null = null;
				try {
					if (names.get(name) !== true) {
						opts.host.publishGiftable(name, opts.behaviorFor(peer));
						names.set(name, true);
					}
					ref = dir.session.publishedRef(name);
					if (ref === null) throw new Error("the giftable has no live capability");
				} catch (err) {
					// Only a name the host never took is given up. Once it has been
					// published there is no verb that hands it back, so forgetting it
					// here would leave it answering forever and mint a second one on the
					// next try.
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
			minted.delete(peer.toLowerCase());
		},
	};
}

/** An unguessable name for one peer's inbox: a guessable one would let anyone
 * fetch it by name on a connection they opened themselves. */
function mintSwiss(peer: string): string {
	const bytes = new Uint8Array(32);
	crypto.getRandomValues(bytes);
	return `dm-${peer.toLowerCase()}-` +
		[...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}
