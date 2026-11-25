// Holding a pasted management link: one access is one row. Holding a link
// again, as pressing Hold after its save failed does, answers the row that
// link already holds, so the page makes no second handle and the save is
// tried again on the same row. A row the link no longer reaches is reached
// again first, and one that stays unreached says why in its row's words.
// Removing the row lets go of the link, and removing a saved row releases it
// from storage first, so a release the session refuses keeps the row. A Try now whose read fails leaves the
// failure on the row, which says it once.
import { assert, assertEquals } from "../assert.ts";
import { closedClean, refused } from "../support/held_access_gestures.ts";
import { attachedLink } from "../support/held_access_plan.ts";
import { type Page, page } from "../support/held_access_page.ts";
import { holdLink } from "../../web/ui/session/managed/access_card.ts";
import { rowOffers, rowShows } from "../../web/ui/session/managed/access_row.ts";
import { unreachedAccess } from "../../lib/text/managed_access.ts";
import { failureView } from "../../lib/text/failure.ts";
import type { HeldControl } from "../../web/ui/session/managed/held_control.ts";

/** Press Hold on the card with the attached link. */
const hold = (f: Page) => holdLink(f.management, crypto.randomUUID(), attachedLink);
const attachedRow = (f: Page): HeldControl | undefined => f.management.held.find((control) => control.id !== "source");

Deno.test("Hold after a failed save saves the row the link already holds, and Hold once saved holds it still", async () => {
	const f = await page();
	f.plan.save = Promise.resolve({ status: "conflict" });
	const failed = await refused(() => hold(f));
	f.plan.save = null;
	const again = await refused(() => hold(f));
	const saved = await refused(() => hold(f));
	const rows = f.management.held.filter((control) => control.id !== "source");
	assertEquals(
		[failed == null, again, saved, rows.length, rows[0]?.storage.kind, f.ledger.made("attached control")],
		[false, null, null, 1, "saved", 1],
	);
	await closedClean(f);
});

Deno.test("Hold after a save lost the access's connection reaches the row again and saves it", async () => {
	const f = await page();
	await f.management.attach("attached", attachedLink);
	f.plan.cut = "attached";
	const lost = await refused(() => hold(f));
	assertEquals([lost, attachedRow(f)?.state.kind], ["session-unreachable", "unreached"]);
	const again = await hold(f);
	const rows = f.management.held.filter((control) => control.id !== "source");
	assertEquals(
		[again, rows.length, rows[0]?.state.kind, rows[0]?.storage.kind, f.ledger.made("attached control")],
		[null, 1, "reached", "saved", 2],
	);
	await closedClean(f);
});

Deno.test("Hold of a row whose reach again times out says its session was not reached, and Try now reaches it", async () => {
	const f = await page();
	await f.management.attach("attached", attachedLink);
	f.plan.cut = "attached";
	await refused(() => hold(f));
	// The reach again misses `attachControl`'s own deadline, which reads as a
	// saved row's dial that runs out of time does, so only a Hold that reached
	// again says it.
	f.plan.restore.attached = "timed out";
	const said = await hold(f);
	const row = attachedRow(f);
	assert(row != null && row.state.kind !== "reached", "the row stays held, unreached");
	const unreached = unreachedAccess.get("session-unreachable")?.summary ?? "";
	const offers = rowOffers(f.management, row);
	assertEquals(
		[
			said,
			said?.startsWith(unreached),
			failureView(row.state.failure).code,
			offers.tryNow,
			row.storage.kind,
			"attached" in f.plan.restore,
		],
		[offers.failure, true, "session-unreachable", true, "unsaved", false],
	);
	await f.management.reachAgain(row);
	assertEquals([row.state.kind, rowOffers(f.management, row).failure, f.ledger.made("attached control")], [
		"reached",
		null,
		2,
	]);
	await closedClean(f);
});

Deno.test("Removing a held link's row lets go of the link it was attached from", async () => {
	const f = await page();
	f.plan.save = Promise.resolve({ status: "conflict" });
	await refused(() => hold(f));
	f.plan.save = null;
	const row = attachedRow(f);
	assert(row != null && row.storage.kind === "unsaved", "the row is held, not saved");
	// The link is a bearer secret, so only whether it is kept is printed.
	assert(row.storage.address === attachedLink, "the row keeps the link it was attached from");
	await f.management.forget(row);
	assertEquals([f.management.held.includes(row), row.storage.address == null], [false, true]);
	await closedClean(f);
});

Deno.test("Removing a saved access releases its row from this browser's storage, then lets go of it", async () => {
	const f = await page();
	const source = f.sourceRow();
	await f.management.forget(source);
	assertEquals(
		[f.management.held.includes(source), f.plan.savedRows.has("source"), f.ledger.made("forget")],
		[false, false, 1],
	);
	await closedClean(f);
});

Deno.test("A removal the session refuses keeps the access held and its row saved", async () => {
	const f = await page();
	const source = f.sourceRow();
	f.plan.forget = Promise.resolve({ status: "refused", reason: "not now" });
	const met = await refused(() => f.management.forget(source));
	assertEquals(
		[met == null, f.management.held.includes(source), f.plan.savedRows.has("source"), source.storage.kind],
		[false, true, true, "saved"],
	);
	await closedClean(f);
});

Deno.test("Try now whose read fails says why on the access, and Try now again reads it", async () => {
	const f = await page();
	const source = f.sourceRow();
	f.plan.cut = "source";
	await refused(() => f.management.refresh(source));
	assertEquals(source.state.kind, "unreached");
	f.plan.sourceRead = "transient";
	let met: unknown = null;
	await f.management.reachAgain(source).catch((error: unknown) => {
		met = error;
	});
	const timedOut = unreachedAccess.get("session-request-timed-out")?.summary ?? "";
	const failure = rowOffers(f.management, source).failure ?? "";
	assertEquals(
		[await refused(() => Promise.reject(met)), source.state.kind, failure.startsWith(timedOut)],
		["session-request-timed-out", "reached", true],
	);
	// The row's line says the failure the press met, so the press says nothing.
	assertEquals([rowShows(source, met), rowOffers(f.management, source).tryNow], [true, true]);
	await f.management.reachAgain(source);
	assertEquals([source.readFailure, rowOffers(f.management, source).failure], [undefined, null]);
	await closedClean(f);
});
