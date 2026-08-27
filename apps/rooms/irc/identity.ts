// IRC identity outcomes that are independent of socket ownership.

import { ircFold } from "./protocol.ts";
import { validateIrcNick } from "./registration.ts";
import { projectedNick } from "./front/render.ts";

export function automaticIrcNick(nick: string): string {
	try {
		validateIrcNick(nick);
		return nick;
	} catch {
		return projectedNick(nick);
	}
}

export function ircNickRenameRefusal(requested: string, observed: string): string | null {
	if (ircFold(requested) === ircFold(observed)) return null;
	return `IRC changed the chosen nick from <${requested}> to <${observed}>. ` +
		"That nick may require login to its registered account.";
}
