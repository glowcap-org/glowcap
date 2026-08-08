#!/usr/bin/env -S deno run -A
/**
 * playwright-test.ts — Drive the running ocapnviz dev server with
 * Playwright. Verifies pan/zoom and basic interactions on the
 * Stage viewport.
 *
 * Usage:
 *   deno run -A playwright-test.ts [url]
 *
 * Requires a vite dev server already running (e.g. via dev.sh).
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
  if (msg.type() === "error" || msg.type() === "warning") {
    console.log(`[browser ${msg.type()}]`, msg.text());
  }
});
page.on("pageerror", (err) => {
  console.log("[browser pageerror]", err.message);
});

await page.goto(url);
await page.waitForLoadState("networkidle");
// Wait for canvas + scene init.
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(1500);

// Capture probe state from the page: viewport transform, scenegraph
// shape, hitArea sizing.
type Probe = {
  hasCanvas: boolean;
  canvasRect: { x: number; y: number; w: number; h: number } | null;
  stageRect: { x: number; y: number; w: number; h: number } | null;
  pixiInfo: unknown;
};

// `elementFromPoint` is the cheapest "what would the browser dispatch
// this click to?" probe. Critical for the unified-canvas layout:
// the panel grid sits above the canvas via `z-index: 1`, and a single
// pointer-events misconfiguration on an ancestor breaks every drag /
// zoom / click on the visible canvas region without otherwise showing
// up as a visual regression.
const hitElement = await page.evaluate(() => {
  const el = document.elementFromPoint(800, 500);
  if (!el) return null;
  const chain: Array<{ tag: string; id: string; cls: string; pe: string }> = [];
  let cur: Element | null = el;
  while (cur) {
    chain.push({
      tag: cur.tagName,
      id: cur.id,
      cls: typeof cur.className === "string" ? cur.className : "",
      pe: getComputedStyle(cur).pointerEvents,
    });
    cur = cur.parentElement;
  }
  return { topMost: chain[0], ancestors: chain };
});
console.log("=== elementFromPoint(800, 500) ===");
console.log(JSON.stringify(hitElement, null, 2));

const probeBefore = await page.evaluate(() => {
  const canvas = document.querySelector(
    "canvas#ocv-pixi",
  ) as HTMLCanvasElement | null;
  const stageMarker = document.querySelector(
    '[data-region="stage"], section > div',
  ) as HTMLElement | null;
  // Walk the stash for the unified-canvas Application.
  const stash = (canvas as unknown as Record<string, unknown> | null)
    ?.["__ocvPixi"] as
      | { app?: { stage?: unknown } }
      | undefined;
  // deno-lint-ignore no-explicit-any
  const app: any = stash?.app;
  // deno-lint-ignore no-explicit-any
  function dump(node: any, depth = 0): unknown {
    if (!node || depth > 5) return null;
    const info: Record<string, unknown> = {
      type: node.constructor?.name,
      pos: node.position ? { x: node.position.x, y: node.position.y } : null,
      scale: node.scale ? { x: node.scale.x, y: node.scale.y } : null,
      eventMode: node.eventMode ?? null,
      hitArea: node.hitArea
        ? {
          type: node.hitArea.constructor?.name,
          x: node.hitArea.x,
          y: node.hitArea.y,
          w: node.hitArea.width,
          h: node.hitArea.height,
        }
        : null,
      childCount: node.children?.length ?? 0,
    };
    if (node.screenWidth !== undefined) {
      info.screenWidth = node.screenWidth;
      info.screenHeight = node.screenHeight;
      info.worldWidth = node.worldWidth;
      info.worldHeight = node.worldHeight;
      info.center = node.center ? { x: node.center.x, y: node.center.y } : null;
      info.worldScreenWidth = node.worldScreenWidth;
      info.worldScreenHeight = node.worldScreenHeight;
    }
    if (node.children && depth < 3) {
      // deno-lint-ignore no-explicit-any
      info.children = node.children.map((c: any) => dump(c, depth + 1));
    }
    return info;
  }
  const ret: Probe = {
    hasCanvas: !!canvas,
    canvasRect: canvas
      ? {
        x: canvas.getBoundingClientRect().x,
        y: canvas.getBoundingClientRect().y,
        w: canvas.getBoundingClientRect().width,
        h: canvas.getBoundingClientRect().height,
      }
      : null,
    stageRect: stageMarker
      ? {
        x: stageMarker.getBoundingClientRect().x,
        y: stageMarker.getBoundingClientRect().y,
        w: stageMarker.getBoundingClientRect().width,
        h: stageMarker.getBoundingClientRect().height,
      }
      : null,
    pixiInfo: app?.stage ? dump(app.stage) : null,
  };
  return ret;
});

console.log("=== PROBE BEFORE ===");
console.log(JSON.stringify(probeBefore, null, 2));

// Try to pan by drag in the middle of the canvas.
const w = probeBefore.canvasRect?.w ?? 1600;
const h = probeBefore.canvasRect?.h ?? 1000;
const cx = Math.floor(w / 2);
const cy = Math.floor(h / 2);

console.log(`\n=== ATTEMPT DRAG at (${cx},${cy}) → (${cx + 300},${cy + 200})`);
await page.mouse.move(cx, cy);
await page.mouse.down();
for (let i = 1; i <= 10; i++) {
  await page.mouse.move(cx + (i * 30), cy + (i * 20), { steps: 3 });
  await page.waitForTimeout(20);
}
await page.mouse.up();
await page.waitForTimeout(300);

const probeAfterPan = await page.evaluate(() => {
  const canvas = document.querySelector(
    "canvas#ocv-pixi",
  ) as HTMLCanvasElement | null;
  const stash = (canvas as unknown as Record<string, unknown> | null)
    ?.["__ocvPixi"] as
      | { app?: { stage?: { children?: unknown[] } } }
      | undefined;
  // deno-lint-ignore no-explicit-any
  const app: any = stash?.app;
  // deno-lint-ignore no-explicit-any
  function findViewport(node: any): any {
    if (!node) return null;
    if (node.center && node.worldScreenWidth !== undefined) return node;
    for (const c of node.children ?? []) {
      const r = findViewport(c);
      if (r) return r;
    }
    return null;
  }
  const vp = findViewport(app?.stage);
  return vp
    ? {
      pos: { x: vp.position.x, y: vp.position.y },
      scale: { x: vp.scale.x, y: vp.scale.y },
      center: { x: vp.center.x, y: vp.center.y },
      hitArea: vp.hitArea
        ? {
          x: vp.hitArea.x,
          y: vp.hitArea.y,
          w: vp.hitArea.width,
          h: vp.hitArea.height,
        }
        : null,
      worldScreenWidth: vp.worldScreenWidth,
      worldScreenHeight: vp.worldScreenHeight,
    }
    : null;
});
console.log("=== VIEWPORT AFTER PAN ===");
console.log(JSON.stringify(probeAfterPan, null, 2));

console.log(`\n=== ATTEMPT WHEEL ZOOM at (${cx},${cy})`);
await page.mouse.move(cx, cy);
await page.mouse.wheel(0, -500);
await page.waitForTimeout(300);

const probeAfterZoom = await page.evaluate(() => {
  const canvas = document.querySelector(
    "canvas#ocv-pixi",
  ) as HTMLCanvasElement | null;
  const stash = (canvas as unknown as Record<string, unknown> | null)
    ?.["__ocvPixi"] as
      | { app?: { stage?: { children?: unknown[] } } }
      | undefined;
  // deno-lint-ignore no-explicit-any
  const app: any = stash?.app;
  // deno-lint-ignore no-explicit-any
  function findViewport(node: any): any {
    if (!node) return null;
    if (node.center && node.worldScreenWidth !== undefined) return node;
    for (const c of node.children ?? []) {
      const r = findViewport(c);
      if (r) return r;
    }
    return null;
  }
  const vp = findViewport(app?.stage);
  return vp
    ? { scale: vp.scale.x, center: { x: vp.center.x, y: vp.center.y } }
    : null;
});
console.log("=== VIEWPORT AFTER ZOOM ===");
console.log(JSON.stringify(probeAfterZoom, null, 2));

// Reset zoom / pan so the next interactions land on the (0, 0)
// world neighborhood where the fixture's peers sit. Then attempt
// a click on the largest visible peer body — verifies federated
// hit-testing reaches sprite handlers, not just the bare viewport.
await page.evaluate(() => {
  const canvas = document.querySelector(
    "canvas#ocv-pixi",
  ) as HTMLCanvasElement | null;
  const stash = (canvas as unknown as Record<string, unknown> | null)
    ?.["__ocvPixi"] as
      | { app?: { stage?: { children?: unknown[] } } }
      | undefined;
  // deno-lint-ignore no-explicit-any
  const app: any = stash?.app;
  // deno-lint-ignore no-explicit-any
  function findViewport(node: any): any {
    if (!node) return null;
    if (node.center && node.worldScreenWidth !== undefined) return node;
    for (const c of node.children ?? []) {
      const r = findViewport(c);
      if (r) return r;
    }
    return null;
  }
  const vp = findViewport(app?.stage);
  if (vp) {
    vp.setZoom(1, true);
    vp.moveCenter(0, 0);
  }
});
await page.waitForTimeout(200);

// Snapshot the first peer's on-screen position and click it.
const peerHit = await page.evaluate(() => {
  const canvas = document.querySelector(
    "canvas#ocv-pixi",
  ) as HTMLCanvasElement | null;
  const stash = (canvas as unknown as Record<string, unknown> | null)
    ?.["__ocvPixi"] as
      | { app?: { stage?: { children?: unknown[] } } }
      | undefined;
  // deno-lint-ignore no-explicit-any
  const app: any = stash?.app;
  // deno-lint-ignore no-explicit-any
  function findViewport(node: any): any {
    if (!node) return null;
    if (node.center && node.worldScreenWidth !== undefined) return node;
    for (const c of node.children ?? []) {
      const r = findViewport(c);
      if (r) return r;
    }
    return null;
  }
  const vp = findViewport(app?.stage);
  if (!vp) return null;
  // The peerLayer is the second viewport child (gridLayer is first).
  // Its children are peer Containers; their .position is in world
  // coords. Map to global screen coords via the toGlobal helper.
  // deno-lint-ignore no-explicit-any
  const peerLayer: any = vp.children[2];
  // deno-lint-ignore no-explicit-any
  const firstPeer: any = peerLayer?.children?.[0];
  if (!firstPeer) return null;
  const global = firstPeer.getGlobalPosition();
  return { x: Math.round(global.x), y: Math.round(global.y) };
});
console.log("=== FIRST PEER GLOBAL POS ===", JSON.stringify(peerHit));

if (peerHit) {
  await page.mouse.click(peerHit.x, peerHit.y);
  await page.waitForTimeout(300);
  const sidebarBody = await page.evaluate(() => {
    // The Details section in the right pane should show some peer
    // text after selection. Cheapest assertion is just to look for
    // the "Peer" / "Profile" labels or any non-empty content
    // beyond the default placeholder.
    const aside = document.querySelectorAll("aside")[1];
    return aside?.textContent ?? null;
  });
  console.log(
    "=== SIDEBAR TEXT AFTER PEER CLICK (first 200 chars) ===\n",
    sidebarBody?.slice(0, 200) ?? "null",
  );
}

// Probe: count cullable + culled descendants under app.stage. With
// the per-frame culler running against the stage marker rect, tiles
// + sprites whose global bounds don't intersect the rect should have
// `culled: true` set; everything inside the rect should be false.
const cullCounts = await page.evaluate(() => {
  const canvas = document.querySelector(
    "canvas#ocv-pixi",
  ) as HTMLCanvasElement | null;
  const stash = (canvas as unknown as Record<string, unknown> | null)
    ?.["__ocvPixi"] as
      | { app?: { stage?: { children?: unknown[] } } }
      | undefined;
  // deno-lint-ignore no-explicit-any
  const app: any = stash?.app;
  let cullableTotal = 0;
  let cullableCulled = 0;
  // deno-lint-ignore no-explicit-any
  function walk(node: any): void {
    if (!node) return;
    if (node.cullable) {
      cullableTotal++;
      if (node.culled) cullableCulled++;
    }
    for (const c of node.children ?? []) walk(c);
  }
  walk(app?.stage);
  return { cullableTotal, cullableCulled };
});
console.log("=== CULL COUNTS ===", JSON.stringify(cullCounts));

// Quick label sanity: print every Text node's content and its
// container's culled flag. If labels visually look truncated, this
// proves whether the text changed or the container got culled.
const labelDump = await page.evaluate(() => {
  const canvas = document.querySelector(
    "canvas#ocv-pixi",
  ) as HTMLCanvasElement | null;
  const stash = (canvas as unknown as Record<string, unknown> | null)
    ?.["__ocvPixi"] as
      | { app?: { stage?: { children?: unknown[] } } }
      | undefined;
  // deno-lint-ignore no-explicit-any
  const app: any = stash?.app;
  const results: Array<
    {
      text: string;
      parentCulled: boolean;
      parentRenderable: boolean;
      parentVisible: boolean;
    }
  > = [];
  // deno-lint-ignore no-explicit-any
  function walk(node: any, parent: any): void {
    if (!node) return;
    if (node.constructor?.name === "Text") {
      results.push({
        text: String(node.text ?? ""),
        parentCulled: !!parent?.culled,
        parentRenderable: parent?.renderable !== false,
        parentVisible: parent?.visible !== false,
      });
    }
    for (const c of node.children ?? []) walk(c, node);
  }
  walk(app?.stage, null);
  return results;
});
console.log("=== LABELS ===");
for (const l of labelDump) console.log(JSON.stringify(l));

const shotPath = `/tmp/ocapnviz-pwt-${Date.now()}.png`;
await page.screenshot({ path: shotPath });
console.log(`\nScreenshot: ${shotPath}`);

await browser.close();
