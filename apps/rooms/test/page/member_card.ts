// Who a person is, asked from both doors that ask it.
//
// The roster row and the rail's foot open one card about the same person. A
// roster names the reader by that directory's grant while the foot uses the
// page's primary grant, so those titles may differ. Identity, the complete name
// list, and page-wide presence may not.
//
// It runs last and leaves nothing open, because the page test is one long
// conversation and a card left standing would be the next scene's problem.

import type { Page } from "playwright";
import { namedRoomRow } from "../support/conversation_row.ts";
import { fail } from "./harness.ts";

/** What the pip on the card's chip is drawing, and what the row under it says.
 * The card has one branch for both, so a reader who glances at the shape and a
 * reader who reads the line have to come away with the same fact. */
const AGREES: Record<string, string> = {
	online: "Here now",
	away: "Away: ",
	offline: "Offline",
};

/** Hold the pip and the row to one answer. Worth stating as its own check
 * because it is the one an idle page cannot exercise: a reader who is here has a
 * pip and a line that agree by accident, so this is asked again once somebody has
 * actually stepped away, where the two could differ and once did. */
function agrees(card: { pip: string; here: string }, when: string): void {
	const expected = AGREES[card.pip];
	if (expected === undefined || !card.here.startsWith(expected)) {
		fail(
			`the pip and the presence row disagree about one person ${when}: ` +
				JSON.stringify({ pip: card.pip, here: card.here }),
		);
	}
}

async function readCard(tab: Page) {
	return await tab.evaluate(() => {
		const chip = document.querySelector("#membercardTitle .avatar-presence");
		const pip = chip === null ? "" : [...chip.classList].find((c) => c !== "avatar-presence") ?? "";
		const text = (sel: string) => document.querySelector(sel)?.textContent?.trim() ?? "";
		return {
			pip,
			title: text(".membercard-name"),
			is: text("#membercardIs"),
			names: text("#membercardName"),
			here: text("#membercardHere"),
			reach: text("#membercardReach"),
			doors: [...document.querySelectorAll("#membercardName .membercard-door")].map((el) =>
				el.textContent?.trim() ?? ""
			),
		};
	});
}

export async function run(tab: Page): Promise<void> {
	// A roster only exists in a room, and the scene before this one leaves a
	// direct conversation open, so this puts a room back on screen first, the
	// home-directory room, by name, never the rail's first row. After the
	// directories scene the reader holds a name per directory, and the card
	// titles the name in the door's context; only this directory's room has the
	// reader under the name the foot answers with, so only here can the two
	// doors be compared at all.
	await namedRoomRow(tab, "lobby").locator(".room-open").click();
	await tab.waitForSelector("#members .member-face", { timeout: 30_000 })
		.catch(() => fail("no roster to open a person from after returning to a room"));

	// The reader is first in the roster, by `rosterOf`. Both doors can answer
	// their own row, giving the comparison a shared case.
	const own = tab.locator("#members .member-face").first();
	const rowName = (await own.locator(".name").textContent() ?? "").replace(" (you)", "").trim();
	await own.click();
	await tab.waitForSelector("#membercardTitle", { timeout: 10_000 })
		.catch(() => fail("a roster row did not open the person card"));
	const fromRoster = await readCard(tab);

	if (fromRoster.title !== rowName) {
		fail(`the card names somebody the row did not: ${JSON.stringify({ row: rowName, card: fromRoster.title })}`);
	}
	if (fromRoster.is !== "You") {
		fail(`the reader's own roster row opened a card that does not say so: ${JSON.stringify(fromRoster.is)}`);
	}
	agrees(fromRoster, "before anyone has stepped away");
	// A name is one directory's grant, and the card says which by making it the
	// way to that directory rather than by printing its name flat.
	if (fromRoster.doors.length === 0) {
		fail(`the reader's card lists no directory behind their names: ${JSON.stringify(fromRoster.names)}`);
	}

	// The directory behind a name is a door into that directory's conversation,
	// not a card stacked over this one.
	await tab.click("#membercardDirectory");
	await tab.waitForSelector("#membercardTitle", { state: "detached", timeout: 10_000 })
		.catch(() => fail("opening the directory left the person card standing"));
	await tab.waitForFunction(
		() => location.pathname === "/directory",
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("the directory behind a name did not open that directory"));

	// The other door. The foot is about the reader wherever they are, so it opens
	// the same card with no room (and therefore no directory-scoped alias) in the
	// question.
	await tab.click("#standingBtn");
	await tab.locator(".standing-actions [role=menuitem]", { hasText: "About you" }).first().click();
	await tab.waitForSelector("#membercardTitle", { timeout: 10_000 })
		.catch(() => fail("the rail's foot did not open the reader's own card"));
	const fromFoot = await readCard(tab);

	for (const card of [fromRoster, fromFoot]) {
		if (!card.names.includes(`${card.title} on`)) {
			fail(`the reader's card title is not one of their directory grants: ${JSON.stringify(card)}`);
		}
	}
	for (
		const [what, mine, theirs] of [
			["what it says they are", fromRoster.is, fromFoot.is],
			["the names they hold", fromRoster.names, fromFoot.names],
			["where they are", fromRoster.here, fromFoot.here],
		] as const
	) {
		if (mine !== theirs) {
			fail(
				`the two doors onto one person card disagree about ${what}: ` +
					JSON.stringify({ fromRoster: mine, fromFoot: theirs }),
			);
		}
	}

	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#membercardTitle", { state: "detached", timeout: 10_000 })
		.catch(() => fail("the person card opened from the foot did not close"));

	await namedRoomRow(tab, "lobby").locator(".room-open").click();
	await tab.waitForSelector("#line:not([disabled])", { timeout: 10_000 })
		.catch(() => fail("returning from the directory did not put a room back"));

	// The same two questions once the reader is somewhere else. Before this the pip
	// and the row agreed on "here", which they would do even if nothing joined
	// them, so this is the leg that can actually tell them apart. Set, read, and
	// put back: the page test is one conversation and this scene borrows its
	// reader rather than changing them.
	await tab.fill("#line", "/away making tea");
	await tab.press("#line", "Enter");
	await tab.locator("#standingBtn #status").filter({ hasText: /^making tea$/ }).waitFor({ timeout: 30_000 });
	await tab.locator("#members .member-face").first().click();
	await tab.waitForSelector("#membercardTitle", { timeout: 10_000 });
	const stepped = await readCard(tab);
	if (stepped.pip !== "away") {
		fail(`a reader who stepped away wears no away pip on their own card: ${JSON.stringify(stepped)}`);
	}
	if (stepped.here !== "Away: making tea") {
		fail(`the card does not carry the reason a reader gave for stepping away: ${JSON.stringify(stepped.here)}`);
	}
	agrees(stepped, "once the reader has stepped away");
	await tab.keyboard.press("Escape");
	await tab.waitForSelector("#membercardTitle", { state: "detached", timeout: 10_000 });
	await tab.fill("#line", "/away");
	await tab.press("#line", "Enter");
}
