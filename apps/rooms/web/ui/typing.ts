// Who is typing, and the rule that clears it.
//
// One answer for rooms and direct lines alike, because the flag is the same
// promise either way: somebody is about to say something. A peer that goes
// quiet without sending the "off" is ordinary (a closed tab, a dropped
// connection) so nothing here trusts the far side to end what it started, and
// every flag carries its own expiry.

import * as store from "./store.ts";
import { silencedFrom } from "./types.ts";
import { TYPING_CLEAR_MS } from "./limits.ts";
import type { RoomsPageContext } from "./page.ts";

/** Auto-clear timers for peer typing flags, one per (conversation, peer). */
export class PageTyping {
	readonly timers = new Map<string, ReturnType<typeof setTimeout>>();
}

export function applyTyping(page: RoomsPageContext, key: string, from: string, on: boolean): void {
	// The one indicator that was left outside the ignore authority: "bob is
	// typing…" over a log that will refuse bob's line promises a message that
	// never comes, again every time he types. A clear still applies, so a flag
	// set just before the ignore cannot linger.
	if (on && silencedFrom(from, false, page.projection.get().ignored)) return;
	const timerKey = `${key}\u0000${from}`;
	const running = page.typing.timers.get(timerKey);
	if (running) clearTimeout(running);
	if (on) {
		page.typing.timers.set(
			timerKey,
			setTimeout(() => {
				page.typing.timers.delete(timerKey);
				store.setTyper(page.projection, key, from, false);
			}, TYPING_CLEAR_MS),
		);
	} else page.typing.timers.delete(timerKey);
	store.setTyper(page.projection, key, from, on);
}
