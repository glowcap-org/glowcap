// What every phase of a page proof needs: how to fail with a sentence, where
// the executables are, a free port, waiting for the server, and the verbs for
// driving the page itself: saying a line, opening a direct message, waiting for
// a bubble, leaving, pressing through the join card, and reading the contrast
// of ink actually drawn on a bubble.
//
// A proof is one conversation driven in order, so these are the only things
// shared across its phases. Everything else a phase needs, it is handed.
import type { Locator, Page } from "playwright";
import { inkContrast } from "../ink_contrast.ts";

import { fail } from "../support/fail.ts";

export { fail };
export { ROOT, SERVER, WEB } from "../support/paths.ts";
export { freePort } from "../support/ports.ts";
export { until } from "../support/wait.ts";
export { waitForHttp } from "../support/rooms_server.ts";

/** Measure hovered ink against every painted ancestor, including opaque file
 * chips inside a gradient bubble. The shared contrast owner handles browser
 * colour syntax and alpha. No descendant skips its actual ground. */
export async function bubbleInkContrast(
	page: Page,
	selector: string,
): Promise<{ ratio: number } | { why: string }> {
	await page.hover(selector);
	return await inkContrast(page, selector) ?? { why: `${selector} has no measurable painted ground` };
}

/** Fill a field of the join card and wait until it holds what was filled.
 *
 * These fields are controlled: the driver writes the element's value and
 * dispatches an input event, and the page answers by putting the value it holds
 * back. A render landing between those two (a settling join, a directory
 * arriving) restores the old text under the write, and the event that follows status-allow: replacement state identity
 * carries the restored value rather than the intended one. Nobody typing sees
 * this, because a keystroke is one event with a render either side of it. A
 * driver filling forty characters at once is the only thing fast enough.
 *
 * So a fill is not done when `fill` returns, it is done when the field agrees.
 * A write the page put its own value back over is gone, and no amount of
 * waiting brings it back, so the recovery is to write it again: the render
 * that landed on top has landed, and the next attempt has the field to itself.
 * Bounded, because a field that will not take a value after several tries is a
 * defect rather than a race, and it should say so instead of spinning. It says
 * it where it happened, too: this was first met as a join that timed out sixty
 * seconds later, twice, reported against a card still holding the previous
 * address and nobody able to reproduce it.
 */
export async function fillSettled(tab: Page, selector: string, value: string): Promise<void> {
	const holds = ({ selector, value }: { selector: string; value: string }) =>
		(document.querySelector(selector) as HTMLInputElement | null)?.value === value;
	for (let attempt = 0; attempt < 5; attempt++) {
		await tab.fill(selector, value);
		const took = await tab
			.waitForFunction(holds, { selector, value }, { timeout: 2_000 })
			.then(() => true, () => false);
		if (took) return;
	}
	fail(`filling ${selector} with ${JSON.stringify(value)} did not take; the field kept what it had`);
}

/** Type `text` into the composer and send it. */
export async function say(tab: Page, text: string): Promise<void> {
	await tab.fill("#line", text);
	await tab.press("#line", "Enter");
}

/** A line's edit authority proves receipt settlement. Quiet progress does not. */
export async function waitForPostedLine(tab: Page, text: string): Promise<void> {
	const bubble = tab.locator(".row.mine .bubble").filter({ hasText: text });
	await bubble.hover();
	await bubble.getByLabel("More for this message", { exact: true }).click();
	await tab.getByRole("menuitem", { name: "Edit", exact: true }).waitFor();
	await tab.keyboard.press("Escape");
}

/** Press the direct-message control beside `peer` in the member list and wait
 * until that conversation is the selected rail row and its composer is live.
 * The title alone names the destination while the conversation is still being
 * opened, over the previous conversation's composer, so it proves nothing about
 * where the next line goes. The control is there only once `peer` is both in
 * the roster and advertised as reachable for direct messages. */
export async function openDmTo(tab: Page, peer: string): Promise<void> {
	const button = tab.locator(`#members li:has-text("${peer}") button.dm-btn`);
	await button.waitFor({ state: "visible", timeout: 60_000 });
	await button.click();
	await directOpened(tab, peer);
}

/** The direct line to `peer` is the open conversation and takes a message. A
 * press only starts the opening. The conversation the reader was in keeps its
 * own composer meanwhile, so an enabled composer alone proves nothing. */
export async function directOpened(tab: Page, peer: string, timeout = 30_000): Promise<void> {
	await tab.waitForFunction(
		(peer) =>
			[...document.querySelectorAll("li.here .dm-open .rname")].some((name) =>
				name.textContent?.trim() === peer
			) &&
			(document.getElementById("roomName")?.textContent ?? "").trim() === peer &&
			(document.getElementById("line") as HTMLTextAreaElement | null)?.disabled === false,
		peer,
		{ timeout },
	);
}

/** Wait for a bubble containing `text` to render in `tab`. On timeout, dump the
 * page's #log so the failure says what the page actually showed. */
export async function awaitBubble(tab: Page, text: string, who: string): Promise<void> {
	await tab.waitForFunction(
		(t) => [...document.querySelectorAll(".bubble")].some((b) => b.textContent?.includes(t)),
		text,
		{ timeout: 30_000 },
	).catch(async () => {
		const log = (await tab.textContent("#log").catch(() => "?")) ?? "?";
		console.error(`  [${who} #log] ${JSON.stringify(log)}`);
		fail(`${who} never rendered "${text}"`);
	});
}

/** End the conversation on screen with the title's mark. The mark asks in that
 * conversation's card. This confirms. */
export async function confirmTitleLeave(tab: Page): Promise<void> {
	await tab.click("#leaveBtn");
	const commit = tab.locator("#convcardLeave, #dircardLeave");
	await commit.waitFor({ state: "visible", timeout: 10_000 });
	await commit.click();
}

/** Press the join card's one act until it is offering the room question, or
 * the restored session has already entered the room this card asked for.
 *
 * The card asks for the directory first and the room after, so an address this
 * tab has not reached takes two presses: one that reaches it, and one that
 * joins. A directory already reached needs no first press, which is why this
 * looks at what the button says rather than counting. It returns once the room
 * field is there to be typed into. The caller presses Join itself when this
 * returns `question`. A card that already names the room finishes the whole
 * request on that one press: the directory is reached and the room entered
 * before the press is over, and the same happens when a reconnect restores an
 * existing membership. Callers that have already named the room pass it so
 * that exact outcome is what is accepted, and not an unrelated selection.
 *
 * Neither answer is known while the press is still running. The room field
 * draws the moment the directory is reached, ahead of the join the same press
 * goes on to make, so a reader who took that frame as the question pressed a
 * button that was busy and then gone. */
export async function reachDirectoryOnCard(
	tab: Page,
	expectedRoom?: string,
): Promise<"question" | "joined"> {
	const label = async () => ((await tab.textContent("#joinBtn")) ?? "").trim();
	if (await label() !== "Connect") return "question";
	await tab.click("#joinBtn");
	await tab.waitForFunction(
		(expectedRoom) => {
			const button = document.getElementById("joinBtn") as HTMLButtonElement | null;
			if (button === null) {
				return expectedRoom !== null &&
					(document.getElementById("roomName")?.textContent ?? "").trim() === expectedRoom &&
					(document.getElementById("line") as HTMLTextAreaElement | null)?.disabled === false;
			}
			// Progress is delayed; readiness follows the control.
			if (button.disabled) return false;
			const room = document.getElementById("room");
			if (room !== null && (room as HTMLInputElement).offsetParent !== null) return true;
			return expectedRoom !== null &&
				(document.getElementById("roomName")?.textContent ?? "").trim() === expectedRoom &&
				(document.getElementById("line") as HTMLTextAreaElement | null)?.disabled === false;
		},
		expectedRoom ?? null,
		{ timeout: 60_000 },
	).catch(async () =>
		fail(
			"connecting to the directory never offered the room question: " +
				JSON.stringify(
					await tab.evaluate(() => {
						const screen = document.getElementById("joinScreen");
						const room = document.getElementById("room") as HTMLInputElement | null;
						return {
							button: document.getElementById("joinBtn")?.textContent?.trim() ?? "",
							refused: document.getElementById("joinError")?.textContent?.trim() ?? "",
							path: location.pathname + location.search,
							appClass: document.getElementById("app")?.className ?? "",
							screenHidden: screen?.hidden ?? null,
							roomHidden: room?.closest<HTMLElement>("[hidden]")?.id ?? null,
							roomValue: room?.value ?? null,
							open: document.getElementById("roomName")?.textContent?.trim() ?? "",
						};
					}),
				),
		)
	);
	return await tab.locator("#room").isVisible() ? "question" : "joined";
}

/** The directory conversation's title opens the existing directory card. */
export async function openDirectoryCard(tab: Page): Promise<void> {
	// Exit transitions retain the previous card after close(). Its painted
	// title cannot prove that this press opened the selected directory's card.
	await tab.waitForSelector("#dircardTitle", { state: "detached", timeout: 10_000 });
	await tab.click("#roomAbout");
	await tab.waitForSelector('dialog[aria-labelledby="dircardTitle"]:modal:not([inert]) #dircardTitle', {
		timeout: 10_000,
	})
		.catch(() => fail("the directory conversation's title did not open its card"));
}

/** Pressing a rail caption selects that directory's conversation. */
export async function showDirectoryFromCaption(tab: Page, caption: Locator): Promise<void> {
	const said = (await caption.getAttribute("aria-label")) ?? "";
	await caption.click();
	await tab.waitForFunction(
		(said) => {
			if (location.pathname !== "/directory") return false;
			const name = document.getElementById("roomName")?.textContent ?? "";
			return name !== "" && said.includes(name);
		},
		said,
		{ timeout: 10_000 },
	).catch(() => fail(`clicking a directory caption did not open that directory's conversation: ${said}`));
}

/** Pressing a rail caption, then the title, opens the directory card. */
export async function openDirectoryCardFromCaption(tab: Page, caption: Locator): Promise<void> {
	await showDirectoryFromCaption(tab, caption);
	await openDirectoryCard(tab);
}

/** Settings names the directory. The button opens that conversation, and the
 * title chip opens the card. */
export async function openDirectoryCardFromSettings(tab: Page): Promise<void> {
	await tab.click("#settingsAboutDir");
	await tab.waitForSelector("#settingsTitle", { state: "hidden", timeout: 10_000 })
		.catch(() => fail("Settings stayed up instead of opening the directory"));
	await tab.waitForFunction(
		() => location.pathname === "/directory" && new URLSearchParams(location.search).get("dir") === null,
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("Settings did not open this directory"));
	await openDirectoryCard(tab);
}
