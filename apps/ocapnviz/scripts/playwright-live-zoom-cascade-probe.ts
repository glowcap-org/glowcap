#!/usr/bin/env -S deno run -A
/**
 * Live-mode zoom-cascade screenshots. Switches to Live mode, then
 * wheel-zooms-out the timeline progressively and captures the
 * ruler at each stop so the s → min → hr → day → mo → yr cascade
 * is visible.
 */
import { chromium } from "playwright";

const url = Deno.args[0] ?? "http://127.0.0.1:5173/";
const browser = await chromium.launch({
  headless: true,
  args: ["--no-sandbox", "--disable-gpu"],
});
const ctx = await browser.newContext({
  viewport: { width: 1600, height: 1000 },
  colorScheme: "dark",
});
const page = await ctx.newPage();
page.on("pageerror", (e) => console.log("[pageerror]", e.message));
await page.addInitScript(() => {
  try {
    localStorage.removeItem("ocapnviz:app-state");
    localStorage.removeItem("ocapnviz:timeline-view");
  } catch {
    // ignore
  }
});
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(400);

await page.getByRole("radio", { name: "Live" }).click();
await page.waitForTimeout(400);

// We dispatch synthetic WheelEvents at the scrubber's host canvas
// because Playwright's mouse.wheel() doesn't always deliver to
// elements with `passive: false` listeners under headless
// Chromium. The Scrubber's wheel handler is attached natively,
// so a direct dispatch routes through the same code path.
async function dispatchWheelOnTimeline(deltaY: number) {
  await page.evaluate((dy) => {
    const target = document.querySelector(
      '[data-testid="timeline-scrubber"]',
    );
    if (!target) {
      console.warn("[probe] no scrubber found");
      return;
    }
    const r = target.getBoundingClientRect();
    target.dispatchEvent(
      new WheelEvent("wheel", {
        deltaY: dy,
        clientX: r.left + r.width / 2,
        clientY: r.top + r.height / 2,
        bubbles: true,
        cancelable: true,
      }),
    );
  }, deltaY);
}

const stops = [
  { label: "1x (start)", scrolls: 0 },
  { label: "few-x zoom-out", scrolls: 8 },
  { label: "tens-x zoom-out", scrolls: 20 },
  { label: "hundreds-x zoom-out", scrolls: 36 },
  { label: "thousand-x zoom-out (floor)", scrolls: 80 },
];

let cumulativeScrolls = 0;
for (const stop of stops) {
  const delta = stop.scrolls - cumulativeScrolls;
  for (let i = 0; i < delta; i++) {
    await dispatchWheelOnTimeline(200);
    await page.waitForTimeout(15);
  }
  cumulativeScrolls = stop.scrolls;
  await page.waitForTimeout(150);
  const slug = stop.label.replace(/[^a-z0-9]+/gi, "-").toLowerCase();
  const out = `/tmp/live-zoom-${slug}.png`;
  await page.screenshot({
    path: out,
    clip: { x: 0, y: 860, width: 1600, height: 140 },
  });
  console.log(`${stop.label} → ${out}`);
}

await browser.close();
