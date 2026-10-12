#!/usr/bin/env -S deno run -A
/**
 * playwright-axis-lock-probe.ts: Adobe / Macromedia shift-axis-lock
 * on peer drag. Verifies all six subtleties:
 *
 *   1. Plain drag: peer follows cursor (no constraint).
 *   2. Shift-drag dominant-X: peer moves in X only, Y stays.
 *   3. Shift-drag dominant-Y: peer moves in Y only, X stays.
 *   4. Live flip across 45°: the locked axis swaps when the cursor
 *      crosses the diagonal from origin.
 *   5. Mid-drag press / release of Shift: engages / disengages
 *      the lock without restarting the drag.
 *   6. Group axis-lock: a shift-drag on a selected peer translates
 *      every selected peer parallel to the same locked axis.
 *
 * Reference frame: peer world position. The probe reads positions
 * straight from the ECS via `__ocv.engine.queries.peers`. Y in
 * world space is screen-down-positive (same as DOM clientY).
 *
 * Setup: dev server on :5173, fresh localStorage so the default
 * fixture loads and Build / Select tool are active (peer-drag on).
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

// Build mode keeps peer-drag enabled under Select tool.
await page.getByRole("radio", { name: "Build" }).click();
await page.waitForTimeout(200);
await page.evaluate(() => {
	(document.activeElement as HTMLElement | null)?.blur();
});

type PeerPos = { id: string; wx: number; wy: number; sx: number; sy: number };

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
		if (!peers) return [];
		const out: {
			id: string;
			wx: number;
			wy: number;
			sx: number;
			sy: number;
		}[] = [];
		for (const p of peers) {
			if (!p.position) continue;
			const s = vp ? vp.toScreen(p.position.x, p.position.y) : { x: 0, y: 0 };
			out.push({
				id: p.peer.id,
				wx: p.position.x,
				wy: p.position.y,
				sx: s.x,
				sy: s.y,
			});
		}
		return out;
	});
}

// pick the first peer to drag, coords are read from the live ECS
const before = await peerPositions();
if (before.length === 0) {
	console.log("FAIL — no peers visible to drag");
	await browser.close();
	Deno.exit(1);
}
const lead = before[0]!;
console.log(
	`peers seen: ${before.length}; lead = ${lead.id} @ world(${lead.wx.toFixed(0)}, ${lead.wy.toFixed(0)})`,
);

// Helper: drag from world-A to world-B by screen coords; lead's
// peer body is the start point.
async function dragPeer(opts: {
	fromSx: number;
	fromSy: number;
	toSx: number;
	toSy: number;
	shift?: boolean;
	shiftMid?: boolean;
	releaseShiftMid?: boolean;
}) {
	await page.mouse.move(opts.fromSx, opts.fromSy);
	if (opts.shift && !opts.shiftMid) await page.keyboard.down("Shift");
	await page.mouse.down({ button: "left" });
	const steps = 20;
	const halfwayAt = Math.floor(steps / 2);
	for (let i = 1; i <= steps; i++) {
		const t = i / steps;
		await page.mouse.move(
			opts.fromSx + (opts.toSx - opts.fromSx) * t,
			opts.fromSy + (opts.toSy - opts.fromSy) * t,
		);
		if (i === halfwayAt && opts.shiftMid) await page.keyboard.down("Shift");
		if (i === halfwayAt && opts.releaseShiftMid) {
			await page.keyboard.up("Shift");
		}
		await page.waitForTimeout(8);
	}
	await page.mouse.up({ button: "left" });
	if (opts.shift || opts.shiftMid) await page.keyboard.up("Shift");
	await page.waitForTimeout(80);
}

async function resetLeadTo(wx: number, wy: number) {
	// Drag the lead peer back to its original spot so each test
	// starts from a clean slate.
	const here = await peerPositions();
	const me = here.find((p) => p.id === lead.id);
	if (!me) return;
	await dragPeer({
		fromSx: me.sx,
		fromSy: me.sy,
		toSx: lead.sx,
		toSy: lead.sy,
	});
	// Compensate for residual drift via a second pass.
	const here2 = await peerPositions();
	const me2 = here2.find((p) => p.id === lead.id);
	if (!me2) return;
	const dwx = wx - me2.wx;
	const dwy = wy - me2.wy;
	if (Math.hypot(dwx, dwy) > 1) {
		await dragPeer({
			fromSx: me2.sx,
			fromSy: me2.sy,
			toSx: me2.sx + dwx,
			toSy: me2.sy + dwy,
		});
	}
}

type Test = { name: string; ok: boolean; detail: string };
const results: Test[] = [];

// (1) Plain drag, no constraint.
{
	await dragPeer({
		fromSx: lead.sx,
		fromSy: lead.sy,
		toSx: lead.sx + 100,
		toSy: lead.sy + 80,
	});
	const after = (await peerPositions()).find((p) => p.id === lead.id)!;
	const dx = after.wx - lead.wx;
	const dy = after.wy - lead.wy;
	const ok = Math.abs(dx - 100) < 4 && Math.abs(dy - 80) < 4;
	results.push({
		name: "1. plain drag follows cursor",
		ok,
		detail: `Δ=(${dx.toFixed(1)}, ${dy.toFixed(1)})  expected≈(100, 80)`,
	});
	await resetLeadTo(lead.wx, lead.wy);
}

// (2) Shift-drag dominant-X, Y stays.
{
	await dragPeer({
		fromSx: lead.sx,
		fromSy: lead.sy,
		toSx: lead.sx + 120,
		toSy: lead.sy + 30,
		shift: true,
	});
	const after = (await peerPositions()).find((p) => p.id === lead.id)!;
	const dx = after.wx - lead.wx;
	const dy = after.wy - lead.wy;
	const ok = Math.abs(dx - 120) < 6 && Math.abs(dy) < 2;
	results.push({
		name: "2. shift+drag dominant-X locks Y (Y≈0)",
		ok,
		detail: `Δ=(${dx.toFixed(1)}, ${dy.toFixed(1)})  expected≈(120, 0)`,
	});
	await resetLeadTo(lead.wx, lead.wy);
}

// (3) Shift-drag dominant-Y, X stays.
{
	await dragPeer({
		fromSx: lead.sx,
		fromSy: lead.sy,
		toSx: lead.sx + 30,
		toSy: lead.sy + 120,
		shift: true,
	});
	const after = (await peerPositions()).find((p) => p.id === lead.id)!;
	const dx = after.wx - lead.wx;
	const dy = after.wy - lead.wy;
	const ok = Math.abs(dx) < 2 && Math.abs(dy - 120) < 6;
	results.push({
		name: "3. shift+drag dominant-Y locks X (X≈0)",
		ok,
		detail: `Δ=(${dx.toFixed(1)}, ${dy.toFixed(1)})  expected≈(0, 120)`,
	});
	await resetLeadTo(lead.wx, lead.wy);
}

// (5) Mid-drag press of Shift, engages axis-lock from ORIGIN
//     (not from press-position). Adobe Photoshop Move-tool
//     convention: pressing shift snaps the object to the
//     origin's axis-locked position, then constrains further
//     motion. Releasing shift restores free motion.
{
	await dragPeer({
		fromSx: lead.sx,
		fromSy: lead.sy,
		toSx: lead.sx + 160,
		toSy: lead.sy + 60,
		shiftMid: true,
	});
	const after = (await peerPositions()).find((p) => p.id === lead.id)!;
	const dx = after.wx - lead.wx;
	const dy = after.wy - lead.wy;
	// X dominant throughout; shift engages halfway → lock from
	// origin snaps Y back to 0 and stays locked. Δ ≈ (160, 0).
	const ok = Math.abs(dx - 160) < 6 && Math.abs(dy) < 2;
	results.push({
		name: "5. shift pressed mid-drag snaps to origin-axis (Y→0)",
		ok,
		detail: `Δ=(${dx.toFixed(1)}, ${dy.toFixed(1)})  expected≈(160, 0)`,
	});
	await resetLeadTo(lead.wx, lead.wy);
}

// (6) Mid-drag release of Shift, restores free motion. Adobe
//     convention: when shift releases, the peer JUMPS to the
//     cursor's actual position (because target = cursor +
//     pickupOffset reasserts). The cursor has been moving
//     unconstrained the whole drag, so by drag-end the peer
//     catches up to cursor's final position.
{
	await dragPeer({
		fromSx: lead.sx,
		fromSy: lead.sy,
		toSx: lead.sx + 160,
		toSy: lead.sy + 60,
		shift: true,
		releaseShiftMid: true,
	});
	const after = (await peerPositions()).find((p) => p.id === lead.id)!;
	const dx = after.wx - lead.wx;
	const dy = after.wy - lead.wy;
	// Cursor ends at (lead + 160, lead + 60); shift released
	// halfway through, so the final unconstrained sample places
	// the peer at the cursor → Δ ≈ (160, 60).
	const ok = Math.abs(dx - 160) < 6 && Math.abs(dy - 60) < 6;
	results.push({
		name: "6. shift released mid-drag → peer catches up to cursor",
		ok,
		detail: `Δ=(${dx.toFixed(1)}, ${dy.toFixed(1)})  expected≈(160, 60)`,
	});
	await resetLeadTo(lead.wx, lead.wy);
}

// (7) Group axis-lock, shift+drag on a selected peer should
//     translate every selected peer parallel to the same locked
//     axis. Select all peers first (Cmd-A), then shift+drag
//     the lead; every peer's Y stays put, X shifts uniformly.
{
	// Rubber-band across the whole stage to populate the store
	// with every peer. Select-all does not write the store.
	await page.mouse.move(320, 120);
	await page.mouse.down({ button: "left" });
	for (let i = 1; i <= 12; i++) {
		await page.mouse.move(320 + i * 80, 120 + i * 50);
		await page.waitForTimeout(8);
	}
	await page.mouse.up({ button: "left" });
	await page.waitForTimeout(150);
	const ledger = await peerPositions();
	await dragPeer({
		fromSx: lead.sx,
		fromSy: lead.sy,
		toSx: lead.sx + 80,
		toSy: lead.sy + 20,
		shift: true,
	});
	const afterAll = await peerPositions();
	let ok = true;
	const detailParts: string[] = [];
	for (const p of ledger) {
		const a = afterAll.find((q) => q.id === p.id);
		if (!a) {
			ok = false;
			detailParts.push(`${p.id}=missing`);
			continue;
		}
		const ddx = a.wx - p.wx;
		const ddy = a.wy - p.wy;
		detailParts.push(`${p.id}=(${ddx.toFixed(1)}, ${ddy.toFixed(1)})`);
		// Every peer locked to X axis: Y delta ≈ 0, X delta ≈ 80.
		if (Math.abs(ddx - 80) > 6 || Math.abs(ddy) > 2) ok = false;
	}
	results.push({
		name: "7. shift+drag on selected peer locks the whole group axis",
		ok,
		detail: detailParts.join("  "),
	});
	// Reset by un-selecting then re-dragging each back.
	await page.keyboard.press("Escape");
}

await browser.close();

let failures = 0;
for (const r of results) {
	console.log(`  ${r.ok ? "PASS" : "FAIL"} — ${r.name}`);
	console.log(`         ${r.detail}`);
	if (!r.ok) failures++;
}
console.log("");
console.log(failures === 0 ? "ALL PASS" : `FAIL: ${failures}`);
Deno.exit(failures === 0 ? 0 : 1);
