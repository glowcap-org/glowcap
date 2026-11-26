// A share under way when the link breaks goes on through the access it was
// shared from, restored over the new link, with its own request, so the session
// issues at most one access for it. A share with no source to go on through
// ends on its own card, and says what became of the access it may have made.
// A narrower control made for someone else whose answer was lost is asked for
// again by its sequence, so the session answers with the one it made and no
// press makes a second.
// Each scenario runs on the share page's fakes, which hold every handle to one
// free and no use after it.
import { canTryNow, described, handleOf } from "../../web/ui/session/managed/held_control.ts";
import { cardOffers } from "../../web/ui/session/managed/access_card.ts";
import { liveEdit } from "../../web/ui/session/managed/edit_state.ts";
import { assert, assertEquals } from "../assert.ts";
import { settle, until, within } from "../support/wait.ts";
import { editSaid } from "../support/managed_link.ts";
import { deferred } from "../support/managed_viewer.ts";
import { connectionLost, LocalRefusal, refusalText } from "../../lib/text/failure.ts";
import type { LocalRefusalKey } from "../../lib/text/local_refusals.ts";
import { lostForGood, type Page, page, restored, revoked, unreached } from "../support/held_access_page.ts";
import { made as heldMade } from "../support/share_gestures.ts";
import { closedClean, refused, relink } from "../support/held_access_gestures.ts";
import { reach } from "../support/share_standings.ts";

/** The name of the handle the share's new access holds now. */
const madeHandleName = (f: Page) => {
	const made = f.management.issued;
	return Reflect.get((made == null ? null : handleOf(made)) ?? {}, "name");
};

Deno.test("a share the session made before the link broke is picked up over the new link and saved", async () => {
	const f = await reach("made");
	await relink(f);
	assert(f.plan.replays === 1, "the share to be asked for again");
	const issue = f.management.issue;
	const made = heldMade(f);
	assert(issue?.phase === "committed" && issue.access != null, "the share holds the access made");
	assertEquals(madeHandleName(f), "made control 2");
	const old = ["access 1", "made control 1", "source 1"];
	assert(old.every((label) => f.ledger.freed(label)), "the access, control, and source before the move are let go");
	await f.management.save(made);
	assertEquals(await f.management.publishIssue(), "the access link");
	await f.management.discardIssue();
	assertEquals([f.management.issue, f.plan.replays], [null, 1]);
	await closedClean(f);
});

Deno.test("a share saved before the link broke is asked for again, so its link can still be shown", async () => {
	const f = await reach("saved");
	await relink(f);
	assert(f.plan.replays === 1, "the share to be asked for again");
	const issue = f.management.issue;
	assert(issue?.phase === "committed" && issue.access != null, "the share holds the access the session made again");
	assertEquals(issue.reason, "");
	assertEquals(await f.management.publishIssue(), "the access link");
	await f.management.discardIssue();
	assertEquals(f.management.issue, null);
	await closedClean(f);
});

Deno.test("a share Rooms could not confirm before the link broke is sent again only when asked, under its request", async () => {
	const f = await reach("uncertain");
	await relink(f);
	assertEquals(f.management.issue?.phase, "uncertain");
	assertEquals(f.plan.replays, 0, "nothing is sent until the person asks");
	const retried = await f.management.submitIssue();
	assertEquals([retried.phase, f.plan.replays], ["committed", 1]);
	await closedClean(f);
});

Deno.test("a share sent again while its source is being restored waits for the move, and goes out over the new link", async () => {
	const f = await reach("uncertain");
	const restoring = deferred<void>();
	f.plan.sources.push(() => restoring.promise.then(() => f.source()));
	await f.breakLink();
	const again = f.management.submitIssue();
	await settle();
	assertEquals([f.plan.sends - f.plan.replays, f.plan.replays], [1, 0], "nothing goes out while the source moves");
	restoring.resolve();
	assertEquals((await again).phase, "committed");
	assertEquals([f.plan.sends - f.plan.replays, f.plan.replays], [1, 1]);
	await closedClean(f);
});

Deno.test("a made share whose replay loses its source's connection stays made, and Try now on the source picks it up", async () => {
	const f = await reach("made");
	f.plan.replayFails = true;
	await relink(f);
	assert(f.plan.replays === 1, "the share to be asked for again");
	await settle();
	assert(f.management.issue?.reason !== "", "the failed replay to say so");
	const issue = f.management.issue;
	assert(issue != null, "the share stays");
	assertEquals(issue.phase, "committed", "an access the session issued is never downgraded to unconfirmed");
	const unheld = refusalText(new LocalRefusal("access-share-unheld"));
	assert(issue.reason.startsWith(unheld), issue.reason);
	assertEquals(issue.source.state.kind, "unreached", "the replay lost its source's own connection");
	await f.management.reachAgain(issue.source);
	assertEquals([f.management.issue?.phase, f.plan.replays, madeHandleName(f)], ["committed", 2, "made control 2"]);
	await closedClean(f);
});

Deno.test("an edit prepared through a made share's unsaved access moves with it onto the new link", async () => {
	const f = await reach("made");
	await f.management.prepare(heldMade(f), { kind: "label", label: "renamed" }, "1");
	await relink(f);
	await settle();
	const made = f.management.issued;
	assertEquals(madeHandleName(f), "made control 2");
	assertEquals(
		Reflect.get((made == null ? null : liveEdit(made))?.request ?? {}, "name"),
		"moved edit 1",
		"the edit goes on over the new link",
	);
	assert(["made control 1", "edit 1"].every((label) => f.ledger.freed(label)), "the edit before the move is let go");
	await closedClean(f);
});

const unfinishedOutcomes: ("committed" | "uncertain")[] = ["committed", "uncertain"];
for (const outcome of unfinishedOutcomes) {
	Deno.test(`${outcome === "committed" ? "a made" : "an unconfirmed"} share whose source is unreached after the link broke waits on it, and Try now on the source goes on`, async () => {
		const f = await reach(outcome === "committed" ? "made" : "uncertain");
		// The source loses its connection over the new link once.
		f.plan.sources.push(unreached);
		await relink(f);
		await settle();
		const issue = f.management.issue;
		assert(issue != null, "the share stays");
		assertEquals(
			[issue.phase, issue.source.state.kind, f.plan.replays],
			[outcome, "unreached", 0],
			"it waits on its source",
		);
		await f.management.reachAgain(issue.source);
		if (outcome === "uncertain") {
			assertEquals(f.plan.replays, 0, "nothing is sent until the person asks");
			assertEquals((await f.management.submitIssue()).phase, "committed");
		}
		assertEquals([f.management.issue?.phase, f.plan.replays, madeHandleName(f)], [
			"committed",
			1,
			outcome === "committed" ? "made control 2" : "made control 1",
		]);
		await closedClean(f);
	});
}

/** Each way a share ends when it cannot go on, and what its card says. */
const endings: [string, "committed" | "uncertain", "gone" | "revoked", LocalRefusalKey][] = [
	["a made share whose source cannot be restored", "committed", "gone", "access-share-lost"],
	["an unconfirmed share whose source cannot be restored", "uncertain", "gone", "access-share-lost-unknown"],
	["a made share whose source was revoked", "committed", "revoked", "access-share-revoked"],
	["an unconfirmed share whose source was revoked", "uncertain", "revoked", "access-share-revoked"],
];
for (const [name, outcome, source, key] of endings) {
	Deno.test(`${name} ends on its own card and says so`, async () => {
		const f = await reach(outcome === "committed" ? "made" : "uncertain");
		const made = f.management.issued;
		f.plan.sources.push(source === "gone" ? lostForGood : revoked(f));
		await relink(f);
		await settle();
		assert(f.management.issue?.phase === "lost", "the share to end");
		assertEquals(f.management.issue?.reason, refusalText(new LocalRefusal(key)));
		assertEquals(f.plan.replays, 0, "an ended share is not sent again");
		assertEquals(f.reports.filter((error) => error instanceof LocalRefusal), [], "the card says it, not the notes");
		await f.management.discardIssue();
		assertEquals(f.management.issue, null, "closing the card ends the share");
		assert(f.ledger.freed("request 1"), "closing the card releases its request");
		if (made != null) {
			assertEquals(f.management.held.includes(made), false, "the unsaved access goes with the share");
			const pressed = await refused(() => f.management.prepare(made, { kind: "label", label: "renamed" }, "1"));
			assertEquals(pressed, "local-not-sent", "a card left open on it sends nothing");
		}
		await closedClean(f);
	});
}

Deno.test("a share whose new access loses its own connection holds it unreached and leaves the page's link live", async () => {
	const f = await reach("made");
	f.plan.read = "lost";
	await relink(f);
	await settle();
	assertEquals(f.plan.replays, 1, "the share to be asked for again");
	assertEquals(f.management.issued?.state.kind, "unreached", "its row says it is unreached");
	await settle();
	assertEquals([f.reports, f.session.link?.live, f.links()], [[], true, 2], "the page dials no second time");
	await closedClean(f);
});

Deno.test("a share whose new access comes back after the page closed frees it", async () => {
	const f = await reach("made");
	// The third call from here asks the session for the share again: after the
	// dial and the restore read.
	const asking = f.park(3);
	await f.breakLink();
	await until(() => asking.count >= asking.at, "the share to be asked for again over the second link");
	const closing = f.close();
	asking.release.resolve();
	await within(closing, "the page to close");
	assertEquals([f.reports, f.ledger.made("made control"), f.ledger.freed("made control 2")], [[], 2, true]);
	await closedClean(f);
});

Deno.test("a share whose new access fails after a newer link took over says nothing, and the newer link holds it", async () => {
	const f = await reach("made");
	// The fourth call from here reads the new access: after the dial, the
	// restore read, and the replay.
	const reading = f.park(4);
	await f.breakLink();
	await until(() => reading.count >= reading.at, "the new access to be read over the second link");
	await f.breakLink();
	reading.release.resolve();
	await until(
		() => {
			const made = f.management.issued;
			return f.plan.replays === 2 && made != null && handleOf(made) != null;
		},
		"the third link to hold the share",
	);
	await settle();
	assertEquals([f.reports, f.ledger.freed("made control 2")], [[], true]);
	await closedClean(f);
});

Deno.test("a save pressed while the link moves waits for the move, and saves the same access, held again", async () => {
	const f = await reach("made");
	const restoring = deferred<void>();
	const answer = deferred<unknown>();
	f.plan.sources.push(() => restoring.promise.then(() => f.source()));
	f.plan.save = answer.promise;
	const made = heldMade(f);
	await f.breakLink();
	const saving = f.management.save(made).then(() => null, (error: unknown) => error);
	await settle();
	restoring.resolve();
	await until(() => f.ledger.freed("request 1"), "the share to move");
	answer.resolve({ status: "committed" });
	assertEquals(await saving, null, "the save goes through");
	assert(f.management.issued === made && handleOf(made) != null, "the share holds the same access again");
	assertEquals(made.storage.kind, "saved", "and saves it");
	assert(f.ledger.freed("save 1"), "the save's request is freed");
	await f.management.publishIssue();
	await f.management.discardIssue();
	await closedClean(f);
});

Deno.test("a save whose answer was lost after its row was written is saved when asked again over the next link", async () => {
	const f = await reach("made");
	const made = heldMade(f);
	f.plan.save = Promise.resolve({ status: "uncertain" });
	assert(await f.management.save(made).then(() => false, () => true), "the save's answer is lost");
	// Its row was written all the same.
	f.plan.savedRows.add(made.id);
	f.plan.save = null;
	await relink(f);
	await settle();
	assert(f.ledger.freed("save 1"), "the new link prepares the save again");
	await f.management.save(made);
	assertEquals(made.storage.kind, "saved", "the access is saved");
	await f.management.publishIssue();
	await f.management.discardIssue();
	await closedClean(f);
});

Deno.test("a card opened on a share's new access before the link moved edits, saves, and removes the access held now", async () => {
	const f = await reach("made");
	const made = heldMade(f);
	await relink(f);
	await settle();
	assert(f.management.issued === made, "the card holds the access the share holds");
	assertEquals(madeHandleName(f), "made control 2");
	await f.management.prepare(made, { kind: "label", label: "renamed" }, "1");
	assertEquals(editSaid(await f.management.submit(made)), "committed");
	await f.management.save(made);
	await f.management.publishIssue();
	await f.management.discardIssue();
	await f.management.forget(made);
	assertEquals(
		[f.management.held.some((held) => held.id === made.id), f.ledger.freed("made control 2")],
		[false, true],
	);
	assertEquals(f.reports, []);
	await closedClean(f);
});

Deno.test("a share's new access removed once saved stays removed when the link moves, and the share still finishes", async () => {
	const f = await reach("removed");
	await relink(f);
	await settle();
	assertEquals(f.plan.replays, 1, "the share to be asked for again");
	assertEquals([f.management.issued, f.management.held.length, f.reports], [null, 1, []]);
	assert(f.ledger.freed("made control 2"), "the access it answers with is let go");
	assertEquals(await f.management.publishIssue(), "the access link", "its link is still shown");
	await f.management.discardIssue();
	assertEquals(f.management.issue, null);
	await closedClean(f);
});

/** Try now on the share's new access asks the share for it again, after
 * which the access saves and the card closes. */
async function tryNowAndClose(f: Page) {
	const made = f.management.issued;
	assert(made != null && made.state.kind !== "reached", "the new access is held unreached");
	assert(canTryNow(made), "its row offers Try now");
	await f.management.reachAgain(made);
	const again = f.management.issued;
	assert(again === made && handleOf(again) != null, "Try now holds the same access again");
	assertEquals([f.plan.replays, madeHandleName(f)], [1, "made control 2"]);
	await f.management.save(again);
	await f.management.publishIssue();
	await f.management.discardIssue();
	assertEquals(f.management.issue, null, "the card closes");
	await closedClean(f);
}

Deno.test("a share's new access cannot be removed before it is saved, and the share still saves and finishes", async () => {
	const f = await reach("made");
	const made = heldMade(f);
	const removed = await refused(() => f.management.forget(made));
	assertEquals(removed, "local-access-share-made-unsaved");
	await f.management.save(made);
	await f.management.publishIssue();
	await f.management.discardIssue();
	assertEquals([f.management.issue, f.management.held.includes(made)], [null, true]);
	await closedClean(f);
});

Deno.test("a share whose new access loses its connection as it is first read holds it, and Try now asks again", async () => {
	const f = await reach("prepared");
	f.plan.read = "lost";
	await f.management.submitIssue();
	const issue = f.management.issue;
	assert(issue != null, "the share stays");
	assertEquals([issue.phase, issue.reason, f.session.link?.live], ["committed", "", true]);
	await tryNowAndClose(f);
});

Deno.test("a share's new access that loses its connection later is asked for again by Try now", async () => {
	const f = await reach("made");
	f.plan.cut = "made";
	const lost = await f.management.refresh(heldMade(f)).then(() => null, (error: unknown) => error);
	assert(connectionLost(lost), "the read loses the new access's connection");
	await tryNowAndClose(f);
});

Deno.test("a share's source that fails its reread for another reason than a lost connection reports it once", async () => {
	const f = await reach("prepared");
	f.plan.sourceRead = "transient";
	await f.management.submitIssue();
	await settle();
	assertEquals(f.reports.length, 1, "the failure lands nowhere else, so the notes hear it once");
	assertEquals(f.management.issue?.phase, "committed");
	await closedClean(f);
});

const narrower = {
	inspect: true,
	pause: false,
	resume: false,
	revoke: false,
	delegateControl: false,
	editCeiling: null,
	issueCeiling: null,
};

/** A page whose source made a narrower control and lost its connection before
 * the control's link was read, then was reached again over a new handle. */
async function narrowerLost() {
	const f = await page({ delegates: true });
	const source = f.sourceRow();
	assert(
		described(source) && cardOffers(f.management, source, undefined).share,
		"the source offers a narrower control",
	);
	f.plan.narrowerLost = true;
	const lost = await refused(() => f.management.share(source, narrower));
	assertEquals([lost, f.management.narrowerPending(source)], ["session-unreachable", narrower]);
	f.plan.sources.push(restored(f));
	await f.management.reachAgain(source);
	await f.moved();
	assert(f.sourceRow() === source, "the source is the same held access over its new handle");
	return { f, source };
}

Deno.test("a narrower control whose answer was lost is read back over a new handle, never made twice", async () => {
	const { f, source } = await narrowerLost();
	const other = { ...narrower, pause: true };
	const changed = await refused(() => f.management.share(source, other));
	assertEquals(changed, "local-access-narrower-pending", "its choices stay until it is answered or given up");
	const again = await f.management.share(source, narrower);
	assertEquals(
		[again, f.ledger.made("narrower control"), f.ledger.made("narrower control again")],
		["link 0", 1, 1],
		"the session answers the same request with the control it made",
	);
	assertEquals([f.ledger.made("resumed attenuation"), f.management.narrowerPending(source)], [1, null]);
	await closedClean(f);
});

Deno.test("a resent narrower control whose answer is lost again stays asked for, and is still made once", async () => {
	const { f, source } = await narrowerLost();
	f.plan.narrowerLost = true;
	const lostAgain = await refused(() => f.management.share(source, narrower));
	assertEquals([lostAgain, f.management.narrowerPending(source)], ["session-unreachable", narrower]);
	f.plan.sources.push(restored(f));
	await f.management.reachAgain(source);
	await f.moved();
	const again = await f.management.share(source, narrower);
	assertEquals(
		[again, f.ledger.made("narrower control")],
		["link 0", 1],
		"the third press reads the same control back",
	);
	await closedClean(f);
});

Deno.test("a narrower control the session no longer answers for says one may exist, and the next press makes a new one", async () => {
	const { f, source } = await narrowerLost();
	f.plan.narrowerExpired = true;
	const resent = await refused(() => f.management.share(source, narrower));
	assertEquals(
		[resent, f.management.narrowerPending(source)],
		["local-access-narrower-unconfirmed", null],
		"the resend is refused and not made again under the same press",
	);
	assertEquals(f.ledger.made("narrower control"), 1);
	const fresh = await f.management.share(source, narrower);
	assertEquals([fresh, f.ledger.made("narrower control")], ["link 1", 2], "a new press asks for a new control");
	await closedClean(f);
});

Deno.test("a narrower control given up frees its request, and the next press chooses again", async () => {
	const { f, source } = await narrowerLost();
	await f.management.giveUpNarrower(source);
	assertEquals(f.management.narrowerPending(source), null);
	assert(f.ledger.freed("attenuation 1"), "the request is freed");
	const other = { ...narrower, pause: true };
	const fresh = await f.management.share(source, other);
	assertEquals([fresh, f.ledger.made("narrower control")], ["link 1", 2]);
	await closedClean(f);
});
