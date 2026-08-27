// The IRC gateway capability, as this tab holds it.
//
// The same shape as every operations capability: the swiss is the authority,
// fetching it on this directory's session is the take, and the rows in the
// store are only what the gateway last said. It lives on the session it was
// fetched on, so a reconnect drops it and the reader takes it again if they
// still want it. Join and part act through the held reference and re-ask, so
// the pane's list is always the gateway's own answer rather than this file's
// bookkeeping.

import { joinIrcChannel, partIrcChannel, snapshotIrcGateway, takeIrcGateway } from "../../../lib/room_client.ts";
import * as store from "../store.ts";
import { dirs } from "./live.ts";
import { opsLost, reason } from "./common.ts";
import { forgetOpsSwiss, rememberOpsSwiss } from "./ops_memory.ts";
import { invalidateOperations } from "../ops/invalidation.ts";
import { type HeldDirectoryCapability, releaseHeldCapability } from "./held_capability.ts";

let gatewayHeld: HeldDirectoryCapability | null = null;

/** Session teardown's drop: return the import while its session is available;
 * the remembered swiss survives so reconnect can take it again. */
export function dropIrcHold(): void {
	const held = gatewayHeld;
	gatewayHeld = null;
	store.setIrcGateway(null);
	releaseHeldCapability(held, "IRC gateway capability release failed");
}

/** The reader's drop, from the Capabilities toggle: the capability goes and
 * so does its remembered swiss. */
export function dropIrcGatewayCap(updateVault = true): void {
	const dir = gatewayHeld?.dir;
	if (updateVault && dir != null && !forgetOpsSwiss("irc", dir)) {
		store.noteTrouble("capability storage", "the saved IRC capability could not be removed");
		return;
	}
	dropIrcHold();
}

/** Fetch the gateway on this directory's session and remember it. Returns an
 * empty string when the tab now holds it, or the reason it would not take. */
export async function takeIrcGatewayCap(pasted: string, remember = false): Promise<string> {
	const home = store.get().homeDir;
	const live = home === null ? null : dirs.get(home) ?? null;
	if (home === null || live === null) return "This directory is not connected yet.";
	try {
		const taken = await takeIrcGateway(live.dir.session, pasted);
		const stored = remember ? rememberOpsSwiss("irc", home, pasted) : forgetOpsSwiss("irc", home);
		if (!stored) {
			releaseHeldCapability(
				{ session: live.dir.session, cap: taken.cap, dir: home },
				"unsaved IRC gateway capability release failed",
			);
			return "This browser refused to update the saved IRC capability.";
		}
		const previous = gatewayHeld;
		gatewayHeld = { session: live.dir.session, cap: taken.cap, dir: home };
		releaseHeldCapability(previous, "replaced IRC gateway capability release failed");
		store.setIrcGateway({ bridged: taken.rows });
		return "";
	} catch (error) {
		return reason(error);
	}
}

/** Ask the gateway in hand for a fresh bridged list. A refusal ends the
 * capability rather than leaving a stale table under a toggle that says it
 * is held, and says so. */
export async function refreshIrcGateway(): Promise<void> {
	const held = gatewayHeld;
	if (held === null) return;
	try {
		const bridged = await snapshotIrcGateway(held.session, held.cap);
		if (gatewayHeld !== held) return;
		store.setIrcGateway({ bridged });
	} catch (error) {
		if (gatewayHeld !== held) return;
		dropIrcHold();
		opsLost("irc", reason(error));
	}
}

/** Bridge one channel. Empty when it stood, otherwise the reason it did not;
 * either way the list shown is the gateway's next answer. */
export async function joinIrcBridge(
	choice: {
		network: string;
		channel: string;
		host: string;
		port: number;
		tls: boolean;
		nick: string;
		sasl?: { account: string; password: string };
	},
): Promise<string> {
	if (gatewayHeld === null) return "This tab no longer holds the gateway.";
	try {
		await joinIrcChannel(gatewayHeld.session, gatewayHeld.cap, choice);
		await invalidateOperations(gatewayHeld.dir);
		return "";
	} catch (error) {
		return reason(error);
	}
}

/** Part one bridged channel; the room leaves the directory with it. */
export async function partIrcBridge(network: string, channel: string): Promise<string> {
	if (gatewayHeld === null) return "This tab no longer holds the gateway.";
	try {
		await partIrcChannel(gatewayHeld.session, gatewayHeld.cap, network, channel);
		await invalidateOperations(gatewayHeld.dir);
		return "";
	} catch (error) {
		return reason(error);
	}
}
