#!/usr/bin/env -S deno run -A
/**
 * playwright-inspector-select-probe.ts — Verifies inspector
 * dropdowns show a chevron via inline `background-image`. The
 * prior fix relied on `.ocv-select` cascading the image; that
 * was getting stomped, so the chevron is now owned by the
 * inline style itself.
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
await page.waitForTimeout(400);

// Switch to Build mode so the inspector renders editor dropdowns
// (PeerFields' ProfileSelect is the easiest one to find).
await page.getByRole("radio", { name: "Build" }).click();
await page.waitForTimeout(200);

// Click a peer in the default fixture to populate the inspector.
const peers = await page.evaluate(() => {
	type Peer = {
		peer: { id: string };
		position?: { x: number; y: number };
	};
	type VP = { toScreen: (x: number, y: number) => { x: number; y: number } };
	const g = globalThis as unknown as {
		__ocv?: { engine?: { queries?: { peers?: Iterable<Peer> } } };
		__ocvViewport?: VP;
	};
	const list = g.__ocv?.engine?.queries?.peers;
	const vp = g.__ocvViewport;
	if (!list || !vp) return [];
	const out: { id: string; sx: number; sy: number }[] = [];
	for (const p of list) {
		if (!p.position) continue;
		const s = vp.toScreen(p.position.x, p.position.y);
		out.push({ id: p.peer.id, sx: s.x, sy: s.y });
	}
	return out;
});
if (peers.length === 0) {
	console.log("FAIL — no peers to inspect");
	await browser.close();
	Deno.exit(1);
}
await page.mouse.click(peers[0]!.sx, peers[0]!.sy);
await page.waitForTimeout(200);

const selects = await page.evaluate(() => {
	const out: { ariaLabel: string; bgImage: string }[] = [];
	for (const sel of document.querySelectorAll("select")) {
		const cs = getComputedStyle(sel);
		out.push({
			ariaLabel: sel.getAttribute("aria-label") ?? "",
			bgImage: cs.backgroundImage,
		});
	}
	return out;
});
console.log(`selects found: ${selects.length}`);
for (const s of selects) {
	const hasChevron = s.bgImage && s.bgImage !== "none";
	console.log(
		`  ${hasChevron ? "✓" : "✗"} aria="${s.ariaLabel}"  bgImage=${
			s.bgImage.length > 40 ? s.bgImage.slice(0, 40) + "…" : s.bgImage
		}`,
	);
}

await browser.close();

const allHaveChevron = selects.length > 0 &&
	selects.every((s) => s.bgImage && s.bgImage !== "none");
console.log("");
console.log(
	allHaveChevron
		? "ALL PASS"
		: `FAIL: ${selects.filter((s) => !s.bgImage || s.bgImage === "none").length} select(s) without chevron`,
);
Deno.exit(allHaveChevron ? 0 : 1);
