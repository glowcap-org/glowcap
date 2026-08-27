#!/usr/bin/env -S deno run -A
/**
 * playwright-stage-rubber-band-probe.ts — PR 4a verification.
 *
 * The selection-store now lives at App level; Stage rubber-band
 * commits route through it and feed back to the multi-peer halo
 * paint. This probe drags a rubber-band rect across the stage and
 * confirms the stage view changes (halos lit on enclosed peers).
 *
 *   01-default               fresh stage, no selection
 *   02-rubber-band-selected  drag across peers → halos appear
 *   03-escape-cleared        Escape → halos gone
 *
 * Compares stage-only screenshot fingerprints. A change in
 * fingerprint is the necessary signal that the selection-store →
 * Stage paint path is wired end-to-end.
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

// Stay in the app's default mode (Play, fresh-load via the
// localStorage wipe). The user's report was "immediately": a
// fresh-load drag should already populate the store.
await page.evaluate(() => {
	(globalThis.document.activeElement as HTMLElement | null)?.blur();
});
await page.waitForTimeout(150);
const modeLabel = await page.evaluate(() => {
	const radios = document.querySelectorAll('input[type="radio"]:checked');
	return Array.from(radios).map((r) =>
		(r as HTMLInputElement).getAttribute("aria-label") ??
			(r as HTMLInputElement).value
	).join(",");
});
console.log(`active mode radios: ${modeLabel}`);

const outDir = "/tmp/ocv-stage-rubber-band";
await Deno.mkdir(outDir, { recursive: true });

// Stage region — above the timeline (which starts around y≈848)
// and below the top bar. The default fixture's peers sit in the
// canvas center, so this clip captures the area where halos will
// light up.
const stageClip = { x: 280, y: 80, width: 1040, height: 720 };

async function snap(name: string): Promise<Uint8Array> {
	return await page.screenshot({
		path: `${outDir}/${name}.png`,
		type: "png",
		clip: stageClip,
	});
}
function fingerprint(buf: Uint8Array): string {
	// Sample every Nth byte across the whole image for a more
	// sensitive fingerprint than a small window — halos are subtle.
	let hash = 0;
	const step = Math.max(1, Math.floor(buf.length / 4096));
	for (let i = 0; i < buf.length; i += step) {
		hash = ((hash << 5) - hash + buf[i]!) | 0;
	}
	return `${buf.length}:${hash}`;
}

type Ocv = {
	selection?: {
		selection?: { size?: number };
		anchor?: { kind: string; id: string } | null;
	};
};
async function selectionSize(): Promise<number> {
	return await page.evaluate(() => {
		const g = globalThis as unknown as { __ocv?: Ocv };
		const set = g.__ocv?.selection?.selection;
		return (set as { size?: number })?.size ?? -1;
	});
}

// First scout peer screen positions via the engine debug, then
// pick drag corners that genuinely enclose ≥2 peers. Falls back
// to a wide diagonal sweep if introspection is unavailable.
const peerPositions = await page.evaluate(() => {
	type Peer = { peer: { id: string }; position?: { x: number; y: number } };
	type Viewport = {
		toScreen: (x: number, y: number) => { x: number; y: number };
	};
	const g = globalThis as unknown as {
		__ocv?: { engine?: { queries?: { peers?: Iterable<Peer> } } };
		__ocvViewport?: Viewport;
	};
	const peers = g.__ocv?.engine?.queries?.peers;
	const vp = g.__ocvViewport;
	if (!peers || !vp) return [] as Array<{ id: string; sx: number; sy: number }>;
	const out: Array<{ id: string; sx: number; sy: number }> = [];
	for (const p of peers) {
		if (!p.position) continue;
		const s = vp.toScreen(p.position.x, p.position.y);
		out.push({ id: p.peer.id, sx: s.x, sy: s.y });
	}
	return out;
});
console.log(`peers seen: ${peerPositions.length}`);
for (const p of peerPositions) {
	console.log(`  ${p.id}  screen ≈ (${p.sx.toFixed(0)}, ${p.sy.toFixed(0)})`);
}

const buf1 = await snap("01-default");
const fp1 = fingerprint(buf1);
const size0 = await selectionSize();
console.log(`01-default              fp=${fp1}  store-multi=${size0}`);

// Drag a rubber-band that's guaranteed to start in empty stage
// territory (top-left corner of the stage clip) and end at the
// bottom-right corner of the canvas. That window encloses
// every peer in the default fixture.
const dragStart = { x: 320, y: 120 };
const dragEnd = { x: 1280, y: 760 };
await page.mouse.move(dragStart.x, dragStart.y);
await page.mouse.down({ button: "left" });
const steps = 20;
for (let i = 1; i <= steps; i++) {
	const t = i / steps;
	await page.mouse.move(
		dragStart.x + (dragEnd.x - dragStart.x) * t,
		dragStart.y + (dragEnd.y - dragStart.y) * t,
	);
	await page.waitForTimeout(12);
}
await page.mouse.up({ button: "left" });
await page.waitForTimeout(200);

const buf2 = await snap("02-rubber-band-selected");
const fp2 = fingerprint(buf2);
const size1 = await selectionSize();
console.log(`02-rubber-band-selected fp=${fp2}  store-multi=${size1}`);

// Confirm pre-shift store state is still 5 (no intermediate
// keyboard / click should have cleared it).
const preShiftSize = await selectionSize();
console.log(`pre-shift                store-multi=${preShiftSize}`);
// Shift+marquee: should ADD to the existing multi-selection,
// not replace. Drag a SMALLER rect that overlaps only one peer,
// expect the store to GROW past the prior multi (or stay if
// nothing new is enclosed).
await page.keyboard.down("Shift");
await page.mouse.move(360, 380);
await page.mouse.down({ button: "left" });
for (let i = 1; i <= 10; i++) {
	await page.mouse.move(360 + i * 12, 380 + i * 12);
	await page.waitForTimeout(10);
}
await page.mouse.up({ button: "left" });
await page.keyboard.up("Shift");
await page.waitForTimeout(150);
const sizeShift = await selectionSize();
const shiftLog = await page.evaluate(() => {
	const g = globalThis as unknown as { __ocv?: { lastEffects?: string[] } };
	return g.__ocv?.lastEffects ?? [];
});
console.log(`02b-shift-marquee       store-multi=${sizeShift}`);
console.log("  fsm tail:");
for (const line of shiftLog.slice(-30)) console.log(`    ${line}`);

// Shift+Option (alt) marquee: REMOVES captured entities from
// the existing selection (Adobe convention). The big rectangle
// covers every peer in the default fixture, so the store should
// shrink below the current size — ideally to 0 if all enclosed.
await page.keyboard.down("Shift");
await page.keyboard.down("Alt");
await page.mouse.move(320, 120);
await page.mouse.down({ button: "left" });
for (let i = 1; i <= 20; i++) {
	await page.mouse.move(
		320 + (1280 - 320) * (i / 20),
		120 + (760 - 120) * (i / 20),
	);
	await page.waitForTimeout(10);
}
await page.mouse.up({ button: "left" });
await page.keyboard.up("Alt");
await page.keyboard.up("Shift");
await page.waitForTimeout(150);
const sizeRemove = await selectionSize();
console.log(`02c-shift+option-remove store-multi=${sizeRemove}`);

// Escape clears everything.
await page.evaluate(() => {
	(globalThis.document.activeElement as HTMLElement | null)?.blur();
});
await page.waitForTimeout(120);
await page.keyboard.press("Escape");
await page.waitForTimeout(200);
const buf3 = await snap("03-escape-cleared");
const fp3 = fingerprint(buf3);
const size2 = await selectionSize();
console.log(`03-escape-cleared       fp=${fp3}  store-multi=${size2}`);

await browser.close();

const checks = {
	"rubber-band populated the store (size > 0)": size1 > 0,
	"rubber-band changed stage paint": fp1 !== fp2,
	"shift+marquee preserved or grew the set": sizeShift >= size1,
	"shift+option+marquee removed captured (shrank set)": sizeRemove < sizeShift,
	"Escape emptied the store": size2 === 0,
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
