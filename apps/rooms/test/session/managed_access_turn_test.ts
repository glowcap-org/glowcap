// A call a page makes through held access outside the access owner's turn
// only reads and calls. A connection it finds lost is kept in a turn of its
// own, while the control still holds the handle the call went through, and a
// control it attaches is held in a turn of its own. For every standing a share
// can hold, every gesture that waits there, every call it waits on, and every
// call outside a turn made meanwhile, nothing that call saw changes held
// access until the waiting gesture's turn ends. Then the loss is kept, every
// handle is freed exactly once, and none is used after its free.
import { assert, assertEquals } from "../assert.ts";
import { settle, within } from "../support/wait.ts";
import { gestures } from "../support/share_gestures.ts";
import { closedClean, refused } from "../support/held_access_gestures.ts";
import type { Page } from "../support/held_access_page.ts";
import { offeredAt, reach } from "../support/share_standings.ts";
import { atEveryCall, parkAt, runWaiting, type Waiting, waitsAt } from "../support/share_waiting.ts";
import { handleOf, type HeldControl } from "../../web/ui/session/managed/held_control.ts";

/** What a page does through a held control outside a turn. */
const calls: Record<string, (f: Page, control: HeldControl) => Promise<unknown>> = {
	"reads": (f, control) => f.management.refresh(control),
	"lists": (f, control) => f.management.inventory(control),
	"prepares an edit": (f, control) => f.management.prepare(control, { kind: "label", label: "renamed" }, "1"),
};
const narrower = {
	inspect: true,
	pause: false,
	resume: false,
	revoke: false,
	delegateControl: false,
	editCeiling: null,
	issueCeiling: null,
};
/** The controls the page holds around a share, and how the fakes name each. */
const holders: Record<string, { control(f: Page): HeldControl | null; cut: "source" | "made" }> = {
	"the source": { control: (f) => f.sourceRow(), cut: "source" },
	"the new access": { control: (f) => f.management.issued, cut: "made" },
};

/** What runs while a gesture waits, and what it checks once every turn after
 * the gesture has ended. */
type Meanwhile = (f: Page) => Promise<(() => Promise<void>) | null>;
/** Hold `a` at its `at`th call, and run `meanwhile` while it waits. Answers
 * false once `a` makes fewer calls than `at`. */
async function whileWaiting(start: string, a: Waiting, at: number, meanwhile: Meanwhile): Promise<boolean> {
	const f = await reach(start);
	const { parked, first, release } = await parkAt(f, at, () => runWaiting(f, a));
	const after = parked ? await meanwhile(f) : null;
	release();
	const code = await within(first, `${a} to end`);
	assert(code !== "unexpected", `${a} at call ${at} ended unexpectedly`);
	await settle();
	await f.moved();
	await after?.();
	await closedClean(f);
	return parked;
}

/** Where a holder is reached at no call a gesture waits on, so nothing goes
 * through it: the share made no new access yet, ended without one, or the
 * source stays unreached. These rows are not generated. */
const unheld: Record<string, Record<string, Waiting[]>> = {
	prepared: { "the new access": ["relink"] },
	uncertain: { "the new access": ["relink"] },
	conflict: { "the new access": ["relink", "remove the source"] },
	removed: { "the new access": ["press", "relink"] },
	lost: { "the new access": ["relink", "remove the source"], "the source": ["remove the source"] },
	"prepared, source lost": { "the new access": ["Try now on the source", "relink"] },
	"uncertain, source lost": { "the new access": ["Try now on the source", "relink"] },
};
const excluded = (start: string, name: string, a: Waiting) => unheld[start]?.[name]?.includes(a) === true;
let generated = 0;
for (const start of Object.keys(offeredAt)) {
	for (const a of waitsAt(start)) {
		for (const [name, holder] of Object.entries(holders)) {
			if (excluded(start, name, a)) continue;
			for (const [verb, call] of Object.entries(calls)) {
				generated++;
				Deno.test(`a share ${start}: ${name} ${verb} and loses its connection while ${a} waits`, async () => {
					let ran = 0;
					await atEveryCall(a, (at) =>
						whileWaiting(start, a, at, async (f) => {
							const control = holder.control(f);
							if (control == null || control.state.kind !== "reached") return null;
							ran++;
							const before = control.state;
							const handle = handleOf(control);
							f.plan.cut = holder.cut;
							assertEquals(await refused(() => call(f, control)), "session-unreachable");
							f.plan.cut = null;
							await settle();
							assert(control.state === before, `${name} kept its state while ${a} waits`);
							return () => {
								assert(
									handleOf(control) !== handle,
									`${name} let go of the handle that lost its connection`,
								);
								return Promise.resolve();
							};
						}));
					assert(ran > 0, `${name} is reached at some call ${a} waits on`);
				});
			}
		}
		Deno.test(`a share ${start}: a control attached while ${a} waits is held once its turn ends`, async () => {
			await atEveryCall(a, (at) =>
				whileWaiting(start, a, at, async (f) => {
					const attaching = f.management.attach("attached", "ocapn://attached");
					await settle();
					const held = () => f.management.held.some((control) => control.id === "attached");
					assert(!held(), `nothing is held while ${a} waits`);
					return async () => {
						await attaching;
						assert(held(), "the attached control is held");
					};
				}));
		});
	}
}

// A narrower control keeps its request until the session answers, so it is
// made in the owner's turn, as an edit is sent, and waits out a gesture.
Deno.test("a narrower control pressed while a gesture waits is asked for once that gesture's turn ends", async () => {
	const parked = await whileWaiting("prepared", "press", 1, async (f) => {
		const control = f.sourceRow();
		const before = control.state;
		const sharing = f.management.share(control, narrower);
		await settle();
		assertEquals(
			[f.ledger.made("narrower control"), control.state === before],
			[0, true],
			"nothing is asked for while the press waits",
		);
		return async () => {
			const link = await sharing;
			assertEquals([typeof link, f.ledger.made("narrower control")], ["string", 1]);
		};
	});
	assert(parked, "the press waits at its first call");
});

Deno.test("a move a newer link overtook while a gesture waits dials nothing", async () => {
	const f = await reach("prepared");
	const { parked, first, release } = await parkAt(f, 1, () => gestures.press(f));
	assert(parked, "the send to wait");
	await f.breakLink();
	await f.breakLink();
	const before = f.plan.dials;
	release();
	await within(first, "the press to end");
	await settle();
	await f.moved();
	assertEquals(f.plan.dials - before, 1, "only the newest move dials the source");
	await closedClean(f);
});

Deno.test("the holder rows are every standing, waiting gesture, holder and call, less the named unheld ones", () => {
	const waiting = Object.keys(offeredAt).reduce((count, start) => count + waitsAt(start).length, 0);
	let unheldRows = 0;
	for (const [start, byHolder] of Object.entries(unheld)) {
		for (const [name, waits] of Object.entries(byHolder)) {
			assert(name in holders, `${name} is a holder`);
			for (const a of waits) assert(waitsAt(start).includes(a), `${a} waits at ${start}`);
			unheldRows += waits.length;
		}
	}
	const verbs = Object.keys(calls).length;
	assertEquals(generated, (waiting * Object.keys(holders).length - unheldRows) * verbs);
});
