// A gesture held open at one call it makes to the session, and something done
// while it waits there, at every call it makes in turn. The turn and order
// tests walk every standing a share can hold this way.
import { assert } from "../assert.ts";
import { within } from "./wait.ts";
import { gestures } from "./share_gestures.ts";
import { refused, relink } from "./held_access_gestures.ts";
import type { ShareGesture } from "./share_offers.ts";
import type { Page } from "./held_access_page.ts";
import { offeredAt } from "./share_standings.ts";

/** What can wait on the session: a gesture the page offers, or the link
 * dropping. */
export type Waiting = ShareGesture | "relink";
export const runWaiting = (f: Page, gesture: Waiting): Promise<unknown> =>
	gesture === "relink" ? relink(f) : gestures[gesture](f);
/** What waits on the session at `start`: each gesture offered there, and the
 * link dropping. Finishing asks the session nothing, so nothing waits on it. */
export function waitsAt(start: string): Waiting[] {
	return [...(offeredAt[start] ?? []).filter((gesture) => gesture !== "finish"), "relink"];
}
/** `run` on `f`, held at its `at`th call. `parked` says whether it got there,
 * `first` is the code it ends with, and `release` lets the held call go on. */
export async function parkAt(f: Page, at: number, run: () => Promise<unknown>) {
	const park = f.park(at);
	const first = refused(run);
	const parked = await within(Promise.race([park.hit.promise.then(() => true), first.then(() => false)]), "a call");
	const release = () => {
		f.plan.park = null;
		park.release.resolve();
	};
	return { parked, first, release };
}
/** Run `attempt` at each call `what` makes, from the first, until it answers
 * that `what` made fewer calls. `what` makes at least one. */
export async function atEveryCall(what: string, attempt: (at: number) => Promise<boolean>): Promise<void> {
	for (let at = 1;; at++) {
		if (await attempt(at)) continue;
		assert(at > 1, `${what} waits on the session`);
		return;
	}
}
