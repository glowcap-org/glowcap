#!/usr/bin/env -S deno run -A
/**
 * playwright-field-rhythm-probe.ts: is the Inspector on one rhythm?
 *
 * Usage: playwright-field-rhythm-probe.ts [url]
 *
 * Selects each entity kind in turn and, for every field group, prints
 * each row's height, the pitch from one row's top to the next, and the
 * space left under the last row's content. Then it switches mode and
 * reprints, so a value that moves vertically between Build and Play
 * shows up as a changed number rather than as a feeling.
 *
 * What to look for: within a group the pitch should be one number, and
 * the trailing space should match across groups and across panels. A
 * last row that is shorter than its siblings is what reads as uneven
 * bottom padding even when the padding is identical.
 */
import { chromium } from "playwright";

const url = Deno.args[0] ?? "http://127.0.0.1:5173/";

const readGroups = () => {
	const out: {
		group: string;
		rows: number[];
		pitch: number[];
		tail: number;
	}[] = [];
	const boxes = document.querySelectorAll<HTMLElement>(".ocv-field");
	const byParent = new Map<HTMLElement, HTMLElement[]>();
	for (const f of boxes) {
		const p = f.parentElement;
		if (!p) continue;
		byParent.set(p, [...(byParent.get(p) ?? []), f]);
	}
	let n = 0;
	for (const [parent, fields] of byParent) {
		const rects = fields.map((f) => f.getBoundingClientRect());
		const pitch: number[] = [];
		for (let i = 1; i < rects.length; i++) {
			pitch.push(Math.round((rects[i]!.top - rects[i - 1]!.top) * 10) / 10);
		}
		// Space under the LAST row's ink, to the group box's inner edge.
		const last = rects[rects.length - 1]!;
		const pr = parent.getBoundingClientRect();
		const padBottom = parseFloat(getComputedStyle(parent).paddingBottom || "0");
		const tail = Math.round((pr.bottom - padBottom - last.bottom) * 10) / 10;
		out.push({
			group: `group ${++n} (${fields.length} rows)`,
			rows: rects.map((r) => Math.round(r.height * 10) / 10),
			pitch,
			tail,
		});
	}
	return out;
};

const browser = await chromium.launch({
	headless: true,
	args: ["--no-sandbox", "--disable-gpu"],
});
const ctx = await browser.newContext({
	viewport: { width: 1600, height: 1000 },
});
const page = await ctx.newPage();
await page.addInitScript(() => {
	try {
		localStorage.removeItem("ocapnviz:app-state");
	} catch {
		// first run has nothing to clear
	}
});
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(400);

const point = await page.evaluate(() => {
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

for (const mode of ["Build", "Play"] as const) {
	await page.getByRole("radio", { name: mode }).click();
	await page.waitForTimeout(300);
	if (point) {
		await page.mouse.click(point.x, point.y);
		await page.waitForTimeout(350);
	}
	console.log(`\n──────── ${mode} ────────`);
	for (const g of await page.evaluate(readGroups)) {
		console.log(
			`${g.group}\n  heights ${g.rows.join(", ")}\n  pitch   ${g.pitch.join(", ")}\n  tail    ${g.tail}`,
		);
	}
}

await browser.close();
