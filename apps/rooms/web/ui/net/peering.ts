// The operator's hand on this directory's foreign rooms, when a reader holds it.
//
// Publication intent belongs to the workspace document. The leases and the
// peering capability are session objects, rebuilt whenever their directory
// connection comes back. Keeping those lifetimes separate is what makes a
// refresh replay the user's choice without pretending a stale lease survived.

import * as store from "../store.ts";
import { DirectoryPeering, type Room, type RoomPublication } from "../../../lib/room/client.ts";
import type { DirId, PeeringPublication } from "../types.ts";
import {
	addWorkspacePeeringIntent,
	removeWorkspacePeeringForSource,
	removeWorkspacePeeringIntent,
	workspacePeeringIntents,
} from "../workspace_state.ts";
import type { WorkspacePeeringIntent } from "../../../lib/rooms_state.ts";
import type { RoomsPageContext } from "../page.ts";
import { DIRECTORY_NOT_CONNECTED, liveHomeDir, reason, trouble } from "./common.ts";
import { rememberedOpsCredentials, rememberOpsSwiss, replaceOpsCredentials } from "./ops_memory.ts";
import { invalidateOperations } from "../ops/invalidation.ts";

/** Publication leases and the peering capability one page fetched. */
export class PagePeering {
	held: { peering: DirectoryPeering; dir: DirId } | null = null;
	readonly leases = new Map<string, RoomPublication>();
	readonly publishing = new Set<string>();
	readonly failures = new Map<string, string>();
	replaying: Promise<void> | null = null;
	dropping: Promise<void> | null = null;
}

function forgetPeeringWorkspace(page: RoomsPageContext, directory: DirId): boolean {
	return replaceOpsCredentials(
		page,
		rememberedOpsCredentials(page).filter((credential) =>
			credential.capability !== "peering" || credential.scope !== directory
		),
	);
}

function sourceOf(
	page: RoomsPageContext,
	intent: WorkspacePeeringIntent,
): { room: Room; dir: DirId; address: string } | null {
	for (const conversation of page.projection.get().convs.values()) {
		if (conversation.type !== "room" || conversation.persistId !== intent.source) continue;
		const session = page.live.dirSession(conversation.dir);
		const room = session?.rooms.get(conversation.key);
		if (session != null && room != null) {
			return { room, dir: conversation.dir, address: page.live.dirAddress(conversation.dir) };
		}
		return null;
	}
	return null;
}

function rowFor(page: RoomsPageContext, intent: WorkspacePeeringIntent): PeeringPublication {
	const existing = page.projection.get().peering?.publications.find((row) => row.id === intent.id);
	return {
		id: intent.id,
		name: intent.name,
		source: sourceOf(page, intent)?.address ?? intent.source,
		phase: page.peering.leases.has(intent.id) ? "live" : existing?.phase === "failed" ? "failed" : "publishing",
	};
}

/** Project every desired intent, including ones whose source room is still reconnecting. */
function refreshRows(page: RoomsPageContext): void {
	if (page.peering.held === null) return;
	store.setPeering(page.projection, {
		publications: workspacePeeringIntents(page).map((intent) => rowFor(page, intent)),
	});
}

function patchPublication(
	page: RoomsPageContext,
	id: string,
	next: Partial<PeeringPublication> | null,
): void {
	const held = page.projection.get().peering;
	if (held === null) return;
	const publications = next === null
		? held.publications.filter((row) => row.id !== id)
		: held.publications.map((row) => row.id === id ? { ...row, ...next } : row);
	store.setPeering(page.projection, { publications });
}

/** Attempt one intent against the currently held capability and current room reference. */
async function publishIntent(
	page: RoomsPageContext,
	intent: WorkspacePeeringIntent,
	holding: { peering: DirectoryPeering; dir: DirId },
): Promise<void> {
	const source = sourceOf(page, intent);
	if (source == null) {
		const why = "the source room is not connected yet";
		page.peering.failures.set(intent.id, why);
		patchPublication(page, intent.id, { phase: "failed" });
		return;
	}
	if (intent.destination !== holding.dir) {
		const why = "the publication destination is no longer held";
		page.peering.failures.set(intent.id, why);
		patchPublication(page, intent.id, { phase: "failed" });
		return;
	}
	try {
		const sourceSession = page.live.dirSession(source.dir);
		if (sourceSession === null) {
			page.peering.failures.set(intent.id, "the source room is not connected yet");
			patchPublication(page, intent.id, { phase: "failed" });
			return;
		}
		const publication = await holding.peering.publish(intent.name, source.room, sourceSession.dir);
		// A revoke may have removed the intent while this request was in flight.
		// Release the newly returned lease rather than resurrecting an operation the
		// user already removed.
		if (page.peering.held !== holding || !workspacePeeringIntents(page).some((entry) => entry.id === intent.id)) {
			try {
				publication.release();
			} catch (error) {
				trouble(page.projection, "a publication lease could not be released", error);
			}
			return;
		}
		page.peering.leases.set(intent.id, publication);
		page.peering.failures.delete(intent.id);
		patchPublication(page, intent.id, { phase: "live" });
		try {
			await invalidateOperations(page, holding.dir);
		} catch (error) {
			trouble(page.projection, "publication invalidation could not be announced", error);
		}
	} catch (error) {
		page.peering.failures.set(intent.id, reason(error));
		patchPublication(page, intent.id, { phase: "failed" });
	}
}

/** Replay saved intents after either capability or room realization changes. */
export function replayPeering(page: RoomsPageContext): Promise<void> {
	if (page.peering.held === null) return Promise.resolve();
	if (page.peering.replaying !== null) return page.peering.replaying;
	const holding = page.peering.held;
	page.peering.replaying = (async () => {
		refreshRows(page);
		for (const intent of workspacePeeringIntents(page)) {
			if (page.peering.held !== holding) return;
			if (page.peering.leases.has(intent.id) || page.peering.publishing.has(intent.id)) continue;
			page.peering.publishing.add(intent.id);
			patchPublication(page, intent.id, { phase: "publishing" });
			try {
				await publishIntent(page, intent, holding);
			} finally {
				page.peering.publishing.delete(intent.id);
			}
		}
	})().finally(() => (page.peering.replaying = null));
	return page.peering.replaying;
}

/** Session teardown's drop. Desired intents remain in the workspace document. */
export function dropPeering(page: RoomsPageContext): void {
	const projection = page.projection;
	if (page.peering.held === null) return;
	const holding = page.peering.held;
	page.peering.held = null;
	for (const lease of page.peering.leases.values()) {
		try {
			lease.release();
		} catch (error) {
			trouble(projection, "a publication lease could not be released", error);
		}
	}
	page.peering.leases.clear();
	store.setPeering(projection, null);
	void holding.peering.close().catch((err) =>
		trouble(projection, "the peering authority could not be released", err)
	);
}

/** Forget and release publications sourced by a room the reader is leaving. */
export function forgetPeeringForSource(page: RoomsPageContext, source: string): void {
	const intents = workspacePeeringIntents(page).filter((intent) => intent.source === source);
	if (intents.length === 0) return;
	if (!removeWorkspacePeeringForSource(page, source)) {
		store.noteTrouble(page.projection, "peering persistence", "the room publication intents could not be removed");
		return;
	}
	for (const intent of intents) {
		const lease = page.peering.leases.get(intent.id);
		if (lease != null) {
			try {
				lease.release();
			} catch (error) {
				trouble(page.projection, "a publication lease could not be released", error);
			}
			page.peering.leases.delete(intent.id);
		}
		page.peering.publishing.delete(intent.id);
		patchPublication(page, intent.id, null);
	}
}

/** Release the capability while leaving desired publication intents intact. */
export function dropPeeringCap(page: RoomsPageContext, updateVault = true): Promise<void> {
	if (page.peering.dropping != null) return page.peering.dropping;
	const holding = page.peering.held;
	if (holding == null) return Promise.resolve();
	if (updateVault && !forgetPeeringWorkspace(page, holding.dir)) {
		store.noteTrouble(
			page.projection,
			"peering persistence",
			"the capability and publication intents could not be removed",
		);
		return Promise.resolve();
	}
	page.peering.dropping = retirePeeringCap(page, holding).finally(() => (page.peering.dropping = null));
	return page.peering.dropping;
}

async function retirePeeringCap(
	page: RoomsPageContext,
	holding: { peering: DirectoryPeering; dir: DirId },
): Promise<void> {
	const projection = page.projection;
	if (page.peering.held === holding) {
		page.peering.held = null;
		store.setPeering(projection, null);
	}
	for (const [id, lease] of page.peering.leases) {
		try {
			lease.release();
		} catch (error) {
			trouble(projection, "a publication lease could not be released", error);
		} finally {
			page.peering.leases.delete(id);
		}
	}
	try {
		await holding.peering.close();
	} catch (error) {
		trouble(projection, "the peering authority could not be released", error);
	}
}

/** Fetch the peering authority on this directory's session and replay saved intent. */
export async function takePeeringCap(page: RoomsPageContext, pasted: string, remember = false): Promise<string> {
	if (page.peering.dropping != null) await page.peering.dropping;
	const live = liveHomeDir(page);
	if (live === null) return DIRECTORY_NOT_CONNECTED;
	try {
		const taken = await DirectoryPeering.fetch(live.dir, pasted);
		const stored = remember
			? rememberOpsSwiss(page, "peering", live.id, pasted)
			: forgetPeeringWorkspace(page, live.id);
		if (!stored) {
			await taken.close();
			return "This browser refused to update the saved peering capability.";
		}
		const previous = page.peering.held;
		if (previous != null) await retirePeeringCap(page, previous);
		page.peering.held = { peering: taken, dir: live.id };
		refreshRows(page);
		await replayPeering(page);
		return "";
	} catch (error) {
		return reason(error);
	}
}

/** Publish one source room, first recording the durable intent. */
export async function publishPeeredRoom(page: RoomsPageContext, key: string, name: string): Promise<string> {
	const holding = page.peering.held;
	if (holding === null) return "This tab no longer holds the peering capability.";
	const conv = store.getConv(page.projection, key);
	if (conv === null || conv.type !== "room") return "That room is no longer open in this tab.";
	if (conv.dir === holding.dir) {
		return "That room already lives on this directory. Peering publishes rooms from another one.";
	}
	const source = page.live.dirSession(conv.dir);
	if (source?.rooms.get(key) == null) return "That room's directory is not connected right now.";
	const intent: WorkspacePeeringIntent = {
		id: crypto.randomUUID(),
		destination: holding.dir,
		source: conv.persistId,
		name,
	};
	if (!addWorkspacePeeringIntent(page, intent)) return "This browser refused to save the publication intent.";
	refreshRows(page);
	await replayPeering(page);
	return page.peering.leases.has(intent.id)
		? ""
		: page.peering.failures.get(intent.id) ?? "The room could not be published right now.";
}

/** Revoke one publication and remove its durable intent. */
export async function revokePeeredPublication(page: RoomsPageContext, id: string | number): Promise<string> {
	const publicationId = String(id);
	const intent = workspacePeeringIntents(page).find((entry) => entry.id === publicationId);
	if (intent == null) return "This tab no longer holds that publication's intent.";
	if (!removeWorkspacePeeringIntent(page, publicationId)) {
		return "This browser refused to save the publication revocation.";
	}
	const lease = page.peering.leases.get(publicationId);
	page.peering.publishing.delete(publicationId);
	if (lease == null) {
		patchPublication(page, publicationId, null);
		return "";
	}
	patchPublication(page, publicationId, { phase: "revoking" });
	try {
		await lease.revoke();
		page.peering.leases.delete(publicationId);
		page.peering.failures.delete(publicationId);
		patchPublication(page, publicationId, null);
		if (page.peering.held !== null) {
			try {
				await invalidateOperations(page, page.peering.held.dir);
			} catch (error) {
				trouble(page.projection, "publication invalidation could not be announced", error);
			}
		}
		return "";
	} catch (error) {
		if (!addWorkspacePeeringIntent(page, intent)) {
			store.noteTrouble(
				page.projection,
				"peering persistence",
				"the failed publication revoke could not be retained",
			);
		}
		page.peering.failures.set(publicationId, reason(error));
		patchPublication(page, publicationId, { phase: "failed" });
		return reason(error);
	}
}
