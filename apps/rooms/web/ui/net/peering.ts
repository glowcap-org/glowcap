// The operator's hand on this directory's foreign rooms, when a reader holds it.
//
// Publication intent belongs to the workspace document. The leases and the
// peering capability are session objects, rebuilt whenever their directory
// connection comes back. Keeping those lifetimes separate is what makes a
// refresh replay the user's choice without pretending a stale lease survived.

import { DirectoryPeering, type Room, type RoomPublication } from "../../../lib/room_client.ts";
import * as store from "../store.ts";
import type { DirId, PeeringPublication } from "../types.ts";
import {
	addWorkspacePeeringIntent,
	removeWorkspacePeeringForSource,
	removeWorkspacePeeringIntent,
	workspacePeeringIntents,
} from "../workspace_state.ts";
import type { WorkspacePeeringIntent } from "../../../lib/rooms_state.ts";
import { dirAddress, dirs, dirSession } from "./live.ts";
import { reason, trouble } from "./common.ts";
import { rememberedOpsCredentials, rememberOpsSwiss, replaceOpsCredentials } from "./ops_memory.ts";
import { invalidateOperations } from "../ops/invalidation.ts";

/** The peering authority this tab fetched, while it still holds it. */
let peeringHeld: { peering: DirectoryPeering; dir: DirId } | null = null;

/** The revocation lease behind each publication intent this tab realized. */
const leases = new Map<string, RoomPublication>();
const publishing = new Set<string>();
const failures = new Map<string, string>();
let replaying: Promise<void> | null = null;
let droppingPeering: Promise<void> | null = null;

function forgetPeeringWorkspace(directory: DirId): boolean {
	return replaceOpsCredentials(
		rememberedOpsCredentials().filter((credential) =>
			credential.capability !== "peering" || credential.scope !== directory
		),
	);
}

function sourceOf(intent: WorkspacePeeringIntent): { room: Room; dir: DirId; address: string } | null {
	for (const conversation of store.get().convs.values()) {
		if (conversation.persistId !== intent.source || conversation.type !== "room") continue;
		const session = dirSession(conversation.dir);
		const room = session?.rooms.get(conversation.key);
		if (session != null && room != null) {
			return { room, dir: conversation.dir, address: dirAddress(conversation.dir) };
		}
		return null;
	}
	return null;
}

function rowFor(intent: WorkspacePeeringIntent): PeeringPublication {
	const existing = store.get().peering?.publications.find((row) => row.id === intent.id);
	return {
		id: intent.id,
		name: intent.name,
		source: sourceOf(intent)?.address ?? intent.source,
		phase: leases.has(intent.id) ? "live" : existing?.phase === "failed" ? "failed" : "publishing",
	};
}

/** Project every desired intent, including ones whose source room is still reconnecting. */
function refreshRows(): void {
	if (peeringHeld === null) return;
	store.setPeering({ publications: workspacePeeringIntents().map(rowFor) });
}

function patchPublication(id: string, next: Partial<PeeringPublication> | null): void {
	const held = store.get().peering;
	if (held === null) return;
	const publications = next === null
		? held.publications.filter((row) => row.id !== id)
		: held.publications.map((row) => row.id === id ? { ...row, ...next } : row);
	store.setPeering({ publications });
}

/** Attempt one intent against the currently held capability and current room reference. */
async function publishIntent(
	intent: WorkspacePeeringIntent,
	holding: { peering: DirectoryPeering; dir: DirId },
): Promise<void> {
	const source = sourceOf(intent);
	if (source == null) {
		const why = "the source room is not connected yet";
		failures.set(intent.id, why);
		patchPublication(intent.id, { phase: "failed" });
		return;
	}
	if (intent.destination !== holding.dir) {
		const why = "the publication destination is no longer held";
		failures.set(intent.id, why);
		patchPublication(intent.id, { phase: "failed" });
		return;
	}
	try {
		const sourceSession = dirSession(source.dir);
		if (sourceSession === null) {
			failures.set(intent.id, "the source room is not connected yet");
			patchPublication(intent.id, { phase: "failed" });
			return;
		}
		const publication = await holding.peering.publish(intent.name, source.room, sourceSession.dir);
		// A revoke may have removed the intent while this request was in flight.
		// Release the newly returned lease rather than resurrecting an operation the
		// user already removed.
		if (peeringHeld !== holding || !workspacePeeringIntents().some((entry) => entry.id === intent.id)) {
			try {
				publication.release();
			} catch (error) {
				trouble("a publication lease could not be released", error);
			}
			return;
		}
		leases.set(intent.id, publication);
		failures.delete(intent.id);
		patchPublication(intent.id, { phase: "live" });
		try {
			await invalidateOperations(holding.dir);
		} catch (error) {
			trouble("publication invalidation could not be announced", error);
		}
	} catch (error) {
		failures.set(intent.id, reason(error));
		patchPublication(intent.id, { phase: "failed" });
	}
}

/** Replay saved intents after either capability or room realization changes. */
export function replayPeering(): Promise<void> {
	if (peeringHeld === null) return Promise.resolve();
	if (replaying !== null) return replaying;
	const holding = peeringHeld;
	replaying = (async () => {
		refreshRows();
		for (const intent of workspacePeeringIntents()) {
			if (peeringHeld !== holding) return;
			if (leases.has(intent.id) || publishing.has(intent.id)) continue;
			publishing.add(intent.id);
			patchPublication(intent.id, { phase: "publishing" });
			try {
				await publishIntent(intent, holding);
			} finally {
				publishing.delete(intent.id);
			}
		}
	})().finally(() => (replaying = null));
	return replaying;
}

/** Session teardown's drop. Desired intents remain in the workspace document. */
export function dropPeering(): void {
	if (peeringHeld === null) return;
	const holding = peeringHeld;
	peeringHeld = null;
	for (const lease of leases.values()) {
		try {
			lease.release();
		} catch (error) {
			trouble("a publication lease could not be released", error);
		}
	}
	leases.clear();
	store.setPeering(null);
	void holding.peering.close().catch((err) => trouble("the peering authority could not be released", err));
}

/** Forget and release publications sourced by a room the reader is leaving. */
export function forgetPeeringForSource(source: string): void {
	const intents = workspacePeeringIntents().filter((intent) => intent.source === source);
	if (intents.length === 0) return;
	if (!removeWorkspacePeeringForSource(source)) {
		store.noteTrouble("peering persistence", "the room publication intents could not be removed");
		return;
	}
	for (const intent of intents) {
		const lease = leases.get(intent.id);
		if (lease != null) {
			try {
				lease.release();
			} catch (error) {
				trouble("a publication lease could not be released", error);
			}
			leases.delete(intent.id);
		}
		publishing.delete(intent.id);
		patchPublication(intent.id, null);
	}
}

/** Release the capability while leaving desired publication intents intact. */
export function dropPeeringCap(updateVault = true): Promise<void> {
	if (droppingPeering != null) return droppingPeering;
	const holding = peeringHeld;
	if (holding == null) return Promise.resolve();
	if (updateVault && !forgetPeeringWorkspace(holding.dir)) {
		store.noteTrouble("peering persistence", "the capability and publication intents could not be removed");
		return Promise.resolve();
	}
	droppingPeering = retirePeeringCap(holding).finally(() => (droppingPeering = null));
	return droppingPeering;
}

async function retirePeeringCap(holding: { peering: DirectoryPeering; dir: DirId }): Promise<void> {
	if (peeringHeld === holding) {
		peeringHeld = null;
		store.setPeering(null);
	}
	for (const [id, lease] of leases) {
		try {
			lease.release();
		} catch (error) {
			trouble("a publication lease could not be released", error);
		} finally {
			leases.delete(id);
		}
	}
	try {
		await holding.peering.close();
	} catch (error) {
		trouble("the peering authority could not be released", error);
	}
}

/** Fetch the peering authority on this directory's session and replay saved intent. */
export async function takePeeringCap(pasted: string, remember = false): Promise<string> {
	if (droppingPeering != null) await droppingPeering;
	const home = store.get().homeDir;
	const live = home === null ? null : dirs.get(home) ?? null;
	if (home === null || live === null) return "This directory is not connected yet.";
	try {
		const taken = await DirectoryPeering.fetch(live.dir, pasted);
		const stored = remember ? rememberOpsSwiss("peering", home, pasted) : forgetPeeringWorkspace(home);
		if (!stored) {
			await taken.close();
			return "This browser refused to update the saved peering capability.";
		}
		const previous = peeringHeld;
		if (previous != null) await retirePeeringCap(previous);
		peeringHeld = { peering: taken, dir: home };
		refreshRows();
		await replayPeering();
		return "";
	} catch (error) {
		return reason(error);
	}
}

/** Publish one source room, first recording the durable intent. */
export async function publishPeeredRoom(key: string, name: string): Promise<string> {
	const holding = peeringHeld;
	if (holding === null) return "This tab no longer holds the peering capability.";
	const conv = store.getConv(key);
	if (conv === null || conv.type !== "room") return "That room is no longer open in this tab.";
	if (conv.dir === holding.dir) {
		return "That room already lives on this directory. Peering publishes rooms from another one.";
	}
	const source = dirSession(conv.dir);
	if (source?.rooms.get(key) == null) return "That room's directory is not connected right now.";
	const intent: WorkspacePeeringIntent = {
		id: crypto.randomUUID(),
		destination: holding.dir,
		source: conv.persistId,
		name,
	};
	if (!addWorkspacePeeringIntent(intent)) return "This browser refused to save the publication intent.";
	refreshRows();
	await replayPeering();
	return leases.has(intent.id) ? "" : failures.get(intent.id) ?? "The room could not be published right now.";
}

/** Revoke one publication and remove its durable intent. */
export async function revokePeeredPublication(id: string | number): Promise<string> {
	const publicationId = String(id);
	const intent = workspacePeeringIntents().find((entry) => entry.id === publicationId);
	if (intent == null) return "This tab no longer holds that publication's intent.";
	if (!removeWorkspacePeeringIntent(publicationId)) return "This browser refused to save the publication revocation.";
	const lease = leases.get(publicationId);
	publishing.delete(publicationId);
	if (lease == null) {
		patchPublication(publicationId, null);
		return "";
	}
	patchPublication(publicationId, { phase: "revoking" });
	try {
		await lease.revoke();
		leases.delete(publicationId);
		failures.delete(publicationId);
		patchPublication(publicationId, null);
		if (peeringHeld !== null) {
			try {
				await invalidateOperations(peeringHeld.dir);
			} catch (error) {
				trouble("publication invalidation could not be announced", error);
			}
		}
		return "";
	} catch (error) {
		if (!addWorkspacePeeringIntent(intent)) {
			store.noteTrouble("peering persistence", "the failed publication revoke could not be retained");
		}
		failures.set(publicationId, reason(error));
		patchPublication(publicationId, { phase: "failed" });
		return reason(error);
	}
}
