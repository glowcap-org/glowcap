#!/usr/bin/env -S deno run -A
/**
 * What a frame spends, asked four ways instead of one.
 *
 * A sampling CPU profile answers "which function" and nothing else. Three of
 * the cost classes worth suspecting on a per-frame path do not show up in one
 * at all, so this probe asks the browser directly:
 *
 *   1. **Engine counters** (`Performance.getMetrics`). Style recalculations,
 *      layout passes, and the seconds spent in each, as running totals this
 *      probe differences across the window and divides by frames drawn. A
 *      React tree that re-renders every frame shows here as recalc-per-frame
 *      near one whether or not any component is slow, which is the fact a
 *      flame graph of `updateFunctionComponent` cannot give you.
 *   2. **Allocation by function** (`HeapProfiler` sampling). Where bytes come
 *      from, which is the only direct read on "allocation inside the frame
 *      loop". A CPU profile sees the collector's work, never the site that
 *      caused it.
 *   3. **Frame timeline** (`Tracing`, `devtools.timeline`). The real
 *      main-thread task record: how long tasks ran, how many crossed the
 *      50ms long-task line, and how the window split between scripting,
 *      style, layout, and paint.
 *   4. **Frame deltas**, kept because it is the number the complaint is
 *      about.
 *
 *     deno run -A scripts/playwright-frame-diagnostics-probe.ts \
 *       http://127.0.0.1:4173/ test-data/the-kids-masterpiece.json 8 4 paused
 *
 * The last argument picks the condition, and `paused` is the sharp one. A
 * paused document is not changing, so every byte allocated and every triangle
 * built under it is work nothing asked for. Reading the playing pass alone
 * cannot tell a per-frame rebuild from the real cost of a moving picture.
 * The difference between the two passes can.
 *
 * Point it at a `vite preview` build rather than the dev server when the
 * question is what a user experiences: React's development build carries
 * `runWithFiberInDEV` on every component and will dominate any ranking taken
 * against `bash dev.sh`.
 *
 * The CPU throttle is what makes a cost difference visible as a dropped frame,
 * and what it costs in exchange is machine independence. These numbers are
 * about this machine on this day, which is why this is an instrument rather
 * than a check.
 */
import { chromium } from "playwright";

const url = Deno.args[0] ?? "http://127.0.0.1:4173/";
const docPath = Deno.args[1] ?? "test-data/the-kids-masterpiece.json";
const seconds = Number(Deno.args[2] ?? "8");
const throttle = Number(Deno.args[3] ?? "4");
const condition = Deno.args[4] ?? "playing";
if (condition !== "playing" && condition !== "paused") {
	console.error(`condition must be "playing" or "paused"; got ${condition}`);
	Deno.exit(2);
}

// `swiftshader` rasterizes in software on the main thread, and on this document
// that costs about 100ms per frame whether the picture is moving or standing
// still. A floor high enough to hide any change the application could make.
// It is the right choice for a probe that only reads JS-side numbers
// (allocation, script time, engine counters, all of which it leaves alone) and
// the wrong one for anything about frame rate. `gpu` opens a real window on a
// real device instead, which is the only way the composite cost means anything.
const renderer = Deno.args[5] ?? "swiftshader";
/** Pull the camera back until the whole document is on screen before measuring.
 *  Costs more rather than less, because nothing is left off screen to cull. */
const fit = (Deno.args[6] ?? "no") === "fit";
/** An explicit camera scale to measure at, which `fit` otherwise chooses. Used
 *  to ask what the background grid costs where every one of its tiles is on
 *  screen at once. */
const forcedZoom = Number(Deno.args[7] ?? "0") || 0;
if (renderer !== "swiftshader" && renderer !== "gpu") {
	console.error(`renderer must be "swiftshader" or "gpu"; got ${renderer}`);
	Deno.exit(2);
}
const browser = await chromium.launch(
	renderer === "gpu"
		? { headless: false, args: ["--no-sandbox"] }
		: { headless: true, args: ["--no-sandbox", "--use-gl=swiftshader"] },
);
const ctx = await browser.newContext({
	viewport: { width: 1600, height: 1000 },
	colorScheme: "dark",
});
const page = await ctx.newPage();
page.on("pageerror", (e) => console.log("[pageerror]", e.message));
await page.addInitScript(() => {
	try {
		localStorage.removeItem("ocapnviz:app-state");
	} catch { /* a browser that refuses storage still runs the probe */ }
});
page.on("dialog", (d) => d.accept());
await page.goto(url);
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(1200);
await page.setInputFiles('input[type="file"]', docPath);
await page.waitForTimeout(1500);

const doc = await page.evaluate(() => {
	// deno-lint-ignore no-explicit-any
	const d = (globalThis as any).__ocv?.engine?.doc;
	return {
		peers: Object.keys(d?.entities?.peers ?? {}).length,
		sessions: Object.keys(d?.entities?.sessions ?? {}).length,
		messages: Object.keys(d?.entities?.messages ?? {}).length,
		duration: d?.duration ?? 0,
	};
});
console.log(
	`${docPath}: ${doc.peers} peers, ${doc.sessions} sessions, ` +
		`${doc.messages} messages, ${Math.round(doc.duration)}ms long`,
);
if (doc.peers === 0) {
	console.log("nothing loaded");
	await browser.close();
	Deno.exit(1);
}

const cdp = await ctx.newCDPSession(page);
await cdp.send("Performance.enable");
await cdp.send("HeapProfiler.enable");
if (throttle > 1) {
	await cdp.send("Emulation.setCPUThrottlingRate", { rate: throttle });
}

const metricsNow = async (): Promise<Map<string, number>> => {
	const { metrics } = await cdp.send("Performance.getMetrics") as {
		metrics: { name: string; value: number }[];
	};
	return new Map(metrics.map((m) => [m.name, m.value]));
};

// Playback loops so the window measures the document rather than a clock that
// ran off its end. Nothing is called through `?.`: an optional call on a
// method name guessed wrong silently measures a stopped picture.
await page.evaluate((paused: boolean) => {
	// deno-lint-ignore no-explicit-any
	const g = globalThis as any;
	const eng = g.__ocv.engine;
	eng.restart();
	if (paused) {
		// Parked mid-document, where there is a picture to hold: everything that
		// ever appears is on stage by then, and none of it is moving.
		eng.seekTo(eng.doc.duration * 0.75);
		eng.clock.pause();
	} else {
		eng.clock.play();
	}
	g.__samples = [];
	let last = performance.now();
	const tick = () => {
		const now = performance.now();
		g.__samples.push(now - last);
		last = now;
		if (!paused && eng.clock.isAtEnd) {
			eng.restart();
			eng.clock.play();
		}
		g.__rafId = requestAnimationFrame(tick);
	};
	g.__rafId = requestAnimationFrame(tick);
}, condition === "paused");

// Optionally pull the camera back until the whole document is on screen. This
// is the harder case for the renderer, not the easier one: nothing is off
// screen for culling to discard, so every entity in the document is drawn on
// every frame. A document built by hand is exactly the one a reader wants to
// see whole, so it is worth measuring.
if (fit) {
	const fitted = await page.evaluate(() => {
		// deno-lint-ignore no-explicit-any
		const g = globalThis as any;
		const viewport = g.__ocvViewport;
		const world = g.__ocv.engine.world;
		let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
		for (const e of world.with("position")) {
			minX = Math.min(minX, e.position.x);
			minY = Math.min(minY, e.position.y);
			maxX = Math.max(maxX, e.position.x);
			maxY = Math.max(maxY, e.position.y);
		}
		if (!Number.isFinite(minX)) return null;
		// Margin so the outermost node's label is inside the frame rather than
		// clipped by it.
		const margin = 400;
		const spanX = maxX - minX + margin * 2;
		const spanY = maxY - minY + margin * 2;
		const zoom = Math.min(
			viewport.screenWidth / spanX,
			viewport.screenHeight / spanY,
		);
		viewport.setZoom(zoom, true);
		viewport.moveCenter((minX + maxX) / 2, (minY + maxY) / 2);
		return { zoom: viewport.scale.x, spanX, spanY };
	});
	console.log(
		fitted === null ? "nothing positioned to fit" : `fitted: zoom ${(fitted.zoom * 100).toFixed(1)}%, ` +
			`world span ${Math.round(fitted.spanX)}x${Math.round(fitted.spanY)}`,
	);
}
if (forcedZoom > 0) {
	const got = await page.evaluate((z: number) => {
		// deno-lint-ignore no-explicit-any
		const vp = (globalThis as any).__ocvViewport;
		vp.setZoom(z, true);
		vp.moveCenter(0, 0);
		return vp.scale.x;
	}, forcedZoom);
	console.log(`forced zoom: ${(got * 100).toFixed(2)}%`);
}
await page.waitForTimeout(400);

await cdp.send("Tracing.start", {
	categories: [
		"devtools.timeline",
		"disabled-by-default-devtools.timeline",
		"v8.execute",
	].join(","),
	transferMode: "ReturnAsStream",
});
await cdp.send("HeapProfiler.startSampling", { samplingInterval: 4096 });
const before = await metricsNow();

await page.waitForTimeout(seconds * 1000);

const after = await metricsNow();
const { profile: heap } = await cdp.send("HeapProfiler.stopSampling") as {
	// deno-lint-ignore no-explicit-any
	profile: any;
};
const traceEvents = await collectTrace();
const frames = await page.evaluate(() => {
	// deno-lint-ignore no-explicit-any
	const g = globalThis as any;
	cancelAnimationFrame(g.__rafId);
	return g.__samples as number[];
});

// ─────────────────────────── frame deltas ───────────────────────────

const sorted = [...frames].sort((a, b) => a - b);
const at = (p: number) => sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] ?? 0;
console.log(
	`\n=== FRAMES — ${condition}${fit ? ", fit" : ""}, ${renderer}, ` +
		`${seconds}s, throttle ${throttle}x, ${frames.length} drawn ===`,
);
console.log(
	`p50=${at(0.5).toFixed(1)}ms p90=${at(0.9).toFixed(1)}ms ` +
		`p99=${at(0.99).toFixed(1)}ms max=${at(1).toFixed(1)}ms  ` +
		`(${(1000 / Math.max(at(0.5), 0.001)).toFixed(0)} fps at p50)`,
);

// ───────────────────────── engine counters ─────────────────────────
//
// Per frame, because a total over a window is only as meaningful as the frame
// count beside it. Recalc and layout counts near 1.0 per frame mean the whole
// document is being restyled or re-laid-out on every tick, which is a
// different defect from any one function being slow.

const per = (name: string) =>
	((after.get(name) ?? 0) - (before.get(name) ?? 0)) /
	Math.max(1, frames.length);
const secs = (name: string) => ((after.get(name) ?? 0) - (before.get(name) ?? 0)) * 1000;

console.log(`\n=== ENGINE COUNTERS (per frame) ===`);
for (
	const [label, name] of [
		["style recalculations", "RecalcStyleCount"],
		["layout passes", "LayoutCount"],
	] as const
) {
	console.log(`  ${per(name).toFixed(2).padStart(8)}  ${label}`);
}
console.log(`=== ENGINE TIME (total ms over the window) ===`);
for (
	const [label, name] of [
		["script", "ScriptDuration"],
		["style recalc", "RecalcStyleDuration"],
		["layout", "LayoutDuration"],
		["all main-thread tasks", "TaskDuration"],
	] as const
) {
	console.log(
		`  ${secs(name).toFixed(0).padStart(8)}ms  ${label}` +
			`  (${(secs(name) / Math.max(1, frames.length)).toFixed(2)}ms/frame)`,
	);
}

// ─────────────────────── allocation by function ───────────────────────
//
// The one direct read on per-frame allocation. Folded by function so a site
// reached down several paths reports once.

const allocByFn = new Map<string, number>();
const walkHeap = (node: {
	callFrame: { functionName: string; url: string };
	selfSize: number;
	// deno-lint-ignore no-explicit-any
	children?: any[];
}) => {
	const fn = node.callFrame.functionName || "(anonymous)";
	const url = node.callFrame.url ?? "";
	const tag = url.includes("/assets/") || url.includes("/src/") ? fn : `${fn}  [${url === "" ? "vm" : "ext"}]`;
	if (node.selfSize > 0) {
		allocByFn.set(tag, (allocByFn.get(tag) ?? 0) + node.selfSize);
	}
	for (const c of node.children ?? []) walkHeap(c);
};
walkHeap(heap.head);
const totalAlloc = [...allocByFn.values()].reduce((a, b) => a + b, 0);
console.log(
	`\n=== ALLOCATION BY FUNCTION — ${(totalAlloc / 1e6).toFixed(1)} MB over ` +
		`${frames.length} frames, ${
			(totalAlloc / 1024 / Math.max(1, frames.length))
				.toFixed(1)
		} KB/frame ===`,
);
for (
	const [fn, bytes] of [...allocByFn.entries()]
		.sort((a, b) => b[1] - a[1])
		.slice(0, 14)
) {
	console.log(
		`  ${(bytes / 1024).toFixed(0).padStart(8)} KB  ` +
			`${(bytes / 1024 / Math.max(1, frames.length)).toFixed(2).padStart(7)} ` +
			`KB/frame  ${fn}`,
	);
}

// ────────────────────────── main-thread tasks ──────────────────────────

type TraceEvent = {
	name: string;
	ph: string;
	dur?: number;
	ts: number;
	cat?: string;
};
const byName = new Map<string, { total: number; count: number }>();
let longTasks = 0;
let longest = 0;
for (const ev of traceEvents as TraceEvent[]) {
	if (ev.ph !== "X" || typeof ev.dur !== "number") continue;
	const ms = ev.dur / 1000;
	const slot = byName.get(ev.name) ?? { total: 0, count: 0 };
	slot.total += ms;
	slot.count += 1;
	byName.set(ev.name, slot);
	if (ev.name === "RunTask") {
		if (ms > 50) longTasks++;
		if (ms > longest) longest = ms;
	}
}
console.log(
	`\n=== MAIN-THREAD TASKS — ${longTasks} over 50ms, ` +
		`longest ${longest.toFixed(0)}ms ===`,
);
for (
	const [name, slot] of [...byName.entries()]
		.sort((a, b) => b[1].total - a[1].total)
		.slice(0, 14)
) {
	console.log(
		`  ${slot.total.toFixed(0).padStart(8)}ms  ` +
			`${String(slot.count).padStart(6)}x  ` +
			`${(slot.total / slot.count).toFixed(2).padStart(7)}ms each  ${name}`,
	);
}

await browser.close();

/** Drain the tracing stream Chromium hands back as a handle. */
async function collectTrace(): Promise<unknown[]> {
	const done = new Promise<string>((resolve) => {
		cdp.on("Tracing.tracingComplete", (e) => {
			resolve((e as { stream?: string }).stream ?? "");
		});
	});
	await cdp.send("Tracing.end");
	const handle = await done;
	if (handle === "") return [];
	let json = "";
	for (;;) {
		const chunk = await cdp.send("IO.read", { handle, size: 1 << 20 }) as {
			data: string;
			eof: boolean;
			base64Encoded?: boolean;
		};
		json += chunk.base64Encoded ? atob(chunk.data) : chunk.data;
		if (chunk.eof) break;
	}
	await cdp.send("IO.close", { handle });
	try {
		const parsed = JSON.parse(json);
		return Array.isArray(parsed) ? parsed : (parsed.traceEvents ?? []);
	} catch {
		return [];
	}
}
