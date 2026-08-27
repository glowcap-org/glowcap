#!/usr/bin/env -S deno run -A
/**
 * Verifies: are the Timeline strip pixels rendered by PixiJS or by
 * the DOM? Test: remove the Overview marker `<div>` from the DOM via
 * inspector-equivalent JS, then snapshot the canvas-painted pixels
 * (the `overviewScene` Pixi container's position + child count).
 *
 *   - If pixels are PixiJS: container survives, but its position
 *     follows the polled rect (which goes to `0,0,0,0` for a
 *     disconnected element) and repaint short-circuits.
 *   - If pixels are DOM: no Pixi container at all, deleting the div
 *     simply removes the painted DOM subtree.
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
await page.goto(url);
await page.waitForLoadState("networkidle");
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(1500);

// Snapshot Pixi scene state for ALL `app.stage` direct children.
type SceneSnapshot = Array<{
	type: string;
	pos: { x: number; y: number };
	childCount: number;
	hasGraphicsContent: boolean;
}>;

async function snapshot(): Promise<SceneSnapshot> {
	return await page.evaluate(() => {
		const canvas = document.querySelector(
			"canvas#ocv-pixi",
		) as HTMLCanvasElement | null;
		const stash = (canvas as unknown as Record<string, unknown> | null)
			?.["__ocvPixi"] as
				| { app?: { stage?: { children?: unknown[] } } }
				| undefined;
		// deno-lint-ignore no-explicit-any
		const stage: any = stash?.app?.stage;
		const result: SceneSnapshot = [];
		for (const c of stage?.children ?? []) {
			// deno-lint-ignore no-explicit-any
			const child = c as any;
			// Heuristic: a Graphics child means "this scene actually has
			// drawn geometry buffered in." We check child.children
			// recursively for any Graphics with non-empty geometry.
			let hasGfx = false;
			const visit = (n: { children?: unknown[] } | undefined): void => {
				if (!n) return;
				// deno-lint-ignore no-explicit-any
				const node = n as any;
				if (node.constructor?.name === "Graphics") {
					const gd = node.context?.batches?.length;
					if (typeof gd === "number" && gd > 0) hasGfx = true;
				}
				for (const cc of n.children ?? []) {
					visit(cc as { children?: unknown[] });
				}
			};
			visit(child);
			result.push({
				type: child.constructor?.name,
				pos: { x: child.position?.x ?? 0, y: child.position?.y ?? 0 },
				childCount: child.children?.length ?? 0,
				hasGraphicsContent: hasGfx,
			});
		}
		return result;
	});
}

console.log("=== BEFORE DELETION (app.stage children) ===");
console.log(JSON.stringify(await snapshot(), null, 2));

// Find and remove the timeline-overview marker. The Overview's host
// div is the immediate child div of the bottom bar's panel column
// rendered above the scrubber slot. We find it by being the only
// div with a wheel handler in the bottom panel; here we just dig
// into the React tree's known structure: bottom row > div.panel >
// div.scrubberSlot > first child (Overview marker).
const removed = await page.evaluate(() => {
	// The overview marker is the div with style.height ≈ 26px sitting
	// inside the scrubberSlot. Easier: find the marker that has both a
	// pointerdown listener AND a 26px height.
	const candidates = Array.from(document.querySelectorAll("div"));
	// Overview marker: height: 26px, touchAction: none, width > 500
	// (rest of the bottom bar). The other 26px touchAction-none element
	// is a small ScrubInput; filter by width to disambiguate.
	for (const d of candidates) {
		const cs = getComputedStyle(d);
		if (cs.height !== "26px" || cs.touchAction !== "none") continue;
		const r = d.getBoundingClientRect();
		if (r.width < 500) continue;
		d.remove();
		return {
			removed: true,
			wasAt: { x: r.x, y: r.y, w: r.width, h: r.height },
		};
	}
	return { removed: false };
});
console.log("=== REMOVE RESULT ===", JSON.stringify(removed, null, 2));

await page.waitForTimeout(200);

console.log("\n=== AFTER DELETION (app.stage children) ===");
console.log(JSON.stringify(await snapshot(), null, 2));

const shotPath = `/tmp/ocapnviz-timeline-probe-${Date.now()}.png`;
await page.screenshot({ path: shotPath });
console.log(`\nScreenshot: ${shotPath}`);

await browser.close();
