/// <reference lib="dom" />
/**
 * How the Rooms capture scripts write an image, so every product capture on
 * the site is framed, themed, and encoded the same way. `capture-rooms.ts`
 * and `capture-rooms-directories.ts` are the callers.
 */
import type { Page } from "playwright";

/** Browser context options every capture shares. Reduced motion stops the
 * mycelium's light from running at random, so a capture shows the same page
 * each time. */
export const still = { reducedMotion: "reduce" } as const;

/** Where a capture script writes its pictures: `--out=<dir>`, or `site/assets`
 * where Zine reads them. `zig build site-captures` passes the flag. */
export const outDirArg = (): string =>
	Deno.args.find((arg) => arg.startsWith("--out="))?.slice("--out=".length) ?? "site/assets";

/** Wait until a web peer this script started answers its page's locator on
 * loopback port `http`. A peer that never answers inside a minute fails the
 * capture with `what` named. */
export async function awaitLocator(http: number, what: string): Promise<void> {
	for (let i = 0; i < 1200; i++) {
		try {
			const res = await fetch(`http://127.0.0.1:${http}/locator`);
			if (res.status === 200 && (await res.text()).trim().length > 0) return;
		} catch {
			// not up yet status-allow: pending state or quoted runtime label
		}
		await new Promise((settle) => setTimeout(settle, 50));
	}
	throw new Error(`${what} never answered with a locator`);
}

/** How much of the mycelium a capture keeps, by theme. Moving, the threads
 * read as depth. Held still at full strength, they read as scratches over the
 * UI. Dark threads on paper fade sooner than light ones on the night ground. */
const GROUND = { dark: 0.18, light: 0.55 } as const;

/** Put the page in one theme, with the mycelium faint, and let its animations
 * finish. */
export async function settle(page: Page, theme: "dark" | "light" = "dark"): Promise<void> {
	await page.evaluate(([t, ground]) => {
		document.documentElement.setAttribute("data-theme", t);
		// A filter, because the page's own fade holds the canvas opacity.
		for (const canvas of document.querySelectorAll<HTMLElement>("canvas[class^=mycelium]")) {
			canvas.style.filter = `opacity(${ground})`;
		}
	}, [theme, GROUND[theme]] as const);
	// An endless animation never finishes, so only the ones that end are
	// waited for.
	await page.evaluate(() =>
		Promise.all(
			document.getAnimations()
				.filter((animation) => animation.effect?.getComputedTiming().iterations !== Infinity)
				.map((animation) => animation.finished.catch(() => {})),
		)
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
	// The "New messages" rule retires a moment after arrival, and a capture
	// that beats it shows a rule its other face does not.
	await page.waitForFunction(() => document.querySelector(".divider.unread") === null, undefined, {
		timeout: 10_000,
	});
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
 * to its end until it stays there, since the page can still be laying out the
 * last rows, and let the pill retire before a capture.
 */
export async function pinToLatest(page: Page): Promise<void> {
	const atEnd = () => {
		const log = document.querySelector("#log");
		if (log === null) return true;
		const end = log.scrollHeight - log.clientHeight;
		const there = log.scrollTop >= end - 2;
		log.scrollTo(0, log.scrollHeight);
		return there;
	};
	for (let settled = 0; settled < 2;) {
		await page.waitForFunction(atEnd, undefined, { polling: 100, timeout: 10_000 });
		await page.waitForTimeout(300);
		settled = (await page.evaluate(atEnd)) ? settled + 1 : 0;
	}
}
