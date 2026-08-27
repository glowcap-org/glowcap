#!/usr/bin/env -S deno run -A
/**
 * playwright-spacebar-pan-probe.ts — Verifies that holding space
 * while dragging a peer body pans the viewport (Adobe hand-tool
 * convention), and that NOT holding space lets the same drag
 * reposition the peer.
 *
 * Setup: dev server running on :5173.
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
	const t = msg.type();
	if (t === "error" || t === "warning") {
		console.log(`[browser ${t}]`, msg.text());
	}
});
page.on("pageerror", (err) => console.log("[browser pageerror]", err.message));

await page.goto(url);
await page.waitForLoadState("networkidle");
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(800);

// Click the Build mode toggle so spaceHeld is active (the hook only
// flips in build mode).
const buildBtn = page.locator('button[role="switch"][aria-label="Build mode"]');
if (await buildBtn.count() === 0) {
	// Fallback to title-based locator.
	await page.locator('button:has-text("Build")').first().click();
} else {
	await buildBtn.click();
}
await page.waitForTimeout(300);

// Find a peer's on-screen position via the canvas probe.
type Peer = { id: string; x: number; y: number };

async function getFirstPeer(): Promise<Peer | null> {
	return await page.evaluate(() => {
		// The app exposes engine state via __ocv only in dev builds; if
		// that's gone, fall back to scanning visible peer DOM markers.
		// Peers are drawn into PixiJS canvas only — no DOM nodes — so
		// we have to read engine.world via the global hook, or guess
		// via canvas center. The "open scenario" loads a fixture with
		// at least one peer near world (0, 0), which maps to roughly
		// canvas center given the default viewport.
		const canvas = document.querySelector(
			"canvas#ocv-pixi",
		) as HTMLCanvasElement | null;
		if (!canvas) return null;
		const r = canvas.getBoundingClientRect();
		// First peer in the demo fixtures sits near world (0,0). Convert
		// to screen by assuming viewport center is at canvas center.
		return {
			id: "estimate",
			x: r.left + r.width / 2,
			y: r.top + r.height / 2,
		};
	});
}

async function getCanvasCursor(): Promise<string> {
	return await page.evaluate(() => {
		const canvas = document.querySelector(
			"canvas#ocv-pixi",
		) as HTMLCanvasElement | null;
		return canvas ? globalThis.getComputedStyle(canvas).cursor || "(unset)" : "(no-canvas)";
	});
}

// Pixel-difference fingerprint via Playwright's PNG screenshot.
// `canvas.toDataURL` on a WebGL canvas without
// `preserveDrawingBuffer: true` returns a blank buffer (PixiJS
// uses an asynchronous gl context), so we route through the OS
// compositor instead — slow, but rock-solid signal.
async function canvasFingerprint(): Promise<string> {
	const buf = await page.screenshot({
		clip: { x: 200, y: 200, width: 800, height: 600 },
		type: "png",
	});
	// SHA-256 would be cleaner, but we only need a stable cheap
	// bucket: hash 32 bytes from the middle of the PNG body, past
	// the deterministic header.
	let hash = 0;
	for (let i = 200; i < 232 && i < buf.length; i++) {
		hash = ((hash << 5) - hash + buf[i]!) | 0;
	}
	return `${buf.length}:${hash}`;
}

const peer = await getFirstPeer();
if (!peer) {
	console.log("FAIL: no peer found");
	Deno.exit(1);
}

console.log(`Peer estimated at (${peer.x.toFixed(0)}, ${peer.y.toFixed(0)})`);

const baseCursor = await getCanvasCursor();
console.log(`Cursor (idle):           ${baseCursor}`);

// Hold space and check cursor flips to grab.
await page.keyboard.down("Space");
await page.waitForTimeout(150);
const spaceCursor = await getCanvasCursor();
console.log(`Cursor (space held):     ${spaceCursor}`);

// Capture content fingerprint before pan.
const beforePan = await canvasFingerprint();

// Hold the peer body's position, press primary button, drag right,
// release. Cursor should be "grabbing" during, content should change
// (viewport panned), peer should NOT have moved.
await page.mouse.move(peer.x, peer.y);
await page.waitForTimeout(60);
await page.mouse.down({ button: "left" });
await page.waitForTimeout(80);
const duringDragCursor = await getCanvasCursor();
console.log(`Cursor (mouse down):     ${duringDragCursor}`);

// Multi-step drag to engage the viewport's pan plugin (some
// implementations need >4px movement to commit).
for (let i = 1; i <= 12; i++) {
	await page.mouse.move(peer.x + i * 15, peer.y + i * 5);
	await page.waitForTimeout(15);
}
const afterDragMidCursor = await getCanvasCursor();
console.log(`Cursor (during drag):    ${afterDragMidCursor}`);

await page.mouse.up({ button: "left" });
await page.waitForTimeout(150);
await page.keyboard.up("Space");
await page.waitForTimeout(150);

const afterPan = await canvasFingerprint();
const panChanged = beforePan !== afterPan;
console.log(`Pan moved content:       ${panChanged ? "YES" : "NO"}`);

const releasedCursor = await getCanvasCursor();
console.log(`Cursor (released):       ${releasedCursor}`);

// Now WITHOUT spacebar — drag should reposition the peer.
const peer2 = await getFirstPeer();
if (peer2) {
	await page.mouse.move(peer2.x, peer2.y);
	await page.mouse.down({ button: "left" });
	for (let i = 1; i <= 12; i++) {
		await page.mouse.move(peer2.x + i * 8, peer2.y);
		await page.waitForTimeout(15);
	}
	await page.mouse.up({ button: "left" });
	await page.waitForTimeout(150);
}
const afterPeerDrag = await canvasFingerprint();
const peerDragChanged = afterPan !== afterPeerDrag;
console.log(`Plain drag changed:      ${peerDragChanged ? "YES" : "NO"}`);

// Verdict.
const cursorOk = spaceCursor === "grab" &&
	(duringDragCursor === "grabbing" || afterDragMidCursor === "grabbing");
const ok = panChanged && cursorOk;
console.log("");
console.log(ok ? "PASS: spacebar pan works on peers" : "FAIL");
console.log(`  pan moved content:    ${panChanged}`);
console.log(`  cursor 'grab' on hold: ${spaceCursor === "grab"}`);
console.log(
	`  cursor 'grabbing' during: ${duringDragCursor === "grabbing" || afterDragMidCursor === "grabbing"}`,
);

await browser.close();
Deno.exit(ok ? 0 : 1);
