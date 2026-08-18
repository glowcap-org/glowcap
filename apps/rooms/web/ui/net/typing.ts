// Who is typing, and the rule that clears it.
//
// One answer for rooms and direct lines alike, because the flag is the same
// promise either way: somebody is about to say something. A peer that goes
// quiet without sending the "off" is ordinary — a closed tab, a dropped
// connection — so nothing here trusts the far side to end what it started, and
// every flag carries its own expiry.

import * as store from "../store.ts";
import { silencedFrom } from "../types.ts";
import { TYPING_CLEAR_MS } from "../../../lib/limits.ts";

// Another peer's typing flag — one auto-clear rule for rooms and
// direct lines alike, so a dropped "off" still fades. Timers key on
// (conversation, peer): the same nick may type in the room and a DM
// at once, and neither flag may clear the other.
const typingTimers = new Map<string, ReturnType<typeof setTimeout>>();

export function applyTyping(key: string, from: string, on: boolean): void {
	// The one indicator that was left outside the ignore authority: "bob is
	// typing…" over a log that will refuse bob's line promises a message that
	// never comes, again every time he types. A clear still applies, so a flag
	// set just before the ignore cannot linger.
	if (on && silencedFrom(from, false, store.get().ignored)) return;
	const timerKey = `${key}\u0000${from}`;
	const running = typingTimers.get(timerKey);
	if (running) clearTimeout(running);
	if (on) {
		typingTimers.set(
			timerKey,
			setTimeout(() => {
				typingTimers.delete(timerKey);
				store.setTyper(key, from, false);
			}, TYPING_CLEAR_MS),
		);
	} else typingTimers.delete(timerKey);
	store.setTyper(key, from, on);
}

// A room's typing signal, routed to the room that raised it. The key comes from
// the subscribe that installed this callback, because the signal arrives as a
// bare (nick, flag) pair with nothing on it to say which room it came from.
export function setRoomTyping(key: string, from: string, on: boolean): void {
	const conv = store.getConv(key);
	if (conv === null || from === store.dirNick(conv.dir)) return;
	// Only about somebody the room has said is here, which is the rule the away
	// line already holds: a name arriving any other way would be inventing one.
	// It is also what bounds the cost of a flag, one tracked name and one timer
	// apiece, since how many arrive is not this window's choice.
	if (on && !store.hasMember(key, from)) return;
	applyTyping(key, from, on);
}
