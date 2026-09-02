// The IRC gateway capability, as this tab holds it.
//
// The same shape as every operations capability: the swiss is the authority,
// fetching it on this directory's session is the take, and what the store holds
// is only what the gateway last said. It lives on the session it was fetched
// on, so a reconnect drops it and the reader takes it again if they still want
// it. Opening, adding, removing, and closing act through the held reference and
// re-ask, so the pane's view is always the gateway's own answer rather than
// this file's bookkeeping.

import * as store from "../store.ts";
import {
	addBridgeLease as requestAddLease,
	closeBridgeConnection as requestCloseConnection,
	openBridgeConnection as requestOpenConnection,
	removeBridgeLease as requestRemoveLease,
	snapshotBridgeGateway,
	takeBridgeGateway,
} from "../../../lib/room/client.ts";
import type { RoomsPageContext } from "../page.ts";
import { DIRECTORY_NOT_CONNECTED, liveHomeDir, opsLost, reason } from "./common.ts";
import { forgetOpsSwiss, rememberOpsSwiss } from "./ops_memory.ts";
import { invalidateOperations } from "../ops/invalidation.ts";
import { type HeldDirectoryCapability, releaseHeldCapability } from "./held_capability.ts";

/** The IRC gateway one page fetched. */
export class PageIrcGateway {
	held: HeldDirectoryCapability | null = null;
}

/** Session teardown's drop: return the import while its session is available;
 * the remembered swiss survives so reconnect can take it again. */
export function dropIrcHold(page: RoomsPageContext): void {
	const held = page.irc.held;
	page.irc.held = null;
	store.setIrcGateway(page.projection, null);
	releaseHeldCapability(held, "IRC gateway capability release failed");
}

/** The reader's drop, from the Capabilities toggle: the capability goes and
 * so does its remembered swiss. */
export function dropIrcGatewayCap(page: RoomsPageContext, updateVault = true): void {
	const dir = page.irc.held?.dir;
	if (updateVault && dir != null && !forgetOpsSwiss(page, "irc", dir)) {
		store.noteTrouble(page.projection, "capability storage", "the saved IRC capability could not be removed");
		return;
	}
	dropIrcHold(page);
}

/** Fetch the gateway on this directory's session and remember it. Returns an
 * empty string when the tab now holds it, or the reason it would not take. */
export async function takeIrcGatewayCap(page: RoomsPageContext, pasted: string, remember = false): Promise<string> {
	const live = liveHomeDir(page);
	if (live === null) return DIRECTORY_NOT_CONNECTED;
	try {
		const taken = await takeBridgeGateway(live.dir.session, pasted);
		const stored = remember ? rememberOpsSwiss(page, "irc", live.id, pasted) : forgetOpsSwiss(page, "irc", live.id);
		if (!stored) {
			releaseHeldCapability(
				{ session: live.dir.session, cap: taken.cap, dir: live.id },
				"unsaved IRC gateway capability release failed",
			);
			return "This browser refused to update the saved IRC capability.";
		}
		const previous = page.irc.held;
		page.irc.held = { session: live.dir.session, cap: taken.cap, dir: live.id };
		releaseHeldCapability(previous, "replaced IRC gateway capability release failed");
		store.setIrcGateway(page.projection, taken.gateway);
		return "";
	} catch (error) {
		return reason(error);
	}
}

/** Ask the gateway in hand for a fresh bridged list. A refusal ends the
 * capability rather than leaving a stale table under a toggle that says it
 * is held, and says so. */
export async function refreshIrcGateway(page: RoomsPageContext): Promise<void> {
	const held = page.irc.held;
	if (held === null) return;
	try {
		const gateway = await snapshotBridgeGateway(held.session, held.cap);
		if (page.irc.held !== held) return;
		store.setIrcGateway(page.projection, gateway);
	} catch (error) {
		if (page.irc.held !== held) return;
		dropIrcHold(page);
		opsLost(page.projection, "irc", reason(error));
	}
}

/** Open a gateway connection from a reader's connection-form answers. */
export async function openBridgeConnection(page: RoomsPageContext, answers: string): Promise<string> {
	const held = page.irc.held;
	if (held === null) return "This tab no longer holds the gateway.";
	try {
		await requestOpenConnection(held.session, held.cap, answers);
		await invalidateOperations(page, held.dir);
		return "";
	} catch (error) {
		return reason(error);
	}
}

export async function closeBridgeConnection(page: RoomsPageContext, connectionId: string): Promise<string> {
	if (page.irc.held === null) return "This tab no longer holds the gateway.";
	try {
		await requestCloseConnection(page.irc.held.session, page.irc.held.cap, connectionId);
		await invalidateOperations(page, page.irc.held.dir);
		return "";
	} catch (error) {
		return reason(error);
	}
}

/** Remove one lease from a connection; the room leaves the directory with it. */
export async function removeBridgeLease(
	page: RoomsPageContext,
	connectionId: string,
	leaseId: string,
): Promise<string> {
	if (page.irc.held === null) return "This tab no longer holds the gateway.";
	try {
		await requestRemoveLease(page.irc.held.session, page.irc.held.cap, connectionId, leaseId);
		await invalidateOperations(page, page.irc.held.dir);
		return "";
	} catch (error) {
		return reason(error);
	}
}

export async function addBridgeLease(
	page: RoomsPageContext,
	connectionId: string,
	answers: string,
): Promise<string> {
	if (page.irc.held === null) return "This tab no longer holds the gateway.";
	try {
		await requestAddLease(page.irc.held.session, page.irc.held.cap, connectionId, answers);
		await invalidateOperations(page, page.irc.held.dir);
		return "";
	} catch (error) {
		return reason(error);
	}
}
