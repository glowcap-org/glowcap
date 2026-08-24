// The operator's hand on this directory's foreign rooms, when a reader holds it.
//
// Like listeners and inspect beside it, the peering authority is a capability
// the tab fetches by swiss number on the home directory's session, so a
// reconnect drops it and a remembered swiss takes it again. What it does is
// publish: a room this tab has joined on another directory becomes a durable
// room here, listed for everyone until its publication is revoked. The store's
// rows are only this tab's own publications — the leases behind them live
// here, because a lease is the exact authority to revoke one publication and
// a reference is not something a page draws.

import { DirectoryPeering, type Room, type RoomPublication } from "../../../lib/room_client.ts";
import * as store from "../store.ts";
import type { DirId, PeeringPublication } from "../types.ts";
import { dirAddress, dirs, dirSession } from "./live.ts";
import { reason, trouble } from "./common.ts";
import { forgetOpsSwiss, rememberOpsSwiss } from "./ops_memory.ts";

/** The peering authority this tab fetched, while it still holds it. */
let peeringHeld: { peering: DirectoryPeering; dir: DirId } | null = null;

/** The revocation lease behind each publication row this tab made. */
const leases = new Map<number, RoomPublication>();

let nextPublicationId = 1;

/** Session teardown's drop: the authority and every lease die with the session
 * they were fetched on, but the publications themselves are durable and stay
 * listed at the directory, and a remembered swiss survives so the reconnect
 * can take the capability again. */
export function dropPeering(): void {
	if (peeringHeld === null) return;
	const holding = peeringHeld;
	peeringHeld = null;
	leases.clear();
	store.setPeering(null);
	try {
		holding.peering.close();
	} catch (err) {
		trouble("the peering authority could not be released", err);
	}
}

/** The reader's drop, from the Capabilities toggle: the capability goes and so
 * does its remembered swiss — no path may drop the cap but keep the secret
 * the reader asked to give up. Publications stay live, because dropping the
 * hand that made them is not revoking them; their leases are released
 * unrevoked by the close. */
export function dropPeeringCap(): void {
	const dir = peeringHeld?.dir;
	for (const lease of leases.values()) {
		try {
			lease.release();
		} catch (err) {
			trouble("a publication lease could not be released", err);
		}
	}
	dropPeering();
	if (dir !== undefined) forgetOpsSwiss("peering", dir);
}

/** Fetch the peering authority on this directory's session and remember it.
 *
 * Returns an empty string when the tab now holds it, or the reason it would
 * not take. */
export async function takePeeringCap(pasted: string, remember = false): Promise<string> {
	const home = store.get().homeDir;
	const live = home === null ? null : dirs.get(home) ?? null;
	if (home === null || live === null) return "This directory is not connected yet.";
	try {
		const taken = await DirectoryPeering.fetch(live.dir, pasted);
		peeringHeld = { peering: taken, dir: home };
		// The checkbox is the reader's current word on remembering, so an
		// unchecked take erases an earlier memory rather than leaving it to
		// auto-redeem against their answer.
		if (remember) rememberOpsSwiss("peering", home, pasted);
		else forgetOpsSwiss("peering", home);
		store.setPeering({ publications: [] });
		return "";
	} catch (error) {
		return reason(error);
	}
}

/** Replace one publication row, or drop it when `next` is null. */
function patchPublication(id: number, next: Partial<PeeringPublication> | null): void {
	const held = store.get().peering;
	if (held === null) return;
	const publications = next === null
		? held.publications.filter((row) => row.id !== id)
		: held.publications.map((row) => row.id === id ? { ...row, ...next } : row);
	store.setPeering({ publications });
}

/** Publish the room behind one conversation into this directory, durably,
 * under `name`. Empty when the publication is live (its row is already in the
 * store), otherwise the refusal for the pane to show. */
export async function publishPeeredRoom(key: string, name: string): Promise<string> {
	const holding = peeringHeld;
	if (holding === null) return "This tab no longer holds the peering capability.";
	const conv = store.getConv(key);
	if (conv === null || conv.type !== "room") return "That room is no longer open in this tab.";
	if (conv.dir === holding.dir) {
		return "That room already lives on this directory; peering publishes rooms from another one.";
	}
	const source = dirSession(conv.dir);
	const room: Room | undefined = source?.rooms.get(key);
	if (source === null || room === undefined) return "That room's directory is not connected right now.";
	const id = nextPublicationId++;
	const row: PeeringPublication = { id, name, source: dirAddress(conv.dir), phase: "publishing" };
	const held = store.get().peering;
	if (held === null) return "This tab no longer holds the peering capability.";
	store.setPeering({ publications: [...held.publications, row] });
	try {
		const publication = await holding.peering.publish(name, room, source.dir);
		// The capability may have been dropped while the publish was in flight;
		// the publication is live either way, and with nowhere to keep its
		// lease, this tab lets the lease go unrevoked. A failing release must
		// not turn that success into a refusal: the drop already retired the
		// session the lease lived on.
		if (peeringHeld !== holding) {
			try {
				publication.release();
			} catch (err) {
				trouble("a publication lease could not be released", err);
			}
			return "";
		}
		leases.set(id, publication);
		patchPublication(id, { phase: "live" });
		return "";
	} catch (error) {
		if (peeringHeld === holding) patchPublication(id, null);
		return reason(error);
	}
}

/** Revoke one publication this tab made, by its row. Revocation removes the
 * room from the directory's listing; references already handed out stay live,
 * which is the destination's contract rather than this tab's choice. Empty
 * when the row is gone, otherwise the refusal for the pane to show. */
export async function revokePeeredPublication(id: number): Promise<string> {
	const lease = leases.get(id);
	if (lease === undefined) return "This tab no longer holds that publication's lease.";
	patchPublication(id, { phase: "revoking" });
	try {
		await lease.revoke();
		leases.delete(id);
		patchPublication(id, null);
		return "";
	} catch (error) {
		patchPublication(id, { phase: "live" });
		return reason(error);
	}
}
