#!/usr/bin/env -S deno run -A
/**
 * playwright-row-substrate-probe.ts — End-to-end visual probe for
 * PR 1 of the Flash-grade timeline thrust. Verifies:
 *
 *   01-default        category lanes collapsed (today's look)
 *   02-expanded       peers category expanded → per-entity rows
 *                     (chevron click on peers header lands)
 *   03-collapsed-back chevron click collapses again
 *
 * Per-row visibility (eyeball click) and row-drag-reorder are
 * deliberately NOT covered here because their pointer coords
 * depend on `scrubberHeight` growth post-expand in ways the
 * fixed-pixel probe can't predict reliably across panel sizes.
 * Their behavior is covered by the `hitTestGutter` unit tests
 * (`Scrubber.test.ts`), which exercise the same code path with
 * synthetic row descriptors.
 *
 * Setup: dev server running on :5173.
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

// Clear persisted state for a deterministic start.
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

// Build mode → row-management gestures are active.
await page.getByRole("radio", { name: "Build" }).click();
await page.waitForTimeout(300);

const outDir = "/tmp/ocv-row-substrate";
await Deno.mkdir(outDir, { recursive: true });

// Crop just the timeline panel. The pane auto-grows when a
// category expands (intrinsic height pushes the grid row), so
// measure the actual bottom pane bounds before each snap.
async function timelineClip(): Promise<
  { x: number; y: number; width: number; height: number }
> {
  return await page.evaluate(() => {
    // Bottom bar = last direct child of the app-root grid.
    const root = globalThis.document.querySelector(".ocv-app-root");
    const panel = root?.lastElementChild;
    if (!panel) return { x: 0, y: 848, width: 1600, height: 152 };
    const r = panel.getBoundingClientRect();
    return {
      x: Math.floor(r.left),
      y: Math.floor(r.top),
      width: Math.floor(r.width),
      height: Math.floor(r.height),
    };
  });
}

async function snap(name: string): Promise<Uint8Array> {
  return await page.screenshot({
    path: `${outDir}/${name}.png`,
    type: "png",
    clip: await timelineClip(),
  });
}

// Cheap content fingerprint — hash bytes past the PNG header.
// Different content ⇒ different fingerprint.
function fingerprint(buf: Uint8Array): string {
  let hash = 0;
  for (let i = 200; i < Math.min(2000, buf.length); i++) {
    hash = ((hash << 5) - hash + buf[i]!) | 0;
  }
  return `${buf.length}:${hash}`;
}

// (1) Default — everything collapsed.
const buf1 = await snap("01-default");
const fp1 = fingerprint(buf1);
console.log(`01-default        fp=${fp1}`);

// Helper: compute the peers-header chevron's y in viewport
// coords. The header is the first scrubber row, offset from
// pane-top by (control row + overview + LANE_GAP/2 + lane/2).
// The pane top shifts when the pane auto-grows on expansion.
async function peersChevronY(): Promise<number> {
  const clip = await timelineClip();
  // Control row ≈ 40, overview = 26, lane/2 ≈ 7. ~73 below pane top.
  return clip.y + 73;
}

// (2) Click the peers chevron at the dynamic y.
await page.mouse.click(8, await peersChevronY());
await page.waitForTimeout(300);
const buf2 = await snap("02-expanded");
const fp2 = fingerprint(buf2);
console.log(`02-expanded       fp=${fp2}`);

// (3) Click the chevron again to collapse back. Re-measure
// the pane bounds — expanded the pane grew taller, so the
// chevron is at a new viewport y.
await page.mouse.click(8, await peersChevronY());
await page.waitForTimeout(300);
const buf3 = await snap("03-collapsed-back");
const fp3 = fingerprint(buf3);
console.log(`03-collapsed-back fp=${fp3}`);

await browser.close();

const checks = {
  "expand changed view": fp1 !== fp2,
  "collapse changed view": fp2 !== fp3,
  // Round-trip: collapsed view after toggling back should
  // resemble the original (within fingerprint tolerance — the
  // PNG bytes are deterministic for static pixel content).
  "collapse restores original": fp1 === fp3,
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
