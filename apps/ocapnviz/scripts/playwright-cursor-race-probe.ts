#!/usr/bin/env -S deno run -A
/**
 * playwright-cursor-race-probe.ts: proves the canvas keeps the cursor the
 * app asked for while Space is held and the pointer is moving, which is the
 * Hand tool's convention (`docs/cursor.md`).
 *
 * The bug it pins: Pixi writes the canvas cursor itself on every pointer
 * event, and its un-hover write reset the element to `"default"`. The Stage
 * derives the cursor once per frame from `cursorFor` and hands it to
 * `UnifiedCanvas`'s `setCursor`, so `UnifiedCanvas` makes Pixi's
 * `cursorStyles.default` a callback that writes that same standing answer.
 * Without it, a move with Space down flickered back to an arrow while the
 * canvas was still panning.
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

await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(600);

// Build mode for a meaningful tool context.
await page.getByRole("radio", { name: "Build" }).click();
await page.waitForTimeout(300);

async function cursorStyle(): Promise<string> {
	return await page.evaluate(() => {
		const c = document.querySelector(
			"canvas#ocv-pixi",
		) as HTMLCanvasElement | null;
		return c ? globalThis.getComputedStyle(c).cursor || "(unset)" : "(no-canvas)";
	});
}

// A point near the middle of the stage. Which surface it lands on depends
// on the scenario loaded, and nothing here needs it to be a particular one.
const peerX = 800;
const peerY = 500;

// (1) Hover the stage with no key down. Whatever the pointer is over, the
//     answer is one of the surface's own cursors and never the pan's, which
//     is what makes step (2)'s flip evidence of anything.
await page.mouse.move(peerX, peerY);
await page.waitForTimeout(150);
const hoverCursor = await cursorStyle();
console.log(`hover, no key:          ${hoverCursor}`);

// (2) Press Space without moving → the cursor flips to "grab".
await page.keyboard.down("Space");
await page.waitForTimeout(150);
const spaceCursor = await cursorStyle();
console.log(`space held:             ${spaceCursor}`);

// (3) Move the pointer a few pixels. It must stay "grab". This is the step
//     the bug failed, because Pixi's un-hover write landed "default".
await page.mouse.move(peerX + 5, peerY);
await page.waitForTimeout(50);
await page.mouse.move(peerX + 10, peerY);
await page.waitForTimeout(50);
await page.mouse.move(peerX + 15, peerY + 3);
await page.waitForTimeout(150);
const moveCursor = await cursorStyle();
console.log(`space held, moved 15px: ${moveCursor}`);

// (4) Release Space → the surface under the pointer answers again.
await page.keyboard.up("Space");
await page.waitForTimeout(150);
const releaseCursor = await cursorStyle();
console.log(`space released:         ${releaseCursor}`);

await browser.close();

// The regression: moving the pointer while Space was held reverted
// `canvas.style.cursor` from "grab" to "default", because Pixi's un-hover
// write raced the app's. The other checks confirm the ladder around it,
// the surface answers before the key and again after it.
const checks = {
	"before Space, the surface's own cursor": hoverCursor !== "grab" &&
		hoverCursor !== "grabbing",
	"space sets grab": spaceCursor === "grab",
	"moved while space-held stays grab (the race)": moveCursor === "grab",
	"release returns to non-grab": releaseCursor !== "grab" &&
		releaseCursor !== "grabbing",
};
let failures = 0;
for (const [name, ok] of Object.entries(checks)) {
	console.log(`  ${ok ? "PASS" : "FAIL"} — ${name}`);
	if (!ok) failures += 1;
}
console.log("");
console.log(failures === 0 ? "ALL PASS" : `FAIL: ${failures} check(s)`);
Deno.exit(failures === 0 ? 0 : 1);
