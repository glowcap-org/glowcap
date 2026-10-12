/// <reference lib="dom" />
/**
 * How the Rooms capture scripts write an image, so every product capture on
 * the site is framed, themed, and encoded the same way. `capture-rooms.ts`
 * and `capture-rooms-directories.ts` are the callers.
 */
import type { Page } from "playwright";

/** Put the page in one theme and let its animations finish. */
export async function settle(page: Page, theme: "dark" | "light" = "dark"): Promise<void> {
	await page.evaluate((t) => document.documentElement.setAttribute("data-theme", t), theme);
	await page.evaluate(() =>
		Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => {})))
	);
	// Presence pips and the composer's focus ring settle a frame after the last
	// animation; one short pause keeps a capture from catching them mid-move.
	await page.waitForTimeout(250);
}

/**
 * Write the viewport, or a clip around the union of the elements `within`
 * selects, with a margin of surrounding page so the crop still reads as a
 * window rather than a cut-out. Every capture is written twice under
 * `outDir`, as `<name>-dark.webp` and `<name>-light.webp`.
 */
export async function shot(page: Page, outDir: string, name: string, within?: string): Promise<void> {
	let clip: { x: number; y: number; width: number; height: number } | undefined;
	if (within) {
		clip = await page.evaluate((selector) => {
			const boxes = [...document.querySelectorAll(selector)].map((el) => el.getBoundingClientRect());
			const margin = 36;
			const left = Math.max(0, Math.min(...boxes.map((b) => b.left)) - margin);
			const top = Math.max(0, Math.min(...boxes.map((b) => b.top)) - margin);
			const viewport = document.documentElement;
			const right = Math.min(viewport.clientWidth, Math.max(...boxes.map((b) => b.right)) + margin);
			const bottom = Math.min(viewport.clientHeight, Math.max(...boxes.map((b) => b.bottom)) + margin);
			return { x: left, y: top, width: right - left, height: bottom - top };
		}, within);
	}
	// One capture per face. The site shows whichever matches its own theme.
	for (const theme of ["dark", "light"] as const) {
		await settle(page, theme);
		await page.screenshot({
			path: `${outDir}/${name}-${theme}.webp`,
			type: "webp",
			// Chromium's WebP encoder is lossless at 100. These captures mix fine
			// UI text with broad gradients, so lossy quantization is conspicuous.
			quality: 100,
			fullPage: false,
			clip,
		});
	}
	await settle(page, "dark");
}

/**
 * A rendered line is rich text: a mention becomes a chip and an emphasis
 * marker disappears, so the bubble is found by a plain run of words from the
 * line rather than by the whole line.
 */
export function plainRun(text: string): string {
	const runs = text.split(/@\S+|[*_`]/).map((run) => run.trim()).filter((run) => run.length > 12);
	if (runs.length === 0) throw new Error(`no plain run to wait for in ${JSON.stringify(text)}`);
	return runs.reduce((longest, run) => (run.length > longest.length ? run : longest));
}

/**
 * Resizing the window can leave the timeline scrolled short of its end, and
 * the page then offers a "latest messages" pill over the log. Scroll the log
 * to its end and let the pill retire before a capture.
 */
export async function pinToLatest(page: Page): Promise<void> {
	await page.evaluate(() => {
		const log = document.querySelector("#log");
		if (log) log.scrollTo(0, log.scrollHeight);
	});
	await page.waitForTimeout(400);
}
