// The IRC gateway capability, as this tab holds it.
//
// The same shape as every operations capability: the swiss is the authority,
// fetching it on this directory's session is the take, and the rows in the
// store are only what the gateway last said. It lives on the session it was
// fetched on, so a reconnect drops it and the reader takes it again if they
// still want it. Join and part act through the held reference and re-ask, so
// the pane's list is always the gateway's own answer rather than this file's
// bookkeeping.

import * as store from "../store.ts";
import {
	closeIrcNetwork as requestCloseIrcNetwork,
	joinIrcChannel as requestJoinIrcChannel,
	openIrcNetwork as requestOpenIrcNetwork,
	partIrcChannel,
	snapshotIrcGateway,
	takeIrcGateway,
} from "../../../lib/room/client.ts";
import type { RoomsPageContext } from "../page.ts";
import { DIRECTORY_NOT_CONNECTED, liveHomeDir, opsLost, reason } from "./common.ts";
import { forgetOpsSwiss, rememberOpsSwiss } from "./ops_memory.ts";
import { invalidateOperations } from "../ops/invalidation.ts";
import { type HeldDirectoryCapability, releaseHeldCapability } from "./held_capability.ts";
import { settleCapabilityCleanup } from "../../../lib/capability_cleanup.ts";

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
		const taken = await takeIrcGateway(live.dir.session, pasted);
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
		store.setIrcGateway(page.projection, taken.snapshot);
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
		const snapshot = await snapshotIrcGateway(held.session, held.cap);
		if (page.irc.held !== held) return;
		store.setIrcGateway(page.projection, snapshot);
	} catch (error) {
		if (page.irc.held !== held) return;
		dropIrcHold(page);
		opsLost(page.projection, "irc", reason(error));
	}
}

/** Retain one network configuration without coupling it to a channel lease. */
export async function openIrcConnection(
	page: RoomsPageContext,
	choice: {
		network: string;
		host: string;
		port: number;
		tls: boolean;
		nick: string;
		sasl?: { account: string; password: string };
	},
): Promise<string> {
	const held = page.irc.held;
	if (held === null) return "This tab no longer holds the gateway.";
	try {
		const network = await requestOpenIrcNetwork(held.session, held.cap, choice);
		settleCapabilityCleanup("IRC network capability release failed", () => held.session.release(network));
		await invalidateOperations(page, held.dir);
		return "";
	} catch (error) {
		return reason(error);
	}
}

export async function closeIrcConnection(page: RoomsPageContext, network: string): Promise<string> {
	if (page.irc.held === null) return "This tab no longer holds the gateway.";
	try {
		await requestCloseIrcNetwork(page.irc.held.session, page.irc.held.cap, network);
		await invalidateOperations(page, page.irc.held.dir);
		return "";
	} catch (error) {
		return reason(error);
	}
}

/** Part one bridged channel; the room leaves the directory with it. */
export async function partIrcBridge(page: RoomsPageContext, network: string, channel: string): Promise<string> {
	if (page.irc.held === null) return "This tab no longer holds the gateway.";
	try {
		await partIrcChannel(page.irc.held.session, page.irc.held.cap, network, channel);
		await invalidateOperations(page, page.irc.held.dir);
		return "";
	} catch (error) {
		return reason(error);
	}
}

export async function joinIrcBridge(page: RoomsPageContext, network: string, channel: string): Promise<string> {
	if (page.irc.held === null) return "This tab no longer holds the gateway.";
	try {
		await requestJoinIrcChannel(page.irc.held.session, page.irc.held.cap, network, channel);
		await invalidateOperations(page, page.irc.held.dir);
		return "";
	} catch (error) {
		return reason(error);
	}
}
