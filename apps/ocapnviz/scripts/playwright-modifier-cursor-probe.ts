#!/usr/bin/env -S deno run -A
/**
 * playwright-modifier-cursor-probe.ts — Cursor preview for the
 * shift / shift+option modifiers. Same idea as the spacebar
 * cursor: the cursor reflects what a click / drag would do at
 * the moment of release.
 *
 *   neutral             "default" (or pointer over a sprite)
 *   shift               "copy"     (add to selection)
 *   shift+option (alt)  "no-drop"  (remove from selection)
 *   release             back to neutral
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

async function cursor(): Promise<string> {
  return await page.evaluate(() => {
    const c = document.querySelector("canvas#ocv-pixi") as HTMLCanvasElement;
    return c ? getComputedStyle(c).cursor || "(unset)" : "(no-canvas)";
  });
}

// Hover over empty stage area.
await page.mouse.move(400, 200);
await page.waitForTimeout(120);
const c0 = await cursor();
console.log(`neutral:           ${c0}`);

await page.keyboard.down("Shift");
await page.waitForTimeout(120);
const c1 = await cursor();
console.log(`shift:             ${c1}`);

await page.keyboard.down("Alt");
await page.waitForTimeout(120);
const c2 = await cursor();
console.log(`shift + option:    ${c2}`);

await page.keyboard.up("Alt");
await page.waitForTimeout(120);
const c3 = await cursor();
console.log(`back to shift:     ${c3}`);

await page.keyboard.up("Shift");
await page.waitForTimeout(120);
const c4 = await cursor();
console.log(`released:          ${c4}`);

await browser.close();

const checks = {
  "shift → copy": c1 === "copy",
  "shift+option → no-drop": c2 === "no-drop",
  "release option → copy": c3 === "copy",
  "release all → matches neutral": c4 === c0,
};
let failed = 0;
for (const [name, ok] of Object.entries(checks)) {
  console.log(`  ${ok ? "PASS" : "FAIL"} — ${name}`);
  if (!ok) failed++;
}
console.log("");
console.log(failed === 0 ? "ALL PASS" : `FAIL: ${failed}`);
Deno.exit(failed === 0 ? 0 : 1);
