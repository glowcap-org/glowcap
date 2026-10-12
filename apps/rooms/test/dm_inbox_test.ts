// The inbox Host's publication ledger, held across the directories and
// connections that come and go beneath it.
//
// A publisher counts publications on a host that survives directory reconnects,
// so its ledger must survive them too: the same offerer instance,
// asked to offer the same peer through a *different* directory connection,
// re-offers the inbox it already minted rather than publishing a second one.
// This binding fixture shares one publisher across its directory offerers.
// The ceiling and retirement behavior are
// pinned beside it because aliases published by every child share one Host
// ledger.

import type { Host, Ref } from "@glowcap/runtime";
import { inboxPublisher } from "../lib/dm_inbox.ts";
import type { Directory } from "../lib/room/client.ts";
import { MAX_DM_INBOXES } from "../lib/limits.ts";
import { registrationId } from "./support/registration.ts";

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

/** The offer path defers one microtask. Run it. */
function settle(): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, 0));
}

/** A host that only records what was published, and a directory that only
 * records what was offered. The offerer touches nothing else on either. */
function fakes() {
	const published: string[] = [];
	const unpublished: string[] = [];
	const offered: { peer: string; name: string }[] = [];
	const host = {
		publish(name: string, _behavior: unknown): void {
			published.push(name);
		},
		unpublish(name: string): boolean {
			unpublished.push(name);
			return true;
		},
	} as unknown as Host;
	// Each call mints a distinct "connection": the offerer must not care which
	// one it is speaking through, only that its own ledger is one.
	const freshDir = () =>
		({
			session: {
				publishedRef(name: string): Ref {
					return { name } as unknown as Ref;
				},
			},
			offerInbox(peer: string, _registrationId: string, _opening: string, ref: unknown): Promise<void> {
				offered.push({ peer, name: (ref as { name: string }).name });
				return Promise.resolve();
			},
		}) as unknown as Directory;
	return { published, unpublished, offered, host, freshDir };
}

Deno.test("a reconnect re-offers the same inbox instead of minting a second", async () => {
	const { published, offered, host, freshDir } = fakes();
	let dir = freshDir();
	const offerer = inboxPublisher(host).offerer({ dir: () => dir, behaviorFor: () => () => null });
	offerer.offer("bob", registrationId(1), "opening");
	await settle();
	assert(published.length === 1, `one offer published ${published.length} publications`);
	assert(offered.length === 1 && offered[0].peer === "bob", "the inbox was offered to bob");

	// The directory reconnects: a new connection, the same offerer. The inbox
	// it minted is still published and still answers, so the offer names it
	// again rather than minting a second live alias.
	dir = freshDir();
	offerer.offer("bob", registrationId(1), "opening");
	await settle();
	// Counts read into fresh locals so the asserts above do not pin the mutable
	// lengths to their first literals.
	const republished: number = published.length;
	const reoffered: number = offered.length;
	assert(republished === 1, `a reconnect re-published: ${republished} publications for one peer`);
	assert(reoffered === 2, "the reconnect re-offered the held inbox");
	assert(offered[1].name === offered[0].name, "the re-offer named the same inbox, not a fresh one");
});

Deno.test("forgetting a peer retires its alias and mints non-retargetable authority", async () => {
	const { published, unpublished, offered, host, freshDir } = fakes();
	const dir = freshDir();
	const offerer = inboxPublisher(host).offerer({ dir: () => dir, behaviorFor: () => () => null });
	offerer.offer("bob", registrationId(1), "opening");
	await settle();
	// The peer left; the next holder of the name is somebody else and must not
	// inherit their inbox. The old alias is unpublished, while any already-issued
	// capability remains attached to its exact old native actor.
	offerer.forget(registrationId(1));
	offerer.offer("bob", registrationId(2), "opening");
	await settle();
	assert(published.length === 2, "a forgotten peer gets a fresh inbox");
	assert(offered[1].name !== offered[0].name, "the fresh inbox has a name of its own");
	assert(unpublished.length === 1 && unpublished[0] === offered[0].name, "the old alias was retired first");
});

Deno.test("the inbox ceiling spans every publisher lookup and directory on one Host", async () => {
	const { published, host, freshDir } = fakes();
	const firstDir = freshDir();
	const secondDir = freshDir();
	const refused: string[] = [];
	const first = inboxPublisher(host).offerer({
		dir: () => firstDir,
		behaviorFor: () => () => null,
		onError: (peer) => refused.push(peer),
	});
	// A second lookup must not mint a second ledger. Factory call count is not
	// ownership; Host identity is.
	const second = inboxPublisher(host).offerer({
		dir: () => secondDir,
		behaviorFor: () => () => null,
		onError: (peer) => refused.push(peer),
	});
	const split = Math.floor(MAX_DM_INBOXES / 2);
	for (let i = 0; i < split; i += 1) first.offer(`first-${i}`, registrationId(i + 1), "opening");
	for (let i = split; i < MAX_DM_INBOXES; i += 1) second.offer(`second-${i}`, registrationId(i + 1), "opening");
	await settle();
	assert(published.length === MAX_DM_INBOXES, `the ceiling admitted ${published.length}`);
	second.offer("one-too-many", registrationId(MAX_DM_INBOXES + 1), "opening");
	await settle();
	assert(refused.includes("one-too-many"), "the peer past the ceiling was refused");
	assert(published.length === MAX_DM_INBOXES, "nothing was published past the ceiling");
});

Deno.test("forget returns an unpublished Host slot before its microtask runs", async () => {
	const { published, host, freshDir } = fakes();
	const publisher = inboxPublisher(host);
	const dir = freshDir();
	const offerer = publisher.offerer({
		dir: () => dir,
		behaviorFor: () => () => null,
	});
	offerer.offer("gone-before-publish", registrationId(MAX_DM_INBOXES + 1), "opening");
	offerer.forget(registrationId(MAX_DM_INBOXES + 1));
	// Fill the ledger in this same turn. Deferring the return until the queued
	// publication notices its row is gone would refuse the final live peer.
	for (let i = 0; i < MAX_DM_INBOXES; i += 1) offerer.offer(`live-${i}`, registrationId(i + 1), "opening");
	await settle();
	const admitted: number = published.length;
	assert(admitted === MAX_DM_INBOXES, "the forgotten provisional slot was immediately reusable");
});
