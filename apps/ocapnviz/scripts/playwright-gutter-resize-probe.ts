#!/usr/bin/env -S deno run -A
/**
 * playwright-gutter-resize-probe.ts: Verifies the timeline's
 * gutter is drag-resizable via `view.gutterWidth`. Reads the
 * actual view state from `__ocv.timelineView` rather than
 * guessing from cursors.
 */
import { chromium } from "playwright";
import { GUTTER_MIN_PX, LANE_LABEL_WIDTH } from "../src/ui/Timeline/state.ts";

const url = Deno.args[0] ?? "http://127.0.0.1:5173/";
const browser = await chromium.launch({
	headless: true,
	args: ["--no-sandbox", "--disable-gpu"],
});
const ctx = await browser.newContext({
	viewport: { width: 1600, height: 1000 },
});
const page = await ctx.newPage();
page.on("pageerror", (e) => console.log("[pageerror]", e.message));
await page.addInitScript(() => {
	try {
		localStorage.removeItem("ocapnviz:app-state");
	} catch {
		// ignore
	}
});
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(500);

async function gutterWidth(): Promise<number> {
	return await page.evaluate((defaultWidth) => {
		const g = globalThis as unknown as {
			__ocv?: { timelineView?: { gutterWidth?: number } };
		};
		return g.__ocv?.timelineView?.gutterWidth ?? defaultWidth;
	}, LANE_LABEL_WIDTH);
}

const scrubber = await page.getByTestId("timeline-scrubber").boundingBox();
if (!scrubber) {
	console.log("FAIL — couldn't locate scrubber");
	await browser.close();
	Deno.exit(1);
}
console.log(`scrubber: ${JSON.stringify(scrubber)}`);

const initial = await gutterWidth();
console.log(`initial gutter width: ${initial}`);

// Grab the seam (at x = scrubber.x + initial) and drag right by 60px.
const seamX = scrubber.x + initial;
const seamY = scrubber.y + scrubber.height / 2;
await page.mouse.move(seamX, seamY);
await page.mouse.down({ button: "left" });
for (let i = 1; i <= 12; i++) {
	await page.mouse.move(seamX + i * 5, seamY);
	await page.waitForTimeout(8);
}
await page.mouse.up({ button: "left" });
await page.waitForTimeout(120);

const widened = await gutterWidth();
console.log(`after widen-drag: ${widened}`);

// Drag back left by 40px (to test shrink).
const newSeamX = scrubber.x + widened;
await page.mouse.move(newSeamX, seamY);
await page.mouse.down({ button: "left" });
for (let i = 1; i <= 8; i++) {
	await page.mouse.move(newSeamX - i * 5, seamY);
	await page.waitForTimeout(8);
}
await page.mouse.up({ button: "left" });
await page.waitForTimeout(120);

const shrunk = await gutterWidth();
console.log(`after shrink-drag: ${shrunk}`);

await browser.close();

const checks = {
	"widen drag increased gutter width": widened > initial + 40,
	"shrink drag decreased gutter width": shrunk < widened - 30,
	"shrink stayed above min": shrunk >= GUTTER_MIN_PX,
};
let failed = 0;
for (const [name, ok] of Object.entries(checks)) {
	console.log(`  ${ok ? "PASS" : "FAIL"} — ${name}`);
	if (!ok) failed++;
}
console.log("");
console.log(failed === 0 ? "ALL PASS" : `FAIL: ${failed}`);
Deno.exit(failed === 0 ? 0 : 1);
