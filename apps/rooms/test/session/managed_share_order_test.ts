// A person can press anything the page offers while an earlier gesture still
// waits on the session. For every standing a share can hold, every gesture
// that waits there, every call it waits on, and every gesture the page offers
// while it waits, the page lands where pressing them one after the other
// lands: the same standing, the same refusals, and every handle freed exactly
// once with none used after its free. A gesture no longer offered when its
// turn comes does nothing. A close meanwhile ends the waiting gesture without a
// hang and frees everything once. A dropped link is no gesture: it drops at
// once, under whatever call waits, so the page then frees everything once and
// still offers a way on for the share itself, or has ended it.
import { assert, assertEquals } from "../assert.ts";
import { settle, within } from "../support/wait.ts";
import { gestures, offers } from "../support/share_gestures.ts";
import { refused, relink } from "../support/held_access_gestures.ts";
import type { Page } from "../support/held_access_page.ts";
import { offeredAt, reach, standing } from "../support/share_standings.ts";
import { type ShareGesture, shareGestures } from "../support/share_offers.ts";
import { atEveryCall, parkAt, waitsAt } from "../support/share_waiting.ts";

/** What can happen while a gesture waits: a gesture the page offers, the link
 * dropping, or the page closing. */
type Event = ShareGesture | "relink" | "close";
const run = (f: Page, event: Event): Promise<unknown> =>
	event === "relink" ? relink(f) : event === "close" ? f.close() : gestures[event](f);
/** Whether `event` can happen on `f` now. */
const possible = (f: Page, event: Event) => event === "relink" || event === "close" || offers(f).includes(event);

/** Whether the share has ended, or the page offers a gesture that takes the
 * share itself on. Removing an access is no way on for the share. */
const goesOn = (f: Page) =>
	f.management.issue == null || offers(f).some((gesture) =>
		gesture !== "remove the source" &&
		gesture !== "remove the new access"
	);
/** How a run ended: the share's standing, each event's code, and the ledger
 * once the page closed. */
async function ended(f: Page, codes: (string | null)[]) {
	await settle();
	const said = standing(f);
	const next = goesOn(f);
	await within(f.close(), "the page to close");
	return { standing: said, codes, wrong: f.ledger.wrong(), misuse: f.ledger.misuse, next };
}
/** `a`, then `b` once `a` has ended, if `b` is pressed. */
async function oneAfterOther(start: string, a: Event, b: Event | null) {
	const f = await reach(start);
	const codes = [await refused(() => run(f, a))];
	if (b != null) codes.push(possible(f, b) ? await refused(() => run(f, b)) : null);
	return await ended(f, codes);
}
/** `a`, held at its `at`th call, and `b` pressed meanwhile when the page offers
 * it then. Answers null once `a` makes fewer calls than `at`. */
async function meanwhile(start: string, a: Event, b: Event, at: number) {
	const f = await reach(start);
	const { parked, first, release } = await parkAt(f, at, () => run(f, a));
	if (!parked) {
		release();
		await first;
		await within(f.close(), "the page to close");
		return null;
	}
	const pressed = possible(f, b);
	const second = pressed ? refused(() => run(f, b)) : null;
	await settle();
	release();
	const codes = [await within(first, `${a} to end`)];
	if (second != null) codes.push(await within(second, `${b} to end`));
	return { pressed, run: await ended(f, codes) };
}

/** Every event that can happen while another waits. */
const every: Event[] = [...shareGestures, "relink", "close"];

for (const start of Object.keys(offeredAt)) {
	for (const a of waitsAt(start)) {
		for (const b of every) {
			Deno.test(`a share ${start}: ${b} while ${a} waits`, async () => {
				await atEveryCall(a, async (at) => {
					const both = await meanwhile(start, a, b, at);
					if (both == null) return false;
					if (b === "close") {
						assertEquals(both.run.standing, "none", `close at call ${at}`);
						assertEquals([both.run.wrong, both.run.misuse], [[], []], `close at call ${at}`);
						return true;
					}
					if (b === "relink") {
						assertEquals([both.run.wrong, both.run.misuse], [[], []], `relink at call ${at}`);
						assert(!both.run.codes.includes("unexpected"), `relink at call ${at}: ${both.run.codes}`);
						assert(both.run.next, `relink at call ${at} leaves a way on from ${both.run.standing}`);
						return true;
					}
					const alone = await oneAfterOther(start, a, both.pressed ? b : null);
					assertEquals(both.run, alone, `${b} at call ${at} of ${a}`);
					return true;
				});
			});
		}
	}
}
