#!/usr/bin/env -S deno run -A
/**
 * playwright-firstpaint-probe.ts — Captures the visual transition
 * from boot screen → app interactive at fast intervals so we can
 * look for the "green bar at top of stage" flash the user reported.
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

page.on("console", (msg) => {
  if (msg.type() === "error") console.log("[console.error]", msg.text());
});
page.on("pageerror", (err) => console.log("[pageerror]", err.message));

// Start navigation, then snapshot at offset times measured from
// navigationStart.
const outDir = "/tmp/ocv-firstpaint";
await Deno.mkdir(outDir, { recursive: true });

// Disable cache so we see the cold-load transition the user sees
// after a code change / hard reload.
await ctx.clearCookies();
const cdp = await ctx.newCDPSession(page);
await cdp.send("Network.enable");
await cdp.send("Network.setCacheDisabled", { cacheDisabled: true });
// Force dark theme via the localStorage key index.html reads.
await page.addInitScript(() => {
  try {
    localStorage.setItem("ocapnviz:theme", "dark");
  } catch {
    // ignored
  }
});
// Slow down all network responses so the boot transition has
// observable phases. 200ms throttle is generous.
await cdp.send("Network.emulateNetworkConditions", {
  offline: false,
  downloadThroughput: 5 * 1024 * 1024,
  uploadThroughput: 1 * 1024 * 1024,
  latency: 80,
});

const navStart = Date.now();
const nav = page.goto(url, { waitUntil: "commit" });

// Start screenshotting immediately on navigation commit; race against
// the goto promise so we get frames during boot.
const snapTimes = [
  2700,
  2900,
  3050,
  3150,
  3250,
  3350,
  3500,
  3700,
  3900,
  4200,
  4600,
  5500,
];
for (const t of snapTimes) {
  const elapsed = Date.now() - navStart;
  const wait = Math.max(0, t - elapsed);
  if (wait > 0) await page.waitForTimeout(wait);
  const filename = `${outDir}/snap-${String(t).padStart(4, "0")}ms.png`;
  try {
    await page.screenshot({ path: filename, type: "png" });
    console.log(`snap @ ${Date.now() - navStart}ms → ${filename}`);
  } catch (err) {
    console.log(`snap @ ${t}ms failed:`, (err as Error).message);
  }
}
await nav;

// Sample pixel column at x=800 (stage center) across rows to find
// any non-uniform color bands in the final state.
const cols = await page.evaluate(() => {
  const canvas = document.querySelector(
    "canvas#ocv-pixi",
  ) as HTMLCanvasElement | null;
  if (!canvas) return null;
  // Canvas is WebGL; we can't readBack via 2d. Inspect computed
  // backgrounds of DOM elements at the top of the visible chrome
  // instead — useful if the green is from a DOM, not WebGL.
  const samples: Array<{ y: number; tag: string; bg: string; id: string }> = [];
  for (let y = 0; y < 200; y += 5) {
    const el = document.elementFromPoint(800, y);
    if (!el) continue;
    const cs = globalThis.getComputedStyle(el);
    samples.push({
      y,
      tag: el.tagName,
      bg: cs.backgroundColor,
      id: el.id || el.className?.toString().slice(0, 40) || "",
    });
  }
  return samples;
});
console.log("DOM column @ x=800, y=0..200:");
for (const s of cols ?? []) {
  console.log(`  y=${s.y}: <${s.tag}> ${s.bg} ${s.id}`);
}

await browser.close();
