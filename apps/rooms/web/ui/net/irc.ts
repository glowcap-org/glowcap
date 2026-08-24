// The IRC gateway capability, as this tab holds it.
//
// The same shape as every operations capability: the swiss is the authority,
// fetching it on this directory's session is the take, and the rows in the
// store are only what the gateway last said. It lives on the session it was
// fetched on, so a reconnect drops it and the reader takes it again if they
// still want it. Join and part act through the held reference and re-ask, so
// the pane's list is always the gateway's own answer rather than this file's
// bookkeeping.

import type { Ref, Session } from "@pancake/runtime";
import { joinIrcChannel, partIrcChannel, snapshotIrcGateway, takeIrcGateway } from "../../../lib/room_client.ts";
import * as store from "../store.ts";
import type { DirId } from "../types.ts";
import { dirs } from "./live.ts";
import { opsLost, reason } from "./common.ts";
import { forgetOpsSwiss, rememberOpsSwiss } from "./ops_memory.ts";

let gatewayHeld: { session: Session; cap: Ref; dir: DirId } | null = null;

/** Session teardown's drop: the reference dies with its session, but a
 * remembered swiss survives so the reconnect can take it again. */
export function dropIrcHold(): void {
	if (gatewayHeld === null) return;
	gatewayHeld = null;
	store.setIrcGateway(null);
}

/** The reader's drop, from the Capabilities toggle: the capability goes and
 * so does its remembered swiss. */
export function dropIrcGatewayCap(): void {
	const dir = gatewayHeld?.dir;
	dropIrcHold();
	if (dir !== undefined) forgetOpsSwiss("irc", dir);
}

/** Fetch the gateway on this directory's session and remember it. Returns an
 * empty string when the tab now holds it, or the reason it would not take. */
export async function takeIrcGatewayCap(pasted: string, remember = false): Promise<string> {
	const home = store.get().homeDir;
	const live = home === null ? null : dirs.get(home) ?? null;
	if (home === null || live === null) return "This directory is not connected yet.";
	try {
		const taken = await takeIrcGateway(live.dir.session, pasted);
		gatewayHeld = { session: live.dir.session, cap: taken.cap, dir: home };
		if (remember) rememberOpsSwiss("irc", home, pasted);
		else forgetOpsSwiss("irc", home);
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
	if (gatewayHeld === null) return;
	try {
		store.setIrcGateway({ bridged: await snapshotIrcGateway(gatewayHeld.session, gatewayHeld.cap) });
	} catch (error) {
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
		await refreshIrcGateway();
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
		await refreshIrcGateway();
		return "";
	} catch (error) {
		return reason(error);
	}
}
