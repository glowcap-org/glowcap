// The answer a refused press on a held access's row or card gets. It is said
// against what the row shows once the press is refused, so a press that waited
// behind a relink is answered. It clears once what the row shows moves, and it
// is said on the row that was pressed. What the row shows holds nothing of the
// link its access was attached from. A press that meets a fault rather than a
// refusal is reported once, and the row stays usable.
import { assert, assertEquals } from "../assert.ts";
import { closedClean, refused, relink } from "../support/held_access_gestures.ts";
import { page, unreached } from "../support/held_access_page.ts";
import { deferred } from "../support/managed_viewer.ts";
import { loseSource, made, prepareShare } from "../support/share_gestures.ts";
import { settle } from "../support/wait.ts";
import {
	cardGestures,
	cardOffers,
	holdLink,
	pressRefused,
	rowRefused,
} from "../../web/ui/session/managed/access_card.ts";
import { pressView, rowOffers, rowShows } from "../../web/ui/session/managed/access_row.ts";
import { described } from "../../web/ui/session/managed/held_control.ts";

/** A link no other part of the page names, so any part of it found in what a
 * row shows came from the link. */
const secretLink = () => `ocapn://${crypto.randomUUID()}`;

Deno.test("a press that waited behind a relink is answered against what the relink left", async () => {
	const f = await page();
	const row = f.sourceRow();
	const restoring = deferred<void>();
	f.plan.sources.push(() => restoring.promise.then(() => f.source()));
	f.plan.forget = Promise.resolve({ status: "conflict" });
	await f.breakLink();
	// The card's Remove waits for the relink, which reaches the access again
	// once its restore answers and reads a change another writer made meanwhile.
	const answering = f.management.answer(row, cardGestures(f.management, row).remove);
	await settle();
	f.plan.revision++;
	restoring.resolve();
	const answer = await answering;
	await f.moved();
	assert(answer != null, "the removal is refused");
	assert(described(row), "the access stays described");
	assertEquals(
		[row.state.kind, row.state.powers.revision, pressRefused(answer, f.management, row)],
		["reached", "2", answer.said],
		"the card says why its removal was refused",
	);
	await closedClean(f);
});

Deno.test("a refused save clears once the access is saved another way", async () => {
	const f = await page();
	const link = secretLink();
	const row = await f.management.attach("row", link);
	f.plan.save = Promise.resolve({ status: "conflict" });
	const answer = await f.management.answer(row, () => f.management.save(row));
	f.plan.save = null;
	assert(answer != null, "the save is refused");
	const before = pressRefused(answer, f.management, row);
	// Hold with the same link saves the row it already holds.
	assertEquals(await holdLink(f.management, crypto.randomUUID(), link), null, "Hold saves the row");
	assertEquals(
		[before, row.storage.kind, pressRefused(answer, f.management, row)],
		[answer.said, "saved", null],
		"the refused save is answered until the row is saved",
	);
	await closedClean(f);
});

Deno.test("a Try now on a share's new access, not yet saved, is answered on the row pressed", async () => {
	const f = await page();
	await prepareShare(f);
	// The new access times out when read, so the share holds it unreached, and
	// then its source loses its connection, which stays lost.
	f.plan.read = "transient";
	await refused(() => f.management.submitIssue());
	await loseSource(f);
	f.plan.sources.push(unreached);
	const access = made(f);
	assert(access.storage.kind === "unsaved" && rowOffers(f.management, access).tryNow, "the row offers Try now");
	const answer = await f.management.answer(access, () => f.management.reachAgain(access));
	await f.moved();
	assert(answer != null, "the Try now is refused");
	// The source's row says the same failure as its own, and the pressed row
	// says it as the press's answer.
	assertEquals(
		[
			rowShows(f.sourceRow(), answer.error),
			rowShows(access, answer.error),
			rowRefused(new Map([[access, answer]]), f.management, access),
		],
		[true, false, answer.said],
		"the pressed row answers the Try now",
	);
	await closedClean(f);
});

Deno.test("what a row shows holds no part of the link its access was attached from", async () => {
	const f = await page();
	const link = secretLink();
	const row = await f.management.attach("row", link);
	// The link is a bearer secret, so only whether it is kept is printed.
	assert(row.storage.kind === "unsaved" && row.storage.address === link, "the row keeps its link");
	const view = pressView(f.management, row);
	const secret = link.slice("ocapn://".length);
	const parts = Array.from({ length: secret.length - 5 }, (_, at) => secret.slice(at, at + 6));
	assert(!parts.some((part) => view.includes(part)), "what the row shows holds no part of its link");
	await closedClean(f);
});

Deno.test("what a share's source shows holds no part of the link the share's new access has", async () => {
	const f = await page();
	const link = secretLink();
	f.plan.accessLink = link;
	await prepareShare(f);
	await f.management.submitIssue();
	await f.management.save(made(f));
	await f.management.publishIssue();
	const issue = f.management.issue;
	assert(issue?.phase === "committed" && issue.link === link, "the share shows its new access's link");
	const view = pressView(f.management, f.sourceRow());
	const secret = link.slice("ocapn://".length);
	const parts = Array.from({ length: secret.length - 5 }, (_, at) => secret.slice(at, at + 6));
	assert(view.includes('"linked":true'), "what the source shows says the link is shown");
	assert(!parts.some((part) => view.includes(part)), "what the source shows holds no part of the link");
	await closedClean(f);
});

Deno.test("a fault a row press or a card gesture meets is reported once, and the row stays usable", async () => {
	const f = await page();
	const row = await f.management.attach("row", secretLink());
	const saving = new TypeError("the save's fault");
	f.plan.save = Promise.reject(saving);
	const rowFault = await f.management.answer(row, () => f.management.save(row)).then(() => null, (error) => error);
	f.plan.save = null;
	await settle();
	assertEquals([rowFault === saving, f.reports.filter((report) => report === saving).length], [true, 1]);
	assertEquals(await f.management.answer(row, () => f.management.save(row)), null, "the row saves after");
	assertEquals(row.storage.kind, "saved");
	const removing = new TypeError("the removal's fault");
	f.plan.forget = Promise.reject(removing);
	const cardFault = await f.management.answer(row, cardGestures(f.management, row).remove).then(
		() => null,
		(error) => error,
	);
	f.plan.forget = null;
	await settle();
	assertEquals([cardFault === removing, f.reports.filter((report) => report === removing).length], [true, 1]);
	assertEquals(f.reports.length, 2, "nothing else is reported");
	assertEquals(await f.management.answer(row, cardGestures(f.management, row).remove), null, "the row removes after");
	assertEquals(f.management.held.includes(row), false);
	await closedClean(f);
});

Deno.test("a submitted edit's end is heard, so the card offers removing its access again", async () => {
	const f = await page();
	const control = f.sourceRow();
	assert(described(control), "the source is described");
	const heard: (string | null)[] = [];
	const stop = f.management.subscribe(() => heard.push(f.management.removal(control)));
	const base = cardOffers(f.management, control, undefined).base;
	await cardGestures(f.management, control).press({ kind: "label", label: "renamed" }, base);
	await f.moved();
	stop();
	assertEquals(
		[control.edit?.phase, f.management.removal(control), heard.at(-1)],
		["ended", null, null],
		"the last change subscribers heard offers removing the access",
	);
	await relink(f);
	await closedClean(f);
});
