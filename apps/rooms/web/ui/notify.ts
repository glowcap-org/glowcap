// Desktop notifications when you are @mentioned or sent a direct message.
//
// Opt-in, and off unless the tab is in the background: a notice about a message
// you are already looking at is noise. Both facts it reads — whether notices are
// on, and whether the tab is being looked at — are store fields, so the button
// that toggles the first and the subscriber that writes the second are the only
// authorities for either.

import type { PageProjection } from "./store/core.ts";

export function maybeNotify(projection: PageProjection, title: string, text: string): void {
	const { notifyOn, visible } = projection.get();
	if (!notifyOn || visible) return;
	if (!("Notification" in globalThis) || Notification.permission !== "granted") return;
	try {
		new Notification(title, { body: text.slice(0, 140) });
	} catch {
		/* notification construction can throw on some platforms; ignore */
	}
}
