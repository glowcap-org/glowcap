// What every phase of a page proof needs: how to fail with a sentence, where
// the executables are, a free port, waiting for the server, and the verbs for
// driving the page itself: saying a line, opening a direct message, waiting for
// a bubble, leaving, pressing through the join card, and reading the contrast
// of ink actually drawn on a bubble.
//
// A proof is one conversation driven in order, so these are the only things
// shared across its phases. Everything else a phase needs, it is handed.
import type { Locator, Page } from "playwright";

import { fail } from "../support/fail.ts";

export { fail };
export { ROOT, SERVER, WEB } from "../support/paths.ts";
export { freePort } from "../support/ports.ts";
export { until } from "../support/wait.ts";
export { waitForHttp } from "../support/rooms_server.ts";

/** How readable `selector` is over the gradient bubble behind it, or why that
 * could not be worked out.
 *
 * The answer is the lowest ink contrast a translucent descendant surface
 * reaches over either end of its containing bubble's gradient, so it is the
 * composite a person actually sees rather than the declarations in isolation. */
export async function bubbleInkContrast(
	page: Page,
	selector: string,
	surfaceSelector: string = selector,
): Promise<{ ratio: number } | { why: string }> {
	await page.hover(selector);
	return page.evaluate(({ selector, surfaceSelector }) => {
		type Rgba = [number, number, number, number];
		// Two syntaxes, because a computed color comes back in whatever shape the
		// token was written in. A `color-mix()` carrying transparency computes to
		// `color(srgb r g b / a)`, whose channels run 0 to 1 rather than 0 to 255,
		// and a reader that knew only `rgb()` found nothing in it. That is how a
		// contrast check came to report the note on a changed line as having no
		// color, on a page whose contrast was perfectly fine. `test/ink_contrast.ts`
		// met the same syntax from the other side and carries the longer account.
		const colors = (value: string): Rgba[] =>
			[...value.matchAll(/rgba?\(([^)]+)\)|color\(srgb\s+([^)]+)\)/g)].map((match) => {
				const srgb = match[2] !== undefined;
				const parts = (srgb ? match[2] : match[1]).split(/[ ,/]+/).filter(Boolean).map(Number);
				const scale = srgb ? 255 : 1;
				return [parts[0] * scale, parts[1] * scale, parts[2] * scale, parts[3] ?? 1];
			});
		const relative = ([r, g, b]: Rgba): number => {
			const channel = (n: number) => {
				const s = n / 255;
				return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
			};
			return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
		};
		const contrast = (a: Rgba, b: Rgba): number => {
			const [bright, dark] = [relative(a), relative(b)].sort((x, y) => y - x);
			return (bright + 0.05) / (dark + 0.05);
		};
		const over = (front: Rgba, back: Rgba): Rgba => [
			front[0] * front[3] + back[0] * (1 - front[3]),
			front[1] * front[3] + back[1] * (1 - front[3]),
			front[2] * front[3] + back[2] * (1 - front[3]),
			1,
		];

		const target = document.querySelector(selector);
		const surface = target?.closest(surfaceSelector);
		const bubble = target?.closest(".bubble");
		// Unmeasurable is reported rather than returned as a bare nothing. There
		// are several ways to arrive at it and they mean different things (a
		// note that never rendered, a bubble that is not painted as a gradient
		// yet), and a caller told only "null" has to guess which, at the moment
		// when the run that could have answered is already over.
		if (!(target instanceof HTMLElement)) return { why: `no element matched ${selector}` };
		if (!(surface instanceof HTMLElement)) return { why: `${selector} sits in no ${surfaceSelector}` };
		if (!(bubble instanceof HTMLElement)) return { why: `${selector} sits in no .bubble` };
		const ink = colors(getComputedStyle(target).color)[0];
		const wash = colors(getComputedStyle(surface).backgroundColor)[0];
		const painted = getComputedStyle(bubble).backgroundImage;
		const stops = colors(painted);
		if (!ink) return { why: `${selector} has no color` };
		if (!wash) return { why: `${surfaceSelector} has no background color` };
		if (stops.length < 2) return { why: `the bubble is painted ${JSON.stringify(painted)}, not as a gradient` };
		return { ratio: Math.min(...stops.map((stop) => contrast(ink, over(wash, stop)))) };
	}, { selector, surfaceSelector });
}

/** Fill a field of the join card and wait until it holds what was filled.
 *
 * These fields are controlled: the driver writes the element's value and
 * dispatches an input event, and the page answers by putting the value it holds
 * back. A render landing between those two (a settling join, a directory
 * arriving) restores the old text under the write, and the event that follows
 * carries the restored value rather than the intended one. Nobody typing sees
 * this, because a keystroke is one event with a render either side of it; a
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

/** Press the direct-message control beside `peer` in the member list and wait
 * until the composer is live again. The control is there only once `peer` is
 * both in the roster and advertised as reachable for direct messages. */
export async function openDmTo(tab: Page, peer: string): Promise<void> {
	const button = tab.locator(`#members li:has-text("${peer}") button.dm-btn`);
	await button.waitFor({ state: "visible", timeout: 60_000 });
	await button.click();
	await tab.waitForSelector("#line:not([disabled])", { timeout: 10_000 });
}

/** Wait for a bubble containing `text` to render in `tab`; on timeout, dump the
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
 * conversation's card; this confirms. */
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
 * field is there to be typed into; the caller presses Join itself when this
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
			if (button.dataset.busy === "true") return false;
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
	await tab.click("#roomAbout");
	await tab.waitForSelector("#dircardTitle", { timeout: 10_000 })
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

/** Settings names the directory; the button opens that conversation, and the
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
