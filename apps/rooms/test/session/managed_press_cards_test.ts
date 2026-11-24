// The answers of the presses on a share's card, on the Manage card's onward
// share and listing, and on the Hold card. A refused press shows until what it
// answered moves: the share's card answers against its source, whose view
// holds the share, so the answer clears once the share moves, a relink
// picking it up included, and rows of other accesses keep theirs. The listing
// asks for its first page again by itself only once per reach, and a first
// page refused or met with a fault offers to ask again. A fault any of them
// meets is reported once, and the card takes the next press.
import { assert, assertEquals } from "../assert.ts";
import { closedClean, relink } from "../support/held_access_gestures.ts";
import { type Page, page } from "../support/held_access_page.ts";
import { made, prepareShare } from "../support/share_gestures.ts";
import { reach } from "../support/share_standings.ts";
import { settle } from "../support/wait.ts";
import {
	askListing,
	cardOffers,
	closeFinishes,
	holdPress,
	listingAgain,
	listingAsk,
	pressRefused,
	rowPressed,
	type RowRefusals,
	rowRefused,
	shareGestures,
} from "../../web/ui/session/managed/access_card.ts";
import { LocalRefusal } from "../../lib/text/failure.ts";
import { described, type DescribedControl } from "../../web/ui/session/managed/held_control.ts";
import { NO_MANAGEMENT } from "../../web/ui/session/managed/access_powers.ts";
import { noCeilings } from "../support/managed_link.ts";

/** The page's saved source, described. */
function source(f: Page): DescribedControl {
	const held = f.sourceRow();
	assert(described(held), "the source is described");
	return held;
}
/** Press the share card's main button for a share from the source. */
const goOn = (f: Page) => () =>
	shareGestures(f.management, source(f)).goOn(["observeWorkspace"], "shared", false, 0, noCeilings);
/** What `work` rejected with, or null. */
const rejection = (work: Promise<unknown>) => work.then(() => null, (error: unknown) => error);

Deno.test("a share card's refused step clears once its share moves, and stands while it does not", async () => {
	const f = await reach("made");
	f.plan.save = Promise.resolve({ status: "conflict" });
	const answer = await f.management.answer(source(f), goOn(f));
	f.plan.save = null;
	assert(answer != null, "saving the share's new access is refused");
	await f.management.refresh(source(f));
	await f.moved();
	assertEquals(pressRefused(answer, f.management, source(f)), answer.said, "a read that finds nothing new keeps it");
	// The new access is saved from its own row, so the share's next step moves.
	await f.management.save(made(f));
	assertEquals(pressRefused(answer, f.management, source(f)), null, "the share moved, so the answer clears");
	await closedClean(f);
});

Deno.test("a share the session refused is the share card's answer until a new share starts", async () => {
	const f = await page();
	f.plan.answer = "refused";
	const answer = await f.management.answer(source(f), goOn(f));
	assert(answer != null, "the share is refused");
	assertEquals(
		[f.management.issue, answer.said.includes("no such receipt"), pressRefused(answer, f.management, source(f))],
		[null, true, answer.said],
		"no share is under way, and the card says the session's refusal",
	);
	f.plan.answer = "committed";
	await prepareShare(f);
	assertEquals(pressRefused(answer, f.management, source(f)), null, "a new share clears it");
	await closedClean(f);
});

Deno.test("a share card's answer does not stand beside a share a relink picked up", async () => {
	const f = await reach("made");
	f.plan.save = Promise.resolve({ status: "conflict" });
	const answer = await f.management.answer(source(f), goOn(f));
	f.plan.save = null;
	assert(answer != null, "saving the share's new access is refused");
	await relink(f);
	const issue = f.management.issue;
	assertEquals([issue?.phase, issue?.reason, f.plan.replays], ["committed", "", 1], "the relink picks the share up");
	assertEquals(pressRefused(answer, f.management, source(f)), null, "the answer clears");
	await closedClean(f);
});

Deno.test("a share card's lost connection does not stand beside a share the relink picked up", async () => {
	const f = await reach("saved");
	// The source's own connection drops with no call to see it, so getting the
	// link loses it.
	f.dropSource();
	const answer = await f.management.answer(source(f), goOn(f));
	assert(answer != null, "getting the link is refused");
	await relink(f);
	const issue = f.management.issue;
	assertEquals([issue?.phase, issue?.reason], ["committed", ""], "the relink picks the share up");
	assertEquals(pressRefused(answer, f.management, source(f)), null, "the answer clears");
	assertEquals(await f.management.publishIssue(), "the access link");
	await closedClean(f);
});

Deno.test("a share that moves clears a row answer on its source, and other rows keep theirs", async () => {
	const f = await page();
	const row = await f.management.attach("row", "ocapn://another");
	f.plan.save = Promise.resolve({ status: "conflict" });
	const rowAnswer = await f.management.answer(row, () => f.management.save(row));
	f.plan.save = null;
	await prepareShare(f);
	const sourceAnswer = await f.management.answer(source(f), () => f.management.forget(source(f)));
	assert(rowAnswer != null && sourceAnswer != null, "both presses are refused");
	// The list keeps each row's last answer, pressed one row after the other.
	let refusals: RowRefusals = new Map();
	refusals = rowPressed(refusals, f.management, row, rowAnswer);
	refusals = rowPressed(refusals, f.management, source(f), sourceAnswer);
	const answers = () => [rowRefused(refusals, f.management, source(f)), rowRefused(refusals, f.management, row)];
	assertEquals(answers(), [sourceAnswer.said, rowAnswer.said], "both rows answer");
	await f.management.submitIssue();
	assertEquals(answers(), [null, rowAnswer.said], "the share moved, so only its source's answer clears");
	refusals = rowPressed(refusals, f.management, source(f), null);
	assertEquals(answers(), [null, rowAnswer.said], "a press on the source that goes through keeps the row's");
	await closedClean(f);
});

/** The Manage card's presses through its access outside a turn. */
const outside: [string, (f: Page) => Promise<unknown>][] = [
	["an onward share", (f) => f.management.share(source(f), NO_MANAGEMENT)],
	["a listing", (f) => f.management.inventory(source(f))],
];
for (const [press, make] of outside) {
	Deno.test(`${press} that lost its connection is said once, and clears once a relink reaches its access`, async () => {
		const f = await page();
		f.plan.cut = "source";
		const answer = await f.management.answer(source(f), () => make(f));
		await f.moved();
		assert(answer != null, "the press is refused");
		assertEquals(
			[f.sourceRow().state.kind, cardOffers(f.management, source(f), undefined).failure != null],
			["unreached", true],
			"the card says the loss as its access's own failure",
		);
		assertEquals(pressRefused(answer, f.management, source(f)), null, "so the press does not say it again");
		await relink(f);
		assertEquals(
			[f.sourceRow().state.kind, pressRefused(answer, f.management, source(f))],
			["reached", null],
			"the answer does not come back once the access is reached",
		);
		assertEquals(await f.management.answer(source(f), () => make(f)), null, "the press works again");
		await closedClean(f);
	});
}

Deno.test("a listing refused twice asks twice for two reaches, and never while its access is unreached", async () => {
	const f = await page();
	f.plan.inspect = true;
	await f.management.refresh(source(f));
	await f.moved();
	const control = source(f);
	const inventory = f.management.inventory.bind(f.management);
	let asks = 0;
	// Every page asked for loses the access's own connection.
	f.management.inventory = (held, cursor) => {
		asks++;
		f.plan.cut = "source";
		return inventory(held, cursor);
	};
	// As the card's effect does: ask when the key changes and is not null, and
	// while a page is asked for, a second ask is that same one.
	let last: unknown = null;
	let pending: Promise<unknown> | null = null;
	let unreachedAsks = 0;
	const effect = () => {
		const key = listingAsk(control, cardOffers(f.management, control, undefined), false);
		if (key == null || key === last) return;
		if (control.state.kind !== "reached") unreachedAsks++;
		last = key;
		pending ??= f.management.answer(control, () => f.management.inventory(control)).finally(() => {
			pending = null;
		});
	};
	const stop = f.management.subscribe(() => queueMicrotask(effect));
	effect();
	await settle();
	await f.moved();
	assertEquals([control.state.kind, asks], ["unreached", 1], "the first page lost the connection");
	await relink(f);
	await settle();
	await f.moved();
	stop();
	assertEquals([control.state.kind, asks, unreachedAsks], ["unreached", 2, 0], "the reach asked once more");
	await closedClean(f);
});

Deno.test("a fault each card's press meets is reported once, and the card takes the next press", async () => {
	const f = await reach("made");
	const faults: unknown[] = [];
	/** Make `press` meet `fault` once, and hold that it rejected with it. */
	const once = async (press: () => Promise<unknown>) => {
		const fault = new TypeError(`fault ${faults.length}`);
		faults.push(fault);
		f.plan.save = Promise.reject(fault);
		assert(await rejection(press()) === fault, "the fault is rethrown");
		f.plan.save = null;
	};
	// The share card's main button saves the new access.
	await once(() => f.management.answer(source(f), goOn(f)));
	// The Hold card saves the access it holds.
	await once(() => holdPress(f.management, crypto.randomUUID(), "ocapn://held"));
	// The onward share and the listing.
	const share = f.management.share.bind(f.management);
	const inventory = f.management.inventory.bind(f.management);
	const shareFault = new TypeError("the onward share's fault");
	const listingFault = new TypeError("the listing's fault");
	faults.push(shareFault, listingFault);
	f.management.share = () => Promise.reject(shareFault);
	f.management.inventory = () => Promise.reject(listingFault);
	assert(
		await rejection(f.management.answer(source(f), () => f.management.share(source(f), NO_MANAGEMENT))) ===
			shareFault,
		"the onward share's fault is rethrown",
	);
	assert(
		await rejection(f.management.answer(source(f), () => f.management.inventory(source(f)))) === listingFault,
		"the listing's fault is rethrown",
	);
	f.management.share = share;
	f.management.inventory = inventory;
	await settle();
	assertEquals(f.reports, faults, "each fault is reported once");
	// Each card takes its next press.
	assertEquals(await f.management.answer(source(f), goOn(f)), null, "the share goes on");
	assertEquals(f.management.issue?.phase === "committed" && f.management.issue.link, "the access link");
	assertEquals(await holdPress(f.management, crypto.randomUUID(), "ocapn://held"), null, "the Hold card holds");
	assertEquals(await f.management.answer(source(f), () => f.management.share(source(f), NO_MANAGEMENT)), null);
	assertEquals(await f.management.answer(source(f), () => f.management.inventory(source(f))), null);
	assertEquals(f.reports.length, faults.length, "nothing else is reported");
	await closedClean(f);
});

Deno.test("closing a share's card lets go only of a share with nothing left to do, and says a refused close", async () => {
	const f = await reach("made");
	const gestures = shareGestures(f.management, source(f));
	// A share whose new access is not saved stays with management.
	assertEquals(closeFinishes(f.management.issue, false), false, "the card closes and the share stays");
	await f.management.save(made(f));
	await f.management.publishIssue();
	assertEquals(closeFinishes(f.management.issue, true), false, "a press under way closes the card at once");
	assertEquals(closeFinishes(f.management.issue, false), true, "a finished share is let go as the card closes");
	const discard = f.management.discardIssue.bind(f.management);
	f.management.discardIssue = () => Promise.reject(new LocalRefusal("session-closed"));
	const refusal = await f.management.answer(source(f), gestures.finish);
	assert(refusal != null, "the close is refused");
	assertEquals(pressRefused(refusal, f.management, source(f)), refusal.said, "the card says why");
	const fault = new TypeError("the close's fault");
	f.management.discardIssue = () => Promise.reject(fault);
	assert(await rejection(f.management.answer(source(f), gestures.finish)) === fault, "the fault is rethrown");
	f.management.discardIssue = discard;
	await settle();
	assertEquals(f.reports, [fault], "the fault is reported once");
	assertEquals(await f.management.answer(source(f), gestures.finish), null, "the close goes through after");
	assertEquals(f.management.issue, null, "and lets go of the share");
	await closedClean(f);
});

for (const fails of ["refused", "fault"] as const) {
	Deno.test(`a first listing page ${fails === "refused" ? "refused" : "met with a fault"} offers to ask again, and asking lands the page`, async () => {
		const f = await page();
		f.plan.inspect = true;
		await f.management.refresh(source(f));
		await f.moved();
		const control = source(f);
		const offers = cardOffers(f.management, control, undefined);
		f.plan.listingFails = fails;
		const first = await askListing(f.management, control);
		assertEquals(first.kind, fails, "the first page is not landed");
		assertEquals(control.state.kind, "reached", "the access stays reached, so no reach asks again");
		assert(listingAgain(offers, false, first), "the listing offers to ask again");
		assertEquals(f.reports.length, fails === "fault" ? 1 : 0, "a fault is reported once");
		const again = await askListing(f.management, control);
		assertEquals(again.kind, "page", "asking again lands the page");
		assert(!listingAgain(offers, true, again), "a landed page offers nothing more");
		await closedClean(f);
	});
}

Deno.test("an onward share whose connection a relink replaced answers nothing beside the reached access, and the next press reads its control back", async () => {
	const f = await page();
	// The share's first call waits while the page's link breaks. The share
	// keeps the owner's turn, so the move waits for it, and its calls meet the
	// connection the relink replaced.
	const park = f.park(1);
	const sharing = f.management.answer(source(f), () => f.management.share(source(f), NO_MANAGEMENT));
	await park.hit.promise;
	await f.breakLink();
	f.plan.park = null;
	park.release.resolve();
	const answer = await sharing;
	await f.moved();
	assert(answer != null, "the share is refused");
	assertEquals(
		[f.sourceRow().state.kind, pressRefused(answer, f.management, source(f))],
		["reached", null],
		"the access stays reached, and the share's loss does not stand beside it",
	);
	assertEquals(
		[f.management.narrowerPending(source(f)), f.ledger.made("narrower control")],
		[NO_MANAGEMENT, 1],
		"the session made the control, and its lost answer keeps the request",
	);
	assertEquals(await f.management.answer(source(f), () => f.management.share(source(f), NO_MANAGEMENT)), null);
	assertEquals(
		[f.management.narrowerPending(source(f)), f.ledger.made("narrower control")],
		[null, 1],
		"the next press reads the same control back",
	);
	await closedClean(f);
});

Deno.test("a listing page lost with a connection a relink already replaced is asked for again over the new one", async () => {
	const f = await page();
	const park = f.park(1);
	const listing = f.management.answer(source(f), () => f.management.inventory(source(f)));
	await park.hit.promise;
	await relink(f);
	f.plan.park = null;
	park.release.resolve();
	assertEquals(await listing, null, "the listing answers");
	await f.moved();
	assertEquals([f.sourceRow().state.kind, f.plan.listings], ["reached", 2], "the page was asked for twice");
	await closedClean(f);
});
