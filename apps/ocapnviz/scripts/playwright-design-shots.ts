#!/usr/bin/env -S deno run -A
/**
 * playwright-design-shots.ts — screenshots the chrome in both themes.
 *
 * Usage: playwright-design-shots.ts <out-dir> [url]
 *
 * Writes, per theme, a full window plus close crops of the top bar,
 * the left pane, and the inspector — the three surfaces the control
 * families all appear on. Run it before and after a design change and
 * compare the pairs.
 */
import { chromium } from "playwright";

const outDir = Deno.args[0] ?? "/tmp/ocv-shots";
const url = Deno.args[1] ?? "http://127.0.0.1:5173/";
await Deno.mkdir(outDir, { recursive: true });

const browser = await chromium.launch({
  headless: true,
  args: ["--no-sandbox", "--disable-gpu"],
});

for (const theme of ["light", "dark"] as const) {
  const ctx = await browser.newContext({
    viewport: { width: 1600, height: 1000 },
    deviceScaleFactor: 2,
    colorScheme: theme,
  });
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("[pageerror]", e.message));
  await page.addInitScript(() => {
    try {
      localStorage.removeItem("ocapnviz:app-state");
    } catch {
      // first run has nothing to clear
    }
  });
  await page.goto(url, { waitUntil: "networkidle" });
  await page.waitForSelector("canvas#ocv-pixi");
  await page.evaluate((t) => {
    document.documentElement.dataset.theme = t;
  }, theme);
  await page.waitForTimeout(500);

  // Build mode shows every control family at once: the palette, the
  // tool options bar, the undo/save clusters, and the inspector.
  await page.getByRole("radio", { name: "Build" }).click();
  await page.waitForTimeout(400);

  await page.screenshot({ path: `${outDir}/${theme}-full.png` });
  await page.screenshot({
    path: `${outDir}/${theme}-topbar.png`,
    clip: { x: 0, y: 0, width: 1600, height: 120 },
  });
  await page.screenshot({
    path: `${outDir}/${theme}-left.png`,
    clip: { x: 0, y: 40, width: 340, height: 700 },
  });

  // Pick a peer so the Inspector shows its fields, chips, link rows
  // and dropdowns rather than the empty-selection placeholder.
  const peerPoint = await page.evaluate(() => {
    type Peer = { peer: { id: string }; position?: { x: number; y: number } };
    type VP = { toScreen: (x: number, y: number) => { x: number; y: number } };
    const g = globalThis as unknown as {
      __ocv?: { engine?: { queries?: { peers?: Iterable<Peer> } } };
      __ocvViewport?: VP;
    };
    const peers = g.__ocv?.engine?.queries?.peers;
    const vp = g.__ocvViewport;
    if (!peers || !vp) return null;
    for (const p of peers) {
      if (p.position) return vp.toScreen(p.position.x, p.position.y);
    }
    return null;
  });
  if (peerPoint) {
    await page.mouse.click(peerPoint.x, peerPoint.y);
    await page.waitForTimeout(400);
  }
  await page.screenshot({
    path: `${outDir}/${theme}-right.png`,
    clip: { x: 1240, y: 40, width: 360, height: 900 },
  });

  // Hover a ghost icon button and a segmented cell, so the states
  // that only exist under a pointer land in a shot too.
  const undo = page.getByRole("button", { name: /^Undo/ }).first();
  if (await undo.count()) {
    await undo.hover();
    await page.waitForTimeout(250);
    await page.screenshot({
      path: `${outDir}/${theme}-hover.png`,
      clip: { x: 0, y: 0, width: 800, height: 90 },
    });
  }

  await ctx.close();
  console.log(`${theme} → ${outDir}/${theme}-*.png`);
}

await browser.close();
