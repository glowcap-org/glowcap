#!/usr/bin/env -S deno run -A
/**
 * playwright-gutter-labels-probe.ts: the row-label column down the left
 * of the timeline, at the widths a reader can drag it to.
 *
 * Two things to look at in the shots. Every row is called what its own
 * span is called, so a session row reads as the pair it joins rather than
 * as sixty-four characters of Session ID. And no label crosses the
 * divider into the plot, at any width the drag handle allows, including
 * the narrowest, which is where a name runs out of room first.
 *
 * The arithmetic behind that second one is held by
 * `src/ui/Timeline/gutter-paint.test.ts`. These are the shots that show
 * what it produces, one close crop of the column per case.
 *
 * Usage: playwright-gutter-labels-probe.ts [out-dir] [url]
 *
 * Setup: a dev server on the url below.
 */
import { chromium } from "playwright";

const outDir = Deno.args[0] ?? "/tmp/ocv-gutter-labels";
const url = Deno.args[1] ?? "http://127.0.0.1:5173/";
await Deno.mkdir(outDir, { recursive: true });

/** The narrowest the drag handle allows, a middle width, and the widest. */
const WIDTHS = [104, 170, 320];

/** Scenarios with the shapes that make this hard: a three-vat handoff
 *  with an end nobody attributed, and two whose peers are keyed, so a
 *  peer's id is sixty-four characters of hex. */
const SCENARIOS = [
	"three-vat-handoff-mixed",
	"04-skip-the-roundtrip",
	"08-enliven-a-sturdyref",
];

const browser = await chromium.launch({
	headless: true,
	args: ["--no-sandbox", "--disable-gpu"],
});

for (const theme of ["dark", "light"] as const) {
	for (const scenario of SCENARIOS) {
		for (const width of WIDTHS) {
			const ctx = await browser.newContext({
				viewport: { width: 1600, height: 1000 },
				deviceScaleFactor: 2,
				colorScheme: theme,
			});
			const page = await ctx.newPage();
			page.on("pageerror", (e) => console.log("[pageerror]", e.message));
			// Seed the persisted view rather than driving chevrons: the three
			// categories drilled down, at the gutter width under test.
			await page.addInitScript((gutterWidth: number) => {
				try {
					localStorage.removeItem("ocapnviz:app-state");
					localStorage.setItem(
						"ocapnviz:timeline-view",
						JSON.stringify({
							expandedLanes: ["ruler", "peers", "sessions", "messages"],
							expandedCategories: ["peers", "sessions", "messages"],
							gutterWidth,
						}),
					);
				} catch {
					// first run has nothing to clear
				}
			}, width);
			await page.goto(url, { waitUntil: "networkidle" });
			await page.waitForSelector("canvas#ocv-pixi");
			await page.evaluate((t) => {
				document.documentElement.dataset.theme = t;
			}, theme);
			await page.waitForTimeout(400);
			await page.selectOption("select.ocv-select", scenario);
			await page.waitForTimeout(700);

			const clip = await page.evaluate(() => {
				const root = document.querySelector(".ocv-app-root");
				const panel = root?.lastElementChild;
				const r = panel?.getBoundingClientRect();
				return r
					? {
						x: Math.floor(r.left),
						y: Math.floor(r.top),
						width: Math.floor(r.width),
						height: Math.floor(r.height),
					}
					: { x: 0, y: 700, width: 1600, height: 300 };
			});
			const name = `${theme}-${scenario}-g${width}`;
			await page.screenshot({ path: `${outDir}/${name}.png`, clip });
			// A closer crop, the column plus the first stretch of plot, so the
			// divider and the text beside it read at a glance.
			await page.screenshot({
				path: `${outDir}/${name}-column.png`,
				clip: { ...clip, width: Math.min(clip.width, width + 200) },
			});
			const rows = await page.evaluate(() => {
				const g = globalThis as unknown as {
					__ocv?: { timelineView?: { gutterWidth?: number } };
				};
				return g.__ocv?.timelineView?.gutterWidth;
			});
			console.log(`${name}: view gutterWidth=${rows}`);
			await ctx.close();
		}
	}
}

// The same two extremes reached the way a reader reaches them, by
// dragging the seam past its stops, so the labels are seen re-fitting
// under a live drag rather than only after a reload.
{
	const ctx = await browser.newContext({
		viewport: { width: 1600, height: 1000 },
		deviceScaleFactor: 2,
		colorScheme: "dark",
	});
	const page = await ctx.newPage();
	page.on("pageerror", (e) => console.log("[pageerror]", e.message));
	await page.addInitScript(() => {
		try {
			localStorage.removeItem("ocapnviz:app-state");
			localStorage.setItem(
				"ocapnviz:timeline-view",
				JSON.stringify({
					expandedLanes: ["ruler", "peers", "sessions", "messages"],
					expandedCategories: ["peers", "sessions", "messages"],
					gutterWidth: 170,
				}),
			);
		} catch {
			// first run has nothing to clear
		}
	});
	await page.goto(url, { waitUntil: "networkidle" });
	await page.waitForSelector("canvas#ocv-pixi");
	await page.waitForTimeout(400);
	await page.selectOption("select.ocv-select", "three-vat-handoff-mixed");
	await page.waitForTimeout(700);

	const pane = await page.evaluate(() => {
		const r = document.querySelector(".ocv-app-root")?.lastElementChild
			?.getBoundingClientRect();
		return r
			? {
				x: Math.floor(r.left),
				y: Math.floor(r.top),
				width: Math.floor(r.width),
				height: Math.floor(r.height),
			}
			: { x: 0, y: 700, width: 1600, height: 300 };
	});
	const seamY = pane.y + pane.height / 2;
	const gutterNow = async () =>
		await page.evaluate(() => {
			const g = globalThis as unknown as {
				__ocv?: { timelineView?: { gutterWidth?: number } };
			};
			return g.__ocv?.timelineView?.gutterWidth ?? 104;
		});

	for (const [label, dx] of [["narrowest", -400], ["widest", 400]] as const) {
		const from = pane.x + await gutterNow();
		await page.mouse.move(from, seamY);
		await page.mouse.down({ button: "left" });
		for (let i = 1; i <= 20; i++) {
			await page.mouse.move(from + (dx * i) / 20, seamY);
			await page.waitForTimeout(8);
		}
		await page.mouse.up({ button: "left" });
		await page.waitForTimeout(200);
		const width = await gutterNow();
		await page.screenshot({
			path: `${outDir}/drag-${label}.png`,
			clip: { ...pane, width: Math.min(pane.width, width + 200) },
		});
		console.log(`drag-${label}: gutterWidth=${width}`);
	}
	await ctx.close();
}

await browser.close();
console.log(`\nshots in ${outDir}`);
