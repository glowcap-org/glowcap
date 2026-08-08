#!/usr/bin/env -S deno run -A
/**
 * Pane-size diagnostic. Reports the bottom pane's intrinsic
 * vs. effective height in Live mode with no entities, so we
 * can verify the auto-fit rule.
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
    localStorage.clear();
  } catch {
    // ignore
  }
});
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(800);

await page.getByRole("radio", { name: "Live" }).click();
await page.waitForTimeout(800);

const info = await page.evaluate(() => {
  const scrubber = document.querySelector('[data-testid="timeline-scrubber"]');
  const panel = scrubber?.closest("div[style*='display']");
  // Walk up to find the bottom-pane wrapper. The pane is the
  // grandparent of the scrubber's host (slot → panel → bottom-bar).
  let node: Element | null = scrubber;
  const chain: Array<{ tag: string; h: number; w: number }> = [];
  while (node) {
    const r = node.getBoundingClientRect();
    chain.push({
      tag: (node as HTMLElement).tagName +
        ((node as HTMLElement).getAttribute("data-testid")
          ? `[${(node as HTMLElement).getAttribute("data-testid")}]`
          : ""),
      h: Math.round(r.height),
      w: Math.round(r.width),
    });
    node = node.parentElement;
  }
  return { chain };
});

console.log("DOM chain (scrubber → ancestors):");
for (const n of info.chain.slice(0, 8)) {
  console.log(`  ${n.tag.padEnd(40)} ${n.w}×${n.h}`);
}

await browser.close();
