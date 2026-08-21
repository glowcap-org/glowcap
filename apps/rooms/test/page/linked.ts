// The rail's room panel and the join card are one form.
//
// While the join card is the workarea, the panel in the rooms list is a second
// view of it rather than a form of its own: one room name, one lock, one
// destination, one submission. So this phase presses each half and reads the
// other, and it checks after every one of those presses that the panel is still
// standing — the card is the rest of this form rather than somewhere else to
// go, and a caret or a press landing over there must not take this half away.
//
// Part of the opening conversation in `opening.ts`, run with that page's state
// and leaving the two halves filled in for the join it makes.

import type { Page } from "playwright";
import { fail, fillSettled } from "./harness.ts";

export async function run(tab: Page): Promise<void> {
	// Typed text shows in both halves, the two locks are one lock, and Enter in
	// the rail submits the card itself, which is how the join after this phase
	// happens. Every check below that the panel is still showing is the claim
	// that the two are one form, made at the moment each half acts on the other.
	const railShowing = () =>
		tab.evaluate(() => document.getElementById("newRoom")?.classList.contains("show") ?? false);
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "linked");
	const mirrored = await tab.inputValue("#room");
	if (mirrored !== "linked") {
		fail(`typing in the rail did not reach the join card (its room field says ${JSON.stringify(mirrored)})`);
	}
	await tab.click(".newroom-private");
	if (await tab.getAttribute("#joinPrivate", "aria-pressed") !== "true") {
		fail("the rail's lock did not press the join card's");
	}
	await tab.click("#joinPrivate");
	if (await tab.getAttribute(".newroom-private", "aria-pressed") !== "false") {
		fail("unpressing the join card's lock did not release the rail's");
	}
	await tab.fill("#room", "half");
	if (!await railShowing()) fail("typing in the join card put the rail's own view of it away");
	const mirroredBack = await tab.inputValue("#newRoomInput");
	if (mirroredBack !== "half") {
		fail(`typing in the join card did not reach the rail (its field says ${JSON.stringify(mirroredBack)})`);
	}

	// The third thing they share is where the room lands. The rail's panel says
	// which directory that is, and while the card is up the card's locator field
	// is what decides it — one name being typed into two places cannot be going
	// to two directories. The panel used to state the directory the reader was
	// standing on whatever the card had been aimed at, so naming another
	// directory in the card left the rail promising the room to this one.
	const railWhere = async () => ((await tab.textContent("#newRoom .rwhere-said")) ?? "").trim();
	const atHome = await railWhere();
	if (!atHome.includes("this directory")) {
		fail(
			`the rail's new-room panel did not say the room lands on this page's directory: ${JSON.stringify(atHome)}`,
		);
	}
	// Naming a directory in the card retargets the panel where it stands, with
	// no reopening in between.
	await fillSettled(tab, "#locator", "ocapn://elsewhere-tester.tcp");
	if (!await railShowing()) fail("naming a directory in the join card put the rail's panel away");
	// An address this tab does not hold wears a mark of its own. Every part of
	// the card that colours itself reads that one mark, so leaving it off let
	// each of them fall back separately, and the stripe's fallback is the
	// colour this page's own directory wears: a card aimed somewhere nobody
	// here holds drew itself as if it were aimed at home.
	const aimedMark = await tab.getAttribute("#joinForm", "data-dir");
	if (aimedMark !== "unknown") {
		fail(`the card aimed at an address in no hand is marked ${JSON.stringify(aimedMark)}`);
	}
	await tab.waitForFunction(
		() => (document.querySelector("#newRoom .rwhere-said")?.textContent ?? "").includes("elsewhere-tester"),
		undefined,
		{ timeout: 10_000 },
	).catch(async () => {
		fail(
			`naming another directory in the join card did not reach the rail's panel: ${
				JSON.stringify(await railWhere())
			}`,
		);
	});

	// And the destination is changed from here rather than by sending the reader
	// to the card to change it. The line opens the directories this tab holds —
	// the same rows, in the same box, that the card's own directory mark opens —
	// and picking one writes the card's locator, which is what makes the two
	// agree without either copying the other.
	//
	// A pick is an edit and files no act, so every other answer stands. Filing
	// one would supersede the act the reader is answering and take the room name
	// in this very field with it.
	await tab.click("#newRoomElsewhere");
	await tab.waitForSelector(".where-picks [role=menuitemradio]", { timeout: 5_000 })
		.catch(() => fail("the rail's new-room line did not offer the directories this tab holds"));

	// An address this tab does not hold has nowhere in the rail to be typed, so
	// that row hands over the field where it can be, leaving everything answered
	// so far where it is — the panel included, because handing over a field is
	// the plainest case of one half acting on the other.
	await tab.click('.where-picks [role=menuitem]:has-text("Another address")');
	if (await tab.evaluate(() => document.activeElement?.id ?? "") !== "locator") {
		fail("the way to an address the tab does not hold did not hand the reader the field that names one");
	}
	if (!await railShowing()) fail("handing over the card's field put the rail's panel away");
	const stillAimed = await tab.inputValue("#locator");
	if (stillAimed !== "ocapn://elsewhere-tester.tcp") {
		fail(`reaching for the card from the rail dropped the address it was aimed at: ${JSON.stringify(stillAimed)}`);
	}
	if (await tab.inputValue("#room") !== "half") {
		fail("reaching for the card from the rail dropped the room name typed into both");
	}

	// Back to this page's own directory, picked in the rail, which is the
	// direction that had no way of being taken before, so the join below
	// reaches the room server this page came from.
	await tab.click("#newRoomElsewhere");
	await tab.click('.where-picks [role=menuitemradio]:has-text("this directory")');
	await tab.waitForFunction(
		() => (document.getElementById("locator") as HTMLInputElement | null)?.value === "",
		undefined,
		{ timeout: 5_000 },
	).catch(async () =>
		fail(
			`picking a directory in the rail did not reach the join card's field; it holds ${
				JSON.stringify(await tab.inputValue("#locator"))
			}`,
		)
	);
	if (await tab.inputValue("#room") !== "half") {
		fail("picking a directory in the rail dropped the room name typed into both");
	}
	const backHome = await railWhere();
	if (!backHome.includes("this directory")) {
		fail(`the rail's panel did not follow the directory picked in it: ${JSON.stringify(backHome)}`);
	}

	// The card's own directory mark opens the same rows, that last one
	// included. Two menus offering the same choice offer the same list, and on
	// the card the row is the short way round: the field it hands over is the
	// one the menu hangs from.
	await tab.click("#joinLocator");
	await tab.waitForSelector('.locator-picks [role=menuitem]:has-text("Another address")', { timeout: 5_000 })
		.catch(() => fail("the join card's own directory menu does not offer the way to an address not held"));
	await tab.click('.locator-picks [role=menuitem]:has-text("Another address")');
	if (await tab.evaluate(() => document.activeElement?.id ?? "") !== "locator") {
		fail("the join card's own way to another address did not hand over its field");
	}
}
