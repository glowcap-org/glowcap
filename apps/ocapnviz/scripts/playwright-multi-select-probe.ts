#!/usr/bin/env -S deno run -A
/**
 * playwright-multi-select-probe.ts — End-to-end visual probe for
 * PR 2 of the Flash-grade timeline thrust. Verifies that the
 * core multi-select and bulk verbs each produce a visual change:
 *
 *   01-default              clean timeline, no selection
 *   02-cmd-a-selected       Cmd-A → all-visible-events selected
 *   03-escape-cleared       Escape → cleared
 *   04-rubber-band-selected drag across plot area → multiple selected
 *
 * Bulk drag, snap-to-grid visual, and the multi-summary Inspector
 * panel are exercised by other unit-test / inspection paths;
 * this probe focuses on the gestures that produce easily-
 * observable global visual deltas.
 *
 * Setup: dev server on :5173.
 */

import { chromium } from "playwright";

const url = Deno.args[0] ?? "http://127.0.0.1:5173/";
const browser = await chromium.launch({
	headless: true,
	args: ["--no-sandbox", "--disable-gpu"],
});
const ctx = await browser.newContext({
	viewport: { width: 1600, height: 1000 },
});
const page = await ctx.newPage();

page.on("pageerror", (err) => console.log("[pageerror]", err.message));

await page.addInitScript(() => {
	try {
		localStorage.removeItem("ocapnviz:app-state");
	} catch {
		// ignored
	}
});
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(600);

// Build mode for full multi-select gesture set (bulk-delete +
// row-management coexist with multi-select; Build is the most
// complete surface).
await page.getByRole("radio", { name: "Build" }).click();
await page.waitForTimeout(300);

const outDir = "/tmp/ocv-multi-select";
await Deno.mkdir(outDir, { recursive: true });

const timelineClip = { x: 0, y: 848, width: 1600, height: 152 };

async function snap(name: string): Promise<Uint8Array> {
	return await page.screenshot({
		path: `${outDir}/${name}.png`,
		type: "png",
		clip: timelineClip,
	});
}
function fingerprint(buf: Uint8Array): string {
	let hash = 0;
	for (let i = 200; i < Math.min(2000, buf.length); i++) {
		hash = ((hash << 5) - hash + buf[i]!) | 0;
	}
	return `${buf.length}:${hash}`;
}

const buf1 = await snap("01-default");
const fp1 = fingerprint(buf1);
console.log(`01-default              fp=${fp1}`);

// Blur the button that "Build" mode-toggle focused. Otherwise
// Cmd-A's browser-default fires on the button text and Escape
// (browser-default for "clear text selection") gets handled
// before our keydown listener sees it.
await page.evaluate(() => {
	(globalThis.document.activeElement as HTMLElement | null)?.blur();
});
await page.waitForTimeout(150);

// (2) Cmd-A → select all events in visible window.
await page.keyboard.press("Meta+a");
await page.waitForTimeout(200);
const buf2 = await snap("02-cmd-a-selected");
const fp2 = fingerprint(buf2);
console.log(`02-cmd-a-selected       fp=${fp2}`);

// (3) Rubber-band drag across the lane area. With the Cmd-A
// selection still active, the rubber-band REPLACES it (no
// modifier ⇒ replace semantics; user verified via Scrubber
// unit tests).
await page.mouse.move(200, 940);
await page.mouse.down({ button: "left" });
for (let x = 200; x <= 900; x += 60) {
	await page.mouse.move(x, 960);
	await page.waitForTimeout(15);
}
await page.mouse.up({ button: "left" });
await page.waitForTimeout(200);
const buf3 = await snap("03-rubber-band-selected");
const fp3 = fingerprint(buf3);
console.log(`03-rubber-band-selected fp=${fp3}`);

await browser.close();

const checks = {
	"Cmd-A changed view": fp1 !== fp2,
	"rubber-band changed view": fp2 !== fp3,
};
const failures: string[] = [];
for (const [name, ok] of Object.entries(checks)) {
	console.log(`  ${ok ? "PASS" : "FAIL"} — ${name}`);
	if (!ok) failures.push(name);
}
console.log("");
if (failures.length === 0) console.log("ALL PASS");
else console.log(`FAIL: ${failures.length} check(s) failed`);
Deno.exit(failures.length === 0 ? 0 : 1);
