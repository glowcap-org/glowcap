// One bridge form act on a live room this page holds.
//
// The scope is the bridge's own word for how far the answers reach, and the
// bridge judges the answers when the room replays them. The intent commits
// before the room ask, matching the durable session's own command: a refresh
// during the ask replays the same request, and taking it back is an explicit
// later act.

import * as store from "../store.ts";
import type { BridgeForm } from "../../../lib/bridge/form.ts";
import { WorkspaceRoomBridgeIntentSchema } from "../../../lib/rooms_state.ts";
import { MEMBERSHIP_NOT_CONNECTED, reason } from "./common.ts";
import { convSession } from "./live.ts";
import type { RoomsPageContext } from "../page.ts";
import * as z from "zod/mini";

/** The declared bridge form for a room this page holds live, or null when
 * its bridge declares none or the room is not connected yet. */
export async function askRoomBridgeForm(page: RoomsPageContext, key: string): Promise<BridgeForm | null> {
	const room = convSession(page, key)?.rooms.get(key);
	if (room == null) return null;
	return await room.bridgeForm();
}

export async function submitBridgeForm(
	page: RoomsPageContext,
	key: string,
	scope: string,
	action: string,
	answers: Record<string, string>,
	secrets: Record<string, string>,
): Promise<string> {
	const projection = page.projection;
	const parsed = z.safeParse(WorkspaceRoomBridgeIntentSchema, {
		scope,
		action,
		answers,
		secretsGiven: Object.keys(secrets).length > 0,
	});
	if (!parsed.success) {
		const why = "That bridge submission is not valid.";
		store.deliver(projection, key, store.sysItem(projection, why));
		return why;
	}
	const room = convSession(page, key)?.rooms.get(key);
	if (room == null) {
		const why = MEMBERSHIP_NOT_CONNECTED;
		store.deliver(projection, key, store.sysItem(projection, why));
		return why;
	}
	store.setRoomBridgeIntent(projection, key, parsed.data, scope);
	store.setRoomBridgeIssue(projection, key, "");
	try {
		const said = await room.submitBridgeForm(action, { ...answers, ...secrets });
		store.setRoomBridgeIssue(projection, key, "");
		if (said !== "") store.deliver(projection, key, store.sysItem(projection, said));
		return "";
	} catch (error) {
		const why = `The room did not apply the bridge form: ${reason(error)}`;
		store.setRoomBridgeIssue(projection, key, why);
		store.deliver(projection, key, store.sysItem(projection, why));
		return why;
	}
}
