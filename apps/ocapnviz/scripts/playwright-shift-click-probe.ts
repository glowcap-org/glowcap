#!/usr/bin/env -S deno run -A
/**
 * playwright-shift-click-probe.ts: Verifies single-entity click
 * modifiers symmetric with the marquee:
 *
 *   plain click                 → replace selection with [clicked]
 *   shift+click, not-in-set     → add to selection
 *   shift+click, already-in-set → no-op (your spec)
 *   shift+option click, in-set  → remove from selection
 *   shift+option click, not-in  → no-op
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

type PeerPos = { id: string; sx: number; sy: number };
async function peerPositions(): Promise<PeerPos[]> {
	return await page.evaluate(() => {
		type Peer = {
			peer: { id: string };
			position?: { x: number; y: number };
		};
		type VP = { toScreen: (x: number, y: number) => { x: number; y: number } };
		const g = globalThis as unknown as {
			__ocv?: { engine?: { queries?: { peers?: Iterable<Peer> } } };
			__ocvViewport?: VP;
		};
		const peers = g.__ocv?.engine?.queries?.peers;
		const vp = g.__ocvViewport;
		if (!peers || !vp) return [];
		const out: PeerPos[] = [];
		for (const p of peers) {
			if (!p.position) continue;
			const s = vp.toScreen(p.position.x, p.position.y);
			out.push({ id: p.peer.id, sx: s.x, sy: s.y });
		}
		return out;
	});
}

async function selectionContents(): Promise<{ size: number; ids: string[] }> {
	return await page.evaluate(() => {
		const g = globalThis as unknown as {
			__ocv?: { selection?: { selection?: Iterable<string> } };
		};
		const set = g.__ocv?.selection?.selection;
		if (!set) return { size: -1, ids: [] };
		const ids: string[] = [];
		for (const k of set) ids.push(k);
		return { size: ids.length, ids };
	});
}

async function clickAt(
	sx: number,
	sy: number,
	mods: { shift?: boolean; alt?: boolean } = {},
) {
	if (mods.shift) await page.keyboard.down("Shift");
	if (mods.alt) await page.keyboard.down("Alt");
	await page.mouse.move(sx, sy);
	await page.mouse.down({ button: "left" });
	await page.waitForTimeout(30);
	await page.mouse.up({ button: "left" });
	if (mods.alt) await page.keyboard.up("Alt");
	if (mods.shift) await page.keyboard.up("Shift");
	await page.waitForTimeout(120);
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
	await page.evaluate(() => {
		(document.activeElement as HTMLElement | null)?.blur();
	});
	await page.keyboard.press("Escape");
	await page.waitForTimeout(120);
}

const results: { name: string; ok: boolean; detail: string }[] = [];
const peers = await peerPositions();
const target = peers[0]!;
const targetKey = `peer:${target.id}`;

// (1) plain click → replace
await escapeAll();
await marqueeAll();
const beforePlain = await selectionContents();
await clickAt(target.sx, target.sy);
const afterPlain = await selectionContents();
results.push({
	name: "plain click → replace selection with [clicked]",
	ok: afterPlain.size === 1 && afterPlain.ids[0] === targetKey,
	detail: `before=${beforePlain.size}  after=[${afterPlain.ids.join(", ")}]`,
});

// (2) shift+click on already-selected → NO-OP (the user's ask)
await escapeAll();
await marqueeAll();
const beforeShiftIn = await selectionContents();
await clickAt(target.sx, target.sy, { shift: true });
const afterShiftIn = await selectionContents();
results.push({
	name: "shift+click on already-selected → no-op",
	ok: afterShiftIn.size === beforeShiftIn.size &&
		afterShiftIn.ids.every((k) => beforeShiftIn.ids.includes(k)),
	detail: `before=${beforeShiftIn.size}  after=${afterShiftIn.size}`,
});

// (3) shift+click on not-selected → ADD
await escapeAll();
const beforeShiftOut = await selectionContents();
await clickAt(target.sx, target.sy, { shift: true });
const afterShiftOut = await selectionContents();
results.push({
	name: "shift+click on not-selected → add",
	ok: afterShiftOut.size === beforeShiftOut.size + 1 &&
		afterShiftOut.ids.includes(targetKey),
	detail: `before=${beforeShiftOut.size}  after=[${afterShiftOut.ids.join(", ")}]`,
});

// (4) shift+option click on selected → REMOVE
await escapeAll();
await marqueeAll();
const beforeShiftOpt = await selectionContents();
await clickAt(target.sx, target.sy, { shift: true, alt: true });
const afterShiftOpt = await selectionContents();
results.push({
	name: "shift+option click on selected → remove",
	ok: afterShiftOpt.size === beforeShiftOpt.size - 1 &&
		!afterShiftOpt.ids.includes(targetKey),
	detail: `before=${beforeShiftOpt.size}  after=${afterShiftOpt.size}`,
});

// (5) shift+option click on not-selected → NO-OP
await escapeAll();
const beforeShiftOptOut = await selectionContents();
await clickAt(target.sx, target.sy, { shift: true, alt: true });
const afterShiftOptOut = await selectionContents();
results.push({
	name: "shift+option click on not-selected → no-op",
	ok: afterShiftOptOut.size === beforeShiftOptOut.size,
	detail: `before=${beforeShiftOptOut.size}  after=${afterShiftOptOut.size}`,
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
