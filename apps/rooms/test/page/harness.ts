// What every phase of the page proof needs: how to fail with a sentence, how to
// find a free port, wait for the server, and measure the contrast of ink
// actually drawn on a bubble.
//
// The proof is one conversation driven in order, so these are the only things
// shared across its phases. Everything else a phase needs, it is handed.
import type { Page } from "playwright";
export const WEB = new URL("../../web/serve.ts", import.meta.url).pathname;
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

/** Lowest ink contrast for a translucent descendant surface over either end of
 * its containing bubble's gradient. This checks the composite a person sees,
 * not the declarations in isolation. */
export async function bubbleInkContrast(
	page: Page,
	selector: string,
	surfaceSelector: string = selector,
): Promise<number | null> {
	await page.hover(selector);
	return page.evaluate(({ selector, surfaceSelector }) => {
		type Rgba = [number, number, number, number];
		const colors = (value: string): Rgba[] =>
			[...value.matchAll(/rgba?\(([^)]+)\)/g)].map((match) => {
				const parts = match[1].split(/[ ,/]+/).filter(Boolean).map(Number);
				return [parts[0], parts[1], parts[2], parts[3] ?? 1];
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
		if (!(target instanceof HTMLElement) || !(surface instanceof HTMLElement) || !(bubble instanceof HTMLElement)) {
			return null;
		}
		const ink = colors(getComputedStyle(target).color)[0];
		const wash = colors(getComputedStyle(surface).backgroundColor)[0];
		const stops = colors(getComputedStyle(bubble).backgroundImage);
		if (!ink || !wash || stops.length < 2) return null;
		return Math.min(...stops.map((stop) => contrast(ink, over(wash, stop))));
	}, { selector, surfaceSelector });
}

export { freePort, waitForHttp } from "../support/rooms_server.ts";
