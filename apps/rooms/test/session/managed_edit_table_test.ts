// An edit through a held access, for every state it can stand in, every event
// that can meet it there, and each kind of access that holds it: the page's
// own, one saved on this session, and one attached from another session. Each
// row runs its event, then asserts where the edit and its access stand, what
// the access's card offers and says, the revision its next change is prepared
// at, that the card leaves a way forward or a way out, that a press the card
// or the access list refused before the event no longer shows once the event
// moved where the edit or its access stands, that a refusal the event's own
// press met is said exactly once, and that every handle is freed exactly once
// with none used after its free. The card's gestures are the card's own verbs,
// pressed through the owner as the card presses them, so the rows press what a
// person presses.
import { assert, assertEquals } from "../assert.ts";
import { settle } from "../support/wait.ts";
import { editSaid } from "../support/managed_link.ts";
import { closedClean, refused, relink } from "../support/held_access_gestures.ts";
import { LandingTable } from "../support/landing_table.ts";
import { attachedLink, type Held } from "../support/held_access_plan.ts";
import { lostForGood, type Page, page, unreached } from "../support/held_access_page.ts";
import {
	canTryNow,
	described,
	type HeldControl,
	OWN_CONTROL,
	standingFailure,
} from "../../web/ui/session/managed/held_control.ts";
import { rowShows } from "../../web/ui/session/managed/access_row.ts";
import { LocalRefusal } from "../../lib/text/failure.ts";
import type { PressRefusal } from "../../web/ui/session/managed/press_answer.ts";
import type { EditIntent, EditState } from "../../web/ui/session/managed/edit_state.ts";
import { managedAccessText as text } from "../../lib/text/managed_access.ts";
import {
	cardGestures,
	type CardOffers,
	cardOffers,
	pressRefused,
	rowRefused,
	wayOn,
} from "../../web/ui/session/managed/access_card.ts";

/** The kinds of access that hold an edit, and the fakes' name for each. */
const holders: Record<string, Held> = { "own": "own", "saved": "source", "attached": "attached" };
const ids: Record<string, string> = { "own": OWN_CONTROL, "saved": "source", "attached": "attached" };

/** A fresh page holding the access `holder` names, reached. */
async function holding(holder: string): Promise<{ f: Page; control: HeldControl }> {
	const f = await page();
	if (holder === "own") await f.management.hold(OWN_CONTROL, await f.ownControl(), { kind: "saved" });
	if (holder === "attached") await f.management.attach("attached", attachedLink);
	const control = f.management.held.find((held) => held.id === ids[holder]);
	assert(control != null, `the ${holder} access is held`);
	return { f, control };
}
/** Fail the next restore of `holder`'s access, as unreached or for good. */
function failRestore(f: Page, holder: string, how: "unreached" | "gone"): void {
	const held = holders[holder];
	if (held === "source") f.plan.sources.push(how === "gone" ? lostForGood : unreached);
	else if (held === "own" || held === "attached") f.plan.restore[held] = how;
}
async function relinked(f: Page): Promise<null> {
	await relink(f);
	return null;
}

/** The revision `control`'s access last read as. */
const base = (control: HeldControl): string => described(control) ? control.state.powers.revision ?? "" : "";
const renamed: EditIntent = { kind: "label", label: "renamed" };
const mine: EditIntent = { kind: "label", label: "mine" };
/** Each state an edit stands in, and how a page gets there. */
const starts: Record<string, (f: Page, control: HeldControl, holder: string) => Promise<unknown>> = {
	"idle": () => Promise.resolve(),
	"prepared": (f, control) => f.management.prepare(control, renamed, base(control)),
	"uncertain": (f, control) => sent(f, control, "uncertain"),
	"uncertain, unreached": (f, control) => sent(f, control, "lost"),
	"conflict": (f, control) => sent(f, control, "conflict"),
	"committed": (f, control) => sent(f, control, "committed"),
	"refused": (f, control) => sent(f, control, "refused"),
	"unreached": (f, control, holder) => {
		f.plan.cut = holders[holder] ?? null;
		return refused(() => f.management.refresh(control));
	},
	"gone": (f, _control, holder) => {
		failRestore(f, holder, "gone");
		return relinked(f);
	},
};
async function sent(f: Page, control: HeldControl, answer: Page["plan"]["edit"]): Promise<void> {
	await f.management.prepare(control, renamed, base(control));
	f.plan.edit = answer;
	await f.management.submit(control);
}

/** What a person can press on the card, and the offer that shows each. */
const gestureOffer = {
	"press": "inputs",
	"check again": "checkAgain",
	"Try now": "tryNow",
	"discard": "discard",
	"save mine": "reapply",
	"remove": "remove",
} satisfies Record<string, keyof CardOffers>;
type Gesture = keyof typeof gestureOffer;
const isGesture = (event: string): event is Gesture => event in gestureOffer;
/** The gestures `offers` show. */
const shown = (offers: CardOffers): string[] =>
	Object.entries(gestureOffer).filter(([, offer]) => offers[offer] === true).map(([gesture]) => gesture);

type Event = (f: Page, control: HeldControl, holder: string, offers: CardOffers) => Promise<string | null>;
/** The answer the owner gave the press each page's event made, if it was refused. */
const answers = new WeakMap<Page, PressRefusal>();
/** Press `press` on `control`'s card through the owner, as the card does, and
 * keep its answer for the row's check. Answers the code it was refused with. */
async function answered(f: Page, control: HeldControl, press: () => Promise<unknown>): Promise<string | null> {
	const answer = await f.management.answer(control, press);
	if (answer == null) return null;
	answers.set(f, answer);
	return await refused(() => Promise.reject(answer.error));
}
const gesture = (run: (verbs: ReturnType<typeof cardGestures>) => Promise<unknown>): Event => (f, control) =>
	answered(f, control, () => run(cardGestures(f.management, control)));
const resend = (answer: Page["plan"]["edit"]): Event => (f) => {
	f.plan.edit = answer;
	return relinked(f);
};
/** Drop the access's own connection with nothing to see it, then press
 * `then` on the card, which sends over the dropped connection. */
const unseen =
	(then: (verbs: ReturnType<typeof cardGestures>, offers: CardOffers) => Promise<unknown>): Event =>
	(f, control, holder, offers) => {
		f.plan.cut = holders[holder] ?? null;
		return answered(f, control, () => then(cardGestures(f.management, control), offers));
	};
const events: Record<string, Event> = {
	"press": (f, control, _holder, offers) =>
		answered(f, control, () => cardGestures(f.management, control).press(mine, offers.base)),
	"check again": gesture((verbs) => verbs.checkAgain()),
	"Try now": gesture((verbs) => verbs.tryNow()),
	"discard": gesture((verbs) => verbs.discard()),
	"save mine": gesture((verbs) => verbs.reapply()),
	"remove": gesture((verbs) => verbs.remove()),
	"close card": (f, control, _holder, offers) => refused(() => cardGestures(f.management, control).close(offers)),
	"relink, access restored": (f) => relinked(f),
	"relink, access unreached": (f, _control, holder) => {
		failRestore(f, holder, "unreached");
		return relinked(f);
	},
	"relink, access gone": (f, _control, holder) => {
		failRestore(f, holder, "gone");
		return relinked(f);
	},
	"relink, the resend commits": resend("committed"),
	"relink, the resend conflicts": resend("conflict"),
	"relink, the resend is refused": resend("refused"),
	"relink, the resend's reply is lost": resend("lost"),
	"relink, the edit cannot move": (f) => {
		f.plan.resumeFails = true;
		return relinked(f);
	},
	"the access's connection drops": (f, control, holder) => {
		f.plan.cut = holders[holder] ?? null;
		return refused(() => f.management.refresh(control));
	},
	"the access's connection drops unseen, then press": unseen((verbs, offers) => verbs.press(mine, offers.base)),
	"the access fails to prepare the change, then press": (f, control, _holder, offers) => {
		f.plan.prepareFails = true;
		return answered(f, control, () => cardGestures(f.management, control).press(mine, offers.base));
	},
	"the access's connection drops unseen, then check again": unseen((verbs) => verbs.checkAgain()),
	"close page": async (f) => {
		await f.close();
		return null;
	},
};
/** The events that send the edit again, which the fakes count. */
const resends = new Set([
	"relink, the resend commits",
	"relink, the resend conflicts",
	"relink, the resend is refused",
	"relink, the resend's reply is lost",
]);

/** What the card shows of the edit, and how the access stands: reached,
 * unreached for a failure its Try now can clear, gone for one it cannot, or
 * released once the page lets go of it. */
function standing(f: Page, control: HeldControl, opened: EditState | undefined): string {
	if (!f.management.held.includes(control)) return "released";
	assert(described(control), "a held access stays described");
	const edit = cardOffers(f.management, control, opened).edit;
	const said = editSaid(edit ?? undefined) ?? "none";
	const reach = control.state.kind === "reached" ? "reached" : canTryNow(control) ? "unreached" : "gone";
	return `${said} ${reach}`;
}
/** What the card offers at each standing. The page's own access stays held,
 * so its card never offers Remove. */
const offered: Record<string, Gesture[]> = {
	"none reached": ["press", "remove"],
	"none unreached": ["Try now", "remove"],
	"none gone": ["remove"],
	"prepared reached": ["discard"],
	"prepared unreached": ["Try now", "discard"],
	"uncertain reached": ["check again", "remove"],
	"uncertain unreached": ["Try now", "remove"],
	"uncertain gone": ["remove"],
	"conflict reached": ["discard", "save mine", "remove"],
	"conflict unreached": ["Try now", "discard", "remove"],
	"conflict gone": ["discard", "remove"],
	"committed reached": ["press", "remove"],
	"committed unreached": ["Try now", "remove"],
	"refused reached": ["press", "remove"],
	"unknown reached": ["press", "remove"],
	"unsent reached": ["press", "remove"],
};
const offeredTo = (at: string, holder: string): string[] =>
	(offered[at] ?? []).filter((gesture) => holder !== "own" || gesture !== "remove");
/** Where each start stands when its card opens. */
const startStanding: Record<string, string> = {
	"idle": "none reached",
	"prepared": "prepared reached",
	"uncertain": "uncertain reached",
	"uncertain, unreached": "uncertain unreached",
	"conflict": "conflict reached",
	"committed": "none reached",
	"refused": "none reached",
	"unreached": "none unreached",
	"gone": "none gone",
};

/** The gesture `event` presses, if it presses one. */
function pressed(event: string): Gesture | null {
	const then = /, then (.+)$/.exec(event)?.[1] ?? event;
	return isGesture(then) ? then : null;
}
/** What a page that runs its session never meets: it holds its own access
 * over no link, so nothing drops, moves, or leaves that access unreached. */
const ownNever = (start: string, event: string): boolean =>
	start === "unreached" || start === "uncertain, unreached" || start === "gone" || event.startsWith("relink") ||
	event.startsWith("the access's connection drops");
/** Why a row is not generated, or null for one that is. */
function excluded(start: string, holder: string, event: string): string | null {
	const at = startStanding[start] ?? "";
	if (holder === "own" && ownNever(start, event)) return "a page that runs its session has no link to lose";
	const gesture = pressed(event);
	if (gesture != null && !offeredTo(at, holder).includes(gesture)) return "the card does not offer it";
	if (event.startsWith("relink, the resend") && !at.startsWith("uncertain")) return "nothing was sent to resend";
	if (event === "relink, the edit cannot move" && !/^(prepared|uncertain) /.test(at)) return "no edit is under way";
	if (event.startsWith("the access's connection drops") && !at.endsWith(" reached")) {
		return "the access holds no connection";
	}
	return null;
}

/** What the card says of the edit at `at`, read from the edit as the owner
 * holds it: its own words, or what its phase says when they are empty. */
function says(control: HeldControl, at: string): string | null {
	const edit = control.edit;
	const [said] = at.split(" ");
	if (edit == null || said === "none") return null;
	if (said === "prepared") return text.unsentEdit;
	if (at === "uncertain unreached" || at === "uncertain gone") return text.sentUnreached;
	if (edit.reason !== "") return edit.reason;
	return said === "committed" && edit.intent.kind !== "revoke" ? text.committedEdit : null;
}
/** Assert what the card says at `at`, and the revision its next change is
 * prepared at: the one the access holds now, once reached. */
function assertCard(f: Page, control: HeldControl, offers: CardOffers, at: string): void {
	assertEquals(offers.answer?.said ?? null, says(control, at), `what the card says at ${at}`);
	if (control.state.kind === "reached") {
		assertEquals(offers.base, String(f.plan.revision), `the revision the next change is prepared at`);
	}
	assertEquals(offers.removeUnconfirmed, at.startsWith("uncertain"), "whether removing stops checking a sent change");
}
/** A press on `control` refused just now by `error`, as the owner answers
 * it: by default a refusal the access does not hold. */
async function refusedPress(
	f: Page,
	control: HeldControl,
	error: unknown = new LocalRefusal("access-unavailable"),
): Promise<PressRefusal> {
	const answer = await f.management.answer(control, () => Promise.reject(error));
	assert(answer != null, "the press was refused");
	return answer;
}
/** Each press on `control`'s row of the access list, refused just now. */
async function refusedRowPresses(f: Page, control: HeldControl): Promise<Record<string, PressRefusal>> {
	const listed: Record<string, PressRefusal> = {};
	for (const press of ["Save", "Remove", "Try now"]) listed[press] = await refusedPress(f, control);
	return listed;
}
/** What `control`'s row says for `refusal`, the last press on it, as the list
 * keeps it. */
function rowSays(f: Page, control: HeldControl, refusal: PressRefusal): string | null {
	return rowRefused(new Map([[control, refusal]]), f.management, control);
}
/** How many times the card says `answer`, the refusal its own press met: as
 * the press's answer, as the access's failure line, or as the edit's answer. */
function timesSaid(f: Page, control: HeldControl, opened: EditState | undefined, answer: PressRefusal): number {
	assert(described(control), "a held access stays described");
	return [
		pressRefused(answer, f.management, control) != null,
		rowShows(control, answer.error),
		cardOffers(f.management, control, opened).answer?.said === answer.said,
	].filter((said) => said).length;
}
/** Whether a page can stand at `start` with `holder`'s access. */
const startPossible = (start: string, holder: string): boolean => !(holder === "own" && ownNever(start, ""));

/** Where each start lands after each event, with the refusal it said. A
 * start's events not listed here land where the start stands, except closing
 * the page, which lets go of every access (`landsAt`). */
const table: Record<string, Record<string, string>> = {
	"idle": {
		"the access fails to prepare the change, then press": "unsent reached !session-request-timed-out",
		"press": "committed reached",
		"remove": "released",
		"relink, access unreached": "none unreached",
		"relink, access gone": "none gone",
		"the access's connection drops": "none unreached !session-unreachable",
		"the access's connection drops unseen, then press": "none unreached !session-unreachable",
	},
	"prepared": {
		"discard": "none reached",
		"close card": "none reached",
		"relink, access unreached": "none unreached",
		"relink, access gone": "none gone",
		"relink, the edit cannot move": "none reached",
		"the access's connection drops": "prepared unreached !session-unreachable",
	},
	"uncertain": {
		"check again": "committed reached",
		"relink, access restored": "committed reached",
		"relink, access unreached": "uncertain unreached",
		"relink, access gone": "uncertain gone",
		"relink, the resend commits": "committed reached",
		"relink, the resend conflicts": "conflict reached",
		"relink, the resend is refused": "refused reached",
		"relink, the resend's reply is lost": "uncertain unreached",
		"relink, the edit cannot move": "unknown reached",
		"the access's connection drops": "uncertain unreached !session-unreachable",
		"the access's connection drops unseen, then check again": "uncertain unreached",
		"remove": "released",
	},
	"uncertain, unreached": {
		"Try now": "committed reached",
		"relink, access restored": "committed reached",
		"relink, access gone": "uncertain gone",
		"relink, the resend commits": "committed reached",
		"relink, the resend conflicts": "conflict reached",
		"relink, the resend is refused": "refused reached",
		"relink, the edit cannot move": "unknown reached",
		"remove": "released",
	},
	"conflict": {
		"discard": "none reached",
		"save mine": "committed reached",
		"remove": "released",
		"close card": "none reached",
		"relink, access unreached": "conflict unreached",
		"relink, access gone": "conflict gone",
		"the access's connection drops": "conflict unreached !session-unreachable",
	},
	"committed": {
		"the access fails to prepare the change, then press": "unsent reached !session-request-timed-out",
		"press": "committed reached",
		"remove": "released",
		"relink, access unreached": "none unreached",
		"relink, access gone": "none gone",
		"the access's connection drops": "none unreached !session-unreachable",
		"the access's connection drops unseen, then press": "none unreached !session-unreachable",
	},
	"refused": {
		"the access fails to prepare the change, then press": "unsent reached !session-request-timed-out",
		"press": "committed reached",
		"remove": "released",
		"relink, access unreached": "none unreached",
		"relink, access gone": "none gone",
		"the access's connection drops": "none unreached !session-unreachable",
		"the access's connection drops unseen, then press": "none unreached !session-unreachable",
	},
	"unreached": {
		"Try now": "none reached",
		"remove": "released",
		"relink, access restored": "none reached",
		"relink, access gone": "none gone",
	},
	"gone": {
		"remove": "released",
		"relink, access restored": "none reached",
		"relink, access unreached": "none unreached",
	},
};

/** Where `event` lands for a start the table names no cell for: where the
 * start stands, unless the event lets go of every access. */
const landsAt = (start: string, event: string): string =>
	table[start]?.[event] ?? (event === "close page" ? "released" : startStanding[start] ?? "");
const edits = new LandingTable("edit");
for (const start of Object.keys(starts)) {
	for (const holder of Object.keys(holders)) {
		for (const event of Object.keys(events)) {
			const why = excluded(start, holder, event);
			if (why != null) {
				edits.leave(why);
				continue;
			}
			edits.row(`the ${holder} access, ${start}: ${event}`, {
				start: async () => {
					const { f, control } = await holding(holder);
					await starts[start]?.(f, control, holder);
					await settle();
					await f.moved();
					const opened = control.edit;
					assertEquals(standing(f, control, opened), startStanding[start], "the start");
					assert(described(control), "the access is described");
					return {
						f,
						control,
						opened,
						sends: f.plan.editSends,
						pressed: await refusedPress(f, control),
						listed: await refusedRowPresses(f, control),
					};
				},
				event: async ({ f, control, opened, sends }) => {
					const code = await events[event]?.(f, control, holder, cardOffers(f.management, control, opened));
					assert(!resends.has(event) || f.plan.editSends > sends, `${event} sent the edit again`);
					assert(event !== "relink, the edit cannot move" || !f.plan.resumeFails, `${event} ran`);
					return code;
				},
				settle: async ({ f }) => {
					await settle();
					await f.moved();
				},
				landing: ({ f, control, opened }, code) => {
					const at = standing(f, control, opened);
					return code == null ? at : `${at} !${code}`;
				},
				expected: landsAt(start, event),
				check: async ({ f, control, opened, pressed, listed }) => {
					const at = standing(f, control, opened);
					// Every answer stands exactly while the access shows what it showed
					// when its press was refused, and a move of the standing is a move
					// of that.
					const held = f.management.held.includes(control);
					const kept = held && f.management.moves(control) === pressed.moves;
					assert(at === startStanding[start] || !kept, `the access moved to ${at}`);
					const own = answers.get(f);
					if (held && own != null) {
						assertEquals(
							timesSaid(f, control, opened, own),
							1,
							`how often the card says the press's refusal`,
						);
					}
					const shownAnswers = () => [
						held ? pressRefused(pressed, f.management, control) : null,
						...Object.values(listed).map((refusal) => rowSays(f, control, refusal)),
					];
					const all = (said: string | null) => [said, said, said, said];
					const standingAnswers = all(kept ? pressed.said : null);
					assertEquals(shownAnswers(), standingAnswers, `the card and each row's answer at ${at}`);
					if (at === "released") return;
					assert(described(control), "a held access stays described");
					const offers = cardOffers(f.management, control, opened);
					assertEquals(shown(offers), offeredTo(at, holder), `what the card offers at ${at}`);
					assert(wayOn(offers), `the card at ${at} leaves a way forward or out`);
					assertCard(f, control, offers, at);
					// A read that finds what the access holds moves nothing, so every
					// answer stays as it stood.
					if (control.state.kind !== "reached" || control.readFailure != null) return;
					const holds = JSON.stringify([control.state.grant, control.state.powers]);
					await f.management.refresh(control);
					await f.moved();
					if (control.state.kind !== "reached") throw new Error(`the read at ${at} lost the access`);
					if (JSON.stringify([control.state.grant, control.state.powers]) !== holds) return;
					assertEquals(
						shownAnswers(),
						standingAnswers,
						`each answer at ${at} after a read that found nothing new`,
					);
				},
				page: ({ f }) => f,
			});
		}
	}
}
edits.pin(Object.keys(starts).length * Object.keys(holders).length * Object.keys(events).length, 194, {
	"a page that runs its session has no link to lose": 126,
	"no edit is under way": 12,
	"nothing was sent to resend": 56,
	"the access holds no connection": 6,
	"the card does not offer it": 146,
});

Deno.test("each edit table cell is a row", () => {
	for (const [start, cells] of Object.entries(table)) {
		assert(start in starts, `${start} is a start`);
		for (const event of Object.keys(cells)) {
			assert(excluded(start, "saved", event) == null, `${start}: ${event} is a row`);
		}
	}
});

Deno.test("each start's card offers what its standing names", async () => {
	for (const start of Object.keys(starts)) {
		for (const holder of Object.keys(holders)) {
			if (!startPossible(start, holder)) continue;
			const { f, control } = await holding(holder);
			await starts[start]?.(f, control, holder);
			await settle();
			await f.moved();
			assert(described(control), "the access is described");
			const at = standing(f, control, control.edit);
			const offers = cardOffers(f.management, control, control.edit);
			assertEquals(shown(offers), offeredTo(at, holder), `${holder}: ${start}`);
			assertCard(f, control, offers, at);
			await closedClean(f);
		}
	}
});

Deno.test("a refused press shows on the card and the list while nothing moved, and clears once the access's state moves", async () => {
	const { f, control } = await holding("saved");
	assert(described(control), "the access is described");
	const pressed = await refusedPress(f, control);
	const listed = await refusedRowPresses(f, control);
	const shown = () => [
		pressRefused(pressed, f.management, control),
		...Object.values(listed).map((refusal) => rowSays(f, control, refusal)),
	];
	const all = [pressed.said, pressed.said, pressed.said, pressed.said];
	assertEquals(shown(), all, "a press that moved nothing");
	await f.management.refresh(control);
	await f.moved();
	assertEquals(shown(), all, "a background read that found nothing new");
	f.plan.cut = "source";
	await refused(() => f.management.refresh(control));
	await f.moved();
	assertEquals([control.state.kind, ...shown()], ["unreached", null, null, null, null]);
	await cardGestures(f.management, control).tryNow();
	assertEquals([control.state.kind, ...shown()], ["reached", null, null, null, null]);
	await closedClean(f);
});

Deno.test("a refused press on an unreached access shows beside the row's failure, and hides only behind that same failure", async () => {
	const { f, control } = await holding("saved");
	f.plan.cut = "source";
	await refused(() => f.management.refresh(control));
	await f.moved();
	assertEquals(control.state.kind, "unreached");
	const other = await refusedPress(f, control);
	const same = await refusedPress(f, control, standingFailure(control));
	const shown = (pressed: PressRefusal) => [
		pressRefused(pressed, f.management, control),
		rowSays(f, control, pressed),
	];
	assertEquals(shown(other), [other.said, other.said], "a failure the row does not hold");
	assertEquals(shown(same), [null, null], "the failure the row's own line says");
	await closedClean(f);
});
