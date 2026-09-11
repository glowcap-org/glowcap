// What every phase of the page proof needs: how to fail with a sentence, how to
// find a free port, wait for the server, and measure the contrast of ink
// actually drawn on a bubble.
//
// The proof is one conversation driven in order, so these are the only things
// shared across its phases. Everything else a phase needs, it is handed.
import type { Locator, Page } from "playwright";
import { WEB } from "../support/web_binary.ts";
export { WEB };
export const ROOT = new URL("../../../../", import.meta.url).pathname;

// Throw rather than exit: `Deno.exit` skips the `finally` below, which is what
// kills the room server this test spawned. A failure used to leave that child
// alive holding the inherited stdout pipe, so whoever was reading this test's
// output — `zig build`, a CI runner — waited on an end-of-file that never came.
// A failing check has to fail, not hang.
export function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	throw new Error(message);
}

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
		// Two syntaxes, because a computed colour comes back in whatever shape the
		// token was written in. A `color-mix()` carrying transparency computes to
		// `color(srgb r g b / a)`, whose channels run 0 to 1 rather than 0 to 255,
		// and a reader that knew only `rgb()` found nothing in it — which is how a
		// contrast check came to report the note on a changed line as having no
		// colour, on a page whose contrast was perfectly fine. `test/ink_contrast.ts`
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
		// are several ways to arrive at it and they mean different things — a
		// note that never rendered, a bubble that is not painted as a gradient
		// yet — and a caller told only "null" has to guess which, at the moment
		// when the run that could have answered is already over.
		if (!(target instanceof HTMLElement)) return { why: `no element matched ${selector}` };
		if (!(surface instanceof HTMLElement)) return { why: `${selector} sits in no ${surfaceSelector}` };
		if (!(bubble instanceof HTMLElement)) return { why: `${selector} sits in no .bubble` };
		const ink = colors(getComputedStyle(target).color)[0];
		const wash = colors(getComputedStyle(surface).backgroundColor)[0];
		const painted = getComputedStyle(bubble).backgroundImage;
		const stops = colors(painted);
		if (!ink) return { why: `${selector} has no colour` };
		if (!wash) return { why: `${surfaceSelector} has no background colour` };
		if (stops.length < 2) return { why: `the bubble is painted ${JSON.stringify(painted)}, not as a gradient` };
		return { ratio: Math.min(...stops.map((stop) => contrast(ink, over(wash, stop)))) };
	}, { selector, surfaceSelector });
}

/** Fill a field of the join card and wait until it holds what was filled.
 *
 * These fields are controlled: the driver writes the element's value and
 * dispatches an input event, and the page answers by putting the value it holds
 * back. A render landing between those two — a settling join, a directory
 * arriving — restores the old text under the write, and the event that follows
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

export { freePort, waitForHttp } from "../support/rooms_server.ts";
export { confirmTitleLeave, reachDirectoryOnCard } from "../support/page.ts";

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
