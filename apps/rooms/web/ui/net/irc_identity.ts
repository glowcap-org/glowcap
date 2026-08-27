// The IRC identity attached to one live Rooms membership.

import * as z from "zod/mini";
import * as store from "../store.ts";
import { WorkspaceRoomIrcIdentitySchema } from "../../../lib/rooms_state.ts";
import { reason } from "./common.ts";
import { convSession } from "./live.ts";

export async function connectIrcIdentity(
	key: string,
	nick: string,
	account: string,
	password: string,
): Promise<string> {
	const parsed = z.safeParse(WorkspaceRoomIrcIdentitySchema, { nick, account, password });
	if (!parsed.success) {
		const why = "That IRC identity is not valid.";
		store.deliver(key, store.sysItem(why));
		return why;
	}
	const room = convSession(key)?.rooms.get(key);
	if (room == null) {
		const why = "This room membership is not connected right now.";
		store.deliver(key, store.sysItem(why));
		return why;
	}
	// The requested identity is user intent. Commit it before the external room
	// ask so a refresh during that ask replays the same request; clearing it is
	// an explicit disconnect act.
	store.setRoomIrcIdentity(key, parsed.data);
	store.setRoomIrcIssue(key, "");
	try {
		const said = await room.ircIdentity(nick, account, password);
		store.setRoomIrcIssue(key, "");
		store.deliver(key, store.sysItem(said === "" ? "Your IRC identity is linked." : said));
		return "";
	} catch (error) {
		const why = `The room did not link the IRC identity: ${reason(error)}`;
		store.setRoomIrcIssue(key, why);
		store.deliver(key, store.sysItem(why));
		return why;
	}
}

export async function disconnectIrcIdentity(key: string): Promise<string> {
	const room = convSession(key)?.rooms.get(key);
	if (room == null) {
		const why = "This room membership is not connected right now.";
		store.deliver(key, store.sysItem(why));
		return why;
	}
	try {
		const said = await room.disconnectIrc();
		store.disconnectRoomIrcIdentity(key);
		store.setRoomIrcIssue(key, "");
		store.deliver(key, store.sysItem(said === "" ? "Your IRC identity is disconnected." : said));
		return "";
	} catch (error) {
		const why = `The room did not disconnect the IRC identity: ${reason(error)}`;
		store.setRoomIrcIssue(key, why);
		store.deliver(key, store.sysItem(why));
		return why;
	}
}
