// A field whose whole value is a name finishes it from the page's own list,
// in a card as in the rail, and only while the field has the caret.

import type { Page } from "playwright";
import { namedRoomRow } from "../support/conversation_row.ts";
import { fail } from "../support/fail.ts";

export async function run(tab: Page): Promise<void> {
	// ── Handing history to a member ─────────────────────────────────────
	// The names worth finishing are the members who can take a direct message.
	// The roster marks each of them with a direct-line button.
	const member = await tab.evaluate(() =>
		[...document.querySelectorAll("#members li")]
			.find((row) => row.querySelector(".dm-btn") !== null)?.querySelector(".name")?.textContent?.trim() ?? ""
	);
	// The scene types part of the name, so a one-letter name leaves nothing to finish.
	if (member.length < 2) {
		fail(`the scene needs a member with a name to finish who can take a direct message: ${JSON.stringify(member)}`);
	}
	const room = (await tab.textContent("#roomList li.here .rname-text"))?.trim() ?? "";
	await tab.click("#roomAbout");
	await tab.click("#convcardArchiveOpen");
	await tab.waitForSelector("#convcardArchivePeer", { timeout: 10_000 })
		.catch(() => fail("the archive card did not ask who to share with"));
	// A list the browser draws is a second look for the one thing this page
	// already does, and it opens with nothing typed.
	const drawnByBrowser = await tab.evaluate(() => {
		const field = document.getElementById("convcardArchivePeer");
		return field instanceof HTMLInputElement && field.list !== null;
	});
	if (drawnByBrowser) fail("the archive card's member field hands its names to the browser's own list");
	await tab.click("#convcardArchivePeer");
	if (await tab.locator("#convcardArchivePeerOffers").count() !== 0) {
		fail("the archive card offered names before anything was typed");
	}
	await tab.type("#convcardArchivePeer", member.slice(0, 1));
	await tab.waitForSelector("#convcardArchivePeerOffers [role=option]", { timeout: 10_000 })
		.catch(() => fail(`typing the start of ${JSON.stringify(member)} in the archive card offered nobody`));
	// Under the field and as wide as it, in the card's own layer.
	const placed = await tab.evaluate(() => {
		const field = document.getElementById("convcardArchivePeer")?.getBoundingClientRect();
		const list = document.getElementById("convcardArchivePeerOffers")?.getBoundingClientRect();
		if (field == null || list == null) return null;
		return {
			under: list.top >= field.bottom,
			apart: Math.abs(list.left - field.left) + Math.abs(list.right - field.right),
		};
	});
	if (placed == null || !placed.under || placed.apart > 1) {
		fail(`the archive card's list of names does not hang under its field: ${JSON.stringify(placed)}`);
	}
	await tab.fill("#convcardArchivePeer", member.slice(0, -1));
	await tab.waitForSelector("#convcardArchivePeerOffers [role=option]", { timeout: 10_000 })
		.catch(() => fail(`typing most of ${JSON.stringify(member)} in the archive card offered nobody`));
	await tab.press("#convcardArchivePeer", "ArrowDown");
	await tab.press("#convcardArchivePeer", "Enter");
	const taken = await tab.inputValue("#convcardArchivePeer");
	if (taken !== member) fail(`taking the offered member left the field as ${JSON.stringify(taken)}`);
	if (await tab.locator(".archive-history-modal").count() !== 1) {
		fail("taking an offered member's name put the archive card away");
	}
	// The caret leaving takes the list down with it.
	await tab.fill("#convcardArchivePeer", member.slice(0, 1));
	await tab.waitForSelector("#convcardArchivePeerOffers [role=option]", { timeout: 10_000 });
	await tab.press("#convcardArchivePeer", "Tab");
	await tab.waitForSelector("#convcardArchivePeerOffers", { state: "detached", timeout: 5_000 })
		.catch(() => fail("the archive card's list of names stayed up after the caret left its field"));
	await tab.locator(".archive-history-modal").getByRole("button", { name: "Close" }).click();
	await tab.waitForSelector(".archive-history-modal", { state: "detached", timeout: 10_000 });
	await tab.click("#convcardClose");

	// ── Naming a room on the join card ──────────────────────────────────
	// The same list, and the same rule: over the name field it would cover.
	if (room.length < 2) fail(`the scene needs a room open to name again and found ${JSON.stringify(room)}`);
	await tab.click(".wordmark-link");
	await tab.waitForSelector("#joinBtn", { timeout: 10_000 });
	await tab.fill("#room", room.slice(0, -1));
	await tab.waitForSelector("#roomOffers [role=option]", { timeout: 10_000 })
		.catch(() => fail(`typing most of ${JSON.stringify(room)} on the join card offered no room`));
	await tab.focus("#nick");
	await tab.waitForSelector("#roomOffers", { state: "detached", timeout: 5_000 })
		.catch(() => fail("the join card's list of rooms stayed up over the name field after the caret left"));
	await tab.fill("#room", "");
	await namedRoomRow(tab, room).locator(".room-open").click();
	await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 })
		.catch(() => fail("the room did not come back after naming it on the join card"));
}
