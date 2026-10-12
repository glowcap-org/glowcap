#!/usr/bin/env -S deno run -A
/**
 * What one frame costs, and whether the picture moves smoothly.
 *
 * Three measurements, because "it stutters" can mean three different things
 * and only one of them is frames arriving late:
 *
 *   1. **Frame deltas.** How long between repaints. On an idle machine this
 *      pins to the display's refresh and tells you nothing, see the budget
 *      note below.
 *   2. **Advance evenness.** How far the playback clock moved each frame. A
 *      picture can repaint at a perfect 60 Hz and still judder if the time it
 *      is drawn at arrives in uneven steps, and no frame-rate number sees it.
 *   3. **Inclusive cost per function.** Sampled CPU profile, folded so each
 *      call carries what it spent plus everything it called. Self time ranks
 *      leaves. This ranks the decisions that reach them, which is the
 *      question "what is this frame actually spending on" is asking.
 *
 * Run it against a dev server (`bash dev.sh`) in one of two modes:
 *
 *     deno run -A scripts/playwright-frame-cost-probe.ts http://127.0.0.1:5173/ - 20 4
 *     deno run -A scripts/playwright-frame-cost-probe.ts http://127.0.0.1:5173/ ws://127.0.0.1:9111/ 40 4
 *
 * `-` plays the default fixture. A `ws:` URL records from a live feed
 * (`scripts/fake-viz-endpoint.ts` is a producer to point it at). The last two
 * arguments are the sampling window in seconds and a CPU throttle factor.
 *
 * **On the throttle, and why this is not a build check.** With headroom to
 * spare every frame lands on the vsync boundary, so frame deltas read 16.7 ms
 * whether the frame costs one millisecond or ten. A budget assertion at 1x
 * would therefore pass on a tree that had doubled the cost of a frame, which
 * is worse than no assertion at all. The throttle is what makes a cost
 * difference visible as a dropped frame, and what it costs in exchange is
 * machine independence, the number it prints is about this machine on this
 * day. So this is an instrument for a measurement you are about to take, not
 * a line anyone can hold. What holds a specific cost is a test that names it:
 * `lane-bundle.test.ts` keeps the timeline's lane stack from rebuilding under
 * a document nobody touched, and `recording-access.test.ts` keeps the
 * observation list stable enough for that to be possible.
 */
import { chromium } from "playwright";

const url = Deno.args[0] ?? "http://127.0.0.1:5173/";
const feed = Deno.args[1] ?? "-";
const seconds = Number(Deno.args[2] ?? "20");
const throttle = Number(Deno.args[3] ?? "1");

const browser = await chromium.launch({
	headless: true,
	args: ["--no-sandbox", "--use-gl=swiftshader"],
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
	} catch { /* a browser that refuses storage still runs the probe */ }
});
page.on("dialog", (d) => d.accept());
await page.goto(url);
await page.waitForSelector("canvas#ocv-pixi");
await page.waitForTimeout(1200);

if (feed === "-") {
	await page.evaluate(() => {
		// deno-lint-ignore no-explicit-any
		(globalThis as any).__ocv?.engine?.clock?.play();
	});
	await page.waitForTimeout(500);
} else {
	await page.getByRole("radio", { name: "Live" }).click();
	await page.waitForTimeout(300);
	const field = page.locator('input[placeholder="ws://127.0.0.1:9000/"]');
	await field.fill(feed);
	await field.press("Enter");
	await page.waitForTimeout(300);
	await page.getByRole("button", { name: "Start recording" }).click();
	// Let some topology arrive, so the window measures a running capture
	// rather than an empty one filling up.
	await page.waitForTimeout(2500);
}

const cdp = await ctx.newCDPSession(page);
await cdp.send("Profiler.enable");
await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
if (throttle > 1) {
	await cdp.send("Emulation.setCPUThrottlingRate", { rate: throttle });
}

await page.evaluate(() => {
	// deno-lint-ignore no-explicit-any
	const g = globalThis as any;
	const eng = g.__ocv?.engine;
	g.__samples = [];
	let last = performance.now();
	const tick = () => {
		const now = performance.now();
		g.__samples.push({ dt: now - last, t: eng?.clock?.t ?? 0 });
		last = now;
		g.__rafId = requestAnimationFrame(tick);
	};
	g.__rafId = requestAnimationFrame(tick);
});

await cdp.send("Profiler.start");
await page.waitForTimeout(seconds * 1000);
// deno-lint-ignore no-explicit-any
const { profile } = await cdp.send("Profiler.stop") as { profile: any };

const out = await page.evaluate(() => {
	// deno-lint-ignore no-explicit-any
	const g = globalThis as any;
	cancelAnimationFrame(g.__rafId);
	const doc = g.__ocv?.engine?.doc;
	return {
		samples: g.__samples as { dt: number; t: number }[],
		peers: Object.keys(doc?.entities?.peers ?? {}).length,
		sessions: Object.keys(doc?.entities?.sessions ?? {}).length,
		messages: Object.keys(doc?.entities?.messages ?? {}).length,
		observations: (doc?.recording?.sources ?? []).reduce(
			(n: number, s: { observations: unknown[] }) => n + s.observations.length,
			0,
		),
	};
});

const frames = out.samples.map((s) => s.dt);
const sorted = [...frames].sort((a, b) => a - b);
const at = (p: number) => sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] ?? 0;
const median = (xs: number[]) => {
	const s = [...xs].sort((a, b) => a - b);
	return s[Math.floor(s.length / 2)] ?? 0;
};

console.log(
	`\n=== FRAME DELTAS — ${feed === "-" ? "play" : "live"}, ${seconds}s, ` +
		`throttle ${throttle}x, ${out.observations} observations ===`,
);
console.log(
	`p50=${at(0.5).toFixed(1)}ms p90=${at(0.9).toFixed(1)}ms ` +
		`p99=${at(0.99).toFixed(1)}ms max=${at(1).toFixed(1)}ms`,
);
console.log(
	`over 20ms: ${frames.filter((d) => d > 20).length}   ` +
		`over 33ms: ${frames.filter((d) => d > 33).length}   ` +
		`over 50ms: ${frames.filter((d) => d > 50).length}`,
);
// A capture grows while it runs, so the two halves of the window are two
// different documents. A last third slower than the first is cost scaling
// with the recording rather than a fixed price per frame.
const third = Math.floor(frames.length / 3);
console.log(
	`p50 over the first third=${median(frames.slice(0, third)).toFixed(1)}ms, ` +
		`over the last=${median(frames.slice(-third)).toFixed(1)}ms`,
);
console.log(
	`doc: ${out.peers} peers, ${out.sessions} sessions, ${out.messages} messages`,
);

const advance: number[] = [];
for (let i = 1; i < out.samples.length; i++) {
	advance.push(out.samples[i]!.t - out.samples[i - 1]!.t);
}
const evenMedian = median(advance);
console.log(`\n=== PLAYBACK ADVANCE PER FRAME ===`);
console.log(
	`median=${evenMedian.toFixed(2)}ms  ` +
		`frames that advanced nothing: ${advance.filter((d) => d === 0).length}  ` +
		`frames that advanced past double: ${advance.filter((d) => d > 2 * evenMedian).length}`,
);

// deno-lint-ignore no-explicit-any
const nodes: any[] = profile.nodes;
const selfTicks = new Map<number, number>();
for (const s of profile.samples as number[]) {
	selfTicks.set(s, (selfTicks.get(s) ?? 0) + 1);
}
const windowMs = (profile.endTime - profile.startTime) / 1000;
const msPerTick = windowMs / Math.max(1, (profile.samples as number[]).length);
const childrenOf = new Map<number, number[]>();
for (const n of nodes) childrenOf.set(n.id, n.children ?? []);
const inclusive = (id: number): number => {
	let ticks = 0;
	const stack = [id];
	const seen = new Set<number>();
	while (stack.length > 0) {
		const cur = stack.pop()!;
		if (seen.has(cur)) continue;
		seen.add(cur);
		ticks += selfTicks.get(cur) ?? 0;
		for (const c of childrenOf.get(cur) ?? []) stack.push(c);
	}
	return ticks * msPerTick;
};
const byName = new Map<string, number>();
for (const n of nodes) {
	const fn = n.callFrame.functionName;
	// App code only. The framework rows below it are real cost but not cost
	// anyone reading this can act on.
	if (!fn || !String(n.callFrame.url).includes("/src/")) continue;
	byName.set(fn, (byName.get(fn) ?? 0) + inclusive(n.id));
}
console.log(
	`\n=== INCLUSIVE COST, app code (window ${windowMs.toFixed(0)}ms) ===`,
);
for (
	const [fn, ms] of [...byName.entries()].sort((a, b) => b[1] - a[1]).slice(
		0,
		20,
	)
) {
	console.log(
		`${ms.toFixed(1).padStart(9)}ms ${(100 * ms / windowMs).toFixed(1).padStart(5)}%  ${fn}`,
	);
}

await browser.close();
