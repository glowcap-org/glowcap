#!/usr/bin/env -S deno run -A
/**
 * playwright-empty-click-probe.ts — Empty-stage click semantics
 * by modifier. Symmetric with the entity-click matrix:
 *
 *   plain        → clear everything (no target = nothing to keep)
 *   shift        → no-op (shift means "add"; nothing to add)
 *   shift+option → no-op (means "remove"; nothing to remove)
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
await page.getByRole("radio", { name: "Build" }).click();
await page.waitForTimeout(200);
await page.evaluate(() => {
	(document.activeElement as HTMLElement | null)?.blur();
});

async function selectionSize(): Promise<number> {
	return await page.evaluate(() => {
		const g = globalThis as unknown as {
			__ocv?: { selection?: { selection?: { size?: number } } };
		};
		return g.__ocv?.selection?.selection?.size ?? 0;
	});
}

async function marqueeAll() {
	await page.mouse.move(320, 120);
	await page.mouse.down({ button: "left" });
	for (let i = 1; i <= 20; i++) {
		await page.mouse.move(
			320 + (1280 - 320) * (i / 20),
			120 + (760 - 120) * (i / 20),
		);
		await page.waitForTimeout(6);
	}
	await page.mouse.up({ button: "left" });
	await page.waitForTimeout(120);
}

async function escapeAll() {
	await page.keyboard.press("Escape");
	await page.waitForTimeout(120);
}

// An empty-stage point that's nowhere near a peer / session.
// Top-left corner of the stage clip is safest.
const EMPTY_X = 340;
const EMPTY_Y = 140;

async function emptyClick(mods: { shift?: boolean; alt?: boolean } = {}) {
	if (mods.shift) await page.keyboard.down("Shift");
	if (mods.alt) await page.keyboard.down("Alt");
	await page.mouse.move(EMPTY_X, EMPTY_Y);
	await page.mouse.down({ button: "left" });
	await page.waitForTimeout(20);
	await page.mouse.up({ button: "left" });
	if (mods.alt) await page.keyboard.up("Alt");
	if (mods.shift) await page.keyboard.up("Shift");
	await page.waitForTimeout(120);
}

const results: { name: string; ok: boolean; detail: string }[] = [];

// (1) Plain empty click → clear.
await escapeAll();
await marqueeAll();
const before1 = await selectionSize();
await emptyClick();
const after1 = await selectionSize();
results.push({
	name: "plain empty click → clears selection",
	ok: after1 === 0 && before1 > 0,
	detail: `before=${before1}  after=${after1}`,
});

// (2) Shift+empty click → no-op.
await escapeAll();
await marqueeAll();
const before2 = await selectionSize();
await emptyClick({ shift: true });
const after2 = await selectionSize();
results.push({
	name: "shift+empty click → preserves selection (no-op)",
	ok: after2 === before2 && before2 > 0,
	detail: `before=${before2}  after=${after2}`,
});

// (3) Shift+option+empty click → no-op.
await escapeAll();
await marqueeAll();
const before3 = await selectionSize();
await emptyClick({ shift: true, alt: true });
const after3 = await selectionSize();
results.push({
	name: "shift+option+empty click → preserves selection (no-op)",
	ok: after3 === before3 && before3 > 0,
	detail: `before=${before3}  after=${after3}`,
});

await browser.close();

let failed = 0;
for (const r of results) {
	console.log(`  ${r.ok ? "PASS" : "FAIL"} — ${r.name}`);
	console.log(`         ${r.detail}`);
	if (!r.ok) failed++;
}
console.log("");
console.log(failed === 0 ? "ALL PASS" : `FAIL: ${failed}`);
Deno.exit(failed === 0 ? 0 : 1);
