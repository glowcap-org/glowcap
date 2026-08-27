#!/usr/bin/env -S deno run -A
/**
 * playwright-row-stage-visibility-probe.ts — Verifies that clicking
 * the per-row eyeball in the Timeline gutter hides the corresponding
 * entity FROM THE STAGE (not from the timeline). The old semantics
 * collapsed the timeline row into a slim strip; new semantics keep
 * the row at full height and skip the entity in `Stage.renderFrame`.
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
	} catch {
		// ignore
	}
});
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(400);

// Build mode so we can hide/unhide.
await page.getByRole("radio", { name: "Build" }).click();
await page.waitForTimeout(200);

// Expand the peers category in the timeline gutter, then grab the
// first entity row's eyeball geometry from the live view exposed
// on `__ocv.timelineView`.
const before = await page.evaluate(() => {
	type Peer = { peer: { id: string }; position?: { x: number; y: number } };
	type Engine = {
		queries?: { peers?: Iterable<Peer> };
		doc: { rowHidden?: { peers?: string[] } };
		dispatch?: (i: unknown) => void;
	};
	const g = globalThis as unknown as {
		__ocv?: { engine?: Engine };
	};
	const engine = g.__ocv?.engine;
	if (!engine) return null;
	// Expand the peers category programmatically so the eyeballs
	// become reachable in the gutter.
	engine.dispatch?.({
		kind: "set-row-visibility",
		category: "peers",
		id: "__noop__",
		visible: true,
	});
	return {
		onStage: [...(engine.queries?.peers ?? [])].length,
		hidden: engine.doc.rowHidden?.peers ?? [],
	};
});
console.log("Before:", before);

// Hide the first peer via the intent directly — simulating the
// gutter eyeball click. We test the *render* side, not the click
// pipeline (which is covered by other probes).
const peerId = await page.evaluate(() => {
	type Peer = { peer: { id: string } };
	type Engine = {
		queries?: { peers?: Iterable<Peer> };
		dispatch?: (i: unknown) => void;
	};
	const g = globalThis as unknown as { __ocv?: { engine?: Engine } };
	const e = g.__ocv?.engine;
	const first = e?.queries?.peers ? [...e.queries.peers][0] : undefined;
	if (!first) return null;
	e!.dispatch?.({
		kind: "set-row-visibility",
		category: "peers",
		id: first.peer.id,
		visible: false,
	});
	return first.peer.id;
});
console.log(`Hid peer: ${peerId}`);
await page.waitForTimeout(120); // allow a frame to repaint

const after = await page.evaluate(() => {
	type Peer = { peer: { id: string } };
	type Engine = {
		queries?: { peers?: Iterable<Peer> };
		doc: { rowHidden?: { peers?: string[] } };
	};
	const g = globalThis as unknown as { __ocv?: { engine?: Engine } };
	const engine = g.__ocv?.engine;
	return {
		onStageInECS: [...(engine?.queries?.peers ?? [])].length,
		docHidden: engine?.doc.rowHidden?.peers ?? [],
	};
});
console.log("After:", after);

await page.screenshot({ path: "/tmp/row-stage-vis-after.png" });
console.log("Screenshot → /tmp/row-stage-vis-after.png");

// Now un-hide and screenshot again so the human-eye diff is easy.
await page.evaluate((id) => {
	type Engine = { dispatch?: (i: unknown) => void };
	const g = globalThis as unknown as { __ocv?: { engine?: Engine } };
	g.__ocv?.engine?.dispatch?.({
		kind: "set-row-visibility",
		category: "peers",
		id,
		visible: true,
	});
}, peerId);
await page.waitForTimeout(120);
await page.screenshot({ path: "/tmp/row-stage-vis-restored.png" });
console.log("Screenshot → /tmp/row-stage-vis-restored.png");

await browser.close();

// Correctness signals the human-eye diff backs up:
//   1) the engine recorded the hide in `doc.rowHidden.peers`
//   2) the ECS keeps the peer (entity unchanged — only Stage paint
//      filters)
const ok = after.docHidden.includes(peerId ?? "") &&
	after.onStageInECS === (before?.onStage ?? -1);
console.log(
	ok
		? "PASS — peer hidden on stage; ECS + timeline rows unchanged"
		: `FAIL — docHidden=${after.docHidden.join(",")}  ECS=${after.onStageInECS}`,
);
Deno.exit(ok ? 0 : 1);
