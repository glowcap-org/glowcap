#!/usr/bin/env -S deno run -A
/**
 * Where a hand-built document's playback cost actually goes.
 *
 * `playwright-frame-cost-probe.ts` measures one condition. This one measures
 * the same window twice under a single varied condition, because the question
 * is not "how expensive is a frame" but "which layer is spending it":
 *
 *   1. **Everything drawn**, the document as a user sees it.
 *   2. **Everything hidden**, `setAllVisMode("both")`, which is the mode
 *      `render-frame.ts` skips its `sync*Sprite` calls for outright. Every
 *      sprite is destroyed and the per-entity loops fall through on their
 *      first test.
 *
 * The difference between the two is the whole render layer: rasterization and
 * the projection that feeds it. What survives into pass 2 is upstream of
 * `renderFrame`, so a pass 2 that still drops frames names the layer to look
 * at without anyone having to guess.
 *
 * It loads a real document through the application's own file input rather
 * than a fixture, so the corpus under test is the one the report came from.
 *
 *     deno run -A scripts/playwright-masterpiece-cost-probe.ts \
 *       http://127.0.0.1:5173/ test-data/the-kids-masterpiece.json 10 6
 *
 * The last two arguments are the sampling window in seconds per pass and a CPU
 * throttle factor. **The throttle is what makes the measurement mean
 * anything.** With headroom to spare every frame lands on the vsync boundary
 * and reads 16.7ms whether it cost one millisecond or ten, so an unthrottled
 * run compares two numbers that are both the display's refresh rate. What the
 * throttle costs in exchange is machine independence: these numbers are about
 * this machine on this day, which is why this is an instrument for a
 * measurement you are taking now and not a line a build check can hold.
 */
import { chromium } from "playwright";

const url = Deno.args[0] ?? "http://127.0.0.1:5173/";
const docPath = Deno.args[1] ?? "test-data/the-kids-masterpiece.json";
const seconds = Number(Deno.args[2] ?? "10");
const throttle = Number(Deno.args[3] ?? "6");

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

// The application opens documents through a hidden `<input type="file">`, so
// the probe hands it a real file the same way a user's picker would. Nothing
// here reaches past the UI to install a document directly: a corpus loaded by
// a private path is not the corpus the report came from.
await page.setInputFiles('input[type="file"]', docPath);
await page.waitForTimeout(1500);

const loaded = await page.evaluate(() => {
	// deno-lint-ignore no-explicit-any
	const doc = (globalThis as any).__ocv?.engine?.doc;
	return {
		peers: Object.keys(doc?.entities?.peers ?? {}).length,
		sessions: Object.keys(doc?.entities?.sessions ?? {}).length,
		messages: Object.keys(doc?.entities?.messages ?? {}).length,
		duration: doc?.duration ?? 0,
	};
});
console.log(
	`loaded ${docPath}: ${loaded.peers} peers, ${loaded.sessions} sessions, ` +
		`${loaded.messages} messages, ${loaded.duration}ms long`,
);
if (loaded.peers === 0) {
	console.log("nothing loaded — the probe has no document to measure");
	await browser.close();
	Deno.exit(1);
}

const cdp = await ctx.newCDPSession(page);
await cdp.send("Profiler.enable");
await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
if (throttle > 1) {
	await cdp.send("Emulation.setCPUThrottlingRate", { rate: throttle });
}

type Ranked = { name: string; ms: number; pct: number }[];
type Pass = {
	label: string;
	frames: number[];
	advance: number[];
	loops: number;
	ranked: Ranked;
	rankedAll: Ranked;
	windowMs: number;
};

async function measure(label: string, hideAll: boolean): Promise<Pass> {
	await page.evaluate((hide: boolean) => {
		// deno-lint-ignore no-explicit-any
		const eng = (globalThis as any).__ocv?.engine;
		eng.setAllVisMode(hide ? "both" : "visible");
		// Restart rather than resume, so both passes measure the same stretch of
		// the document. A second pass beginning where the first stopped would be
		// a different picture as well as a different condition.
		//
		// `engine.restart()` and not `clock.restart()`: rewinding the clock alone
		// leaves the world in its end state, which `clock.ts` says outright.
		eng.restart();
		eng.clock.play();
	}, hideAll);
	await page.waitForTimeout(400);

	// The sampler also keeps the clock inside the document. A hand-built
	// document is short, the masterpiece is 1.4 seconds, so a window long
	// enough to profile would otherwise spend most of itself on a clock that
	// had run off the end, and report the cost of a stopped picture as the cost
	// of playback.
	//
	// Nothing here is called through `?.`. An optional call on a wrong method
	// name does nothing silently, and the probe would measure a stopped clock
	// and report it as playback. A name this probe gets wrong throws, in view,
	// on the first frame.
	await page.evaluate(() => {
		// deno-lint-ignore no-explicit-any
		const g = globalThis as any;
		const eng = g.__ocv.engine;
		const span = eng.doc.duration as number;
		g.__samples = [];
		g.__loops = 0;
		let last = performance.now();
		const tick = () => {
			const now = performance.now();
			const t = eng.clock.t as number;
			g.__samples.push({ dt: now - last, t });
			last = now;
			if (eng.clock.isAtEnd || t >= span) {
				eng.restart();
				eng.clock.play();
				g.__loops++;
			}
			g.__rafId = requestAnimationFrame(tick);
		};
		g.__rafId = requestAnimationFrame(tick);
	});

	await cdp.send("Profiler.start");
	await page.waitForTimeout(seconds * 1000);
	// deno-lint-ignore no-explicit-any
	const { profile } = await cdp.send("Profiler.stop") as { profile: any };

	const { samples, loops } = await page.evaluate(() => {
		// deno-lint-ignore no-explicit-any
		const g = globalThis as any;
		cancelAnimationFrame(g.__rafId);
		return {
			samples: g.__samples as { dt: number; t: number }[],
			loops: g.__loops as number,
		};
	});

	const frames = samples.map((s) => s.dt);
	const advance: number[] = [];
	for (let i = 1; i < samples.length; i++) {
		advance.push(samples[i]!.t - samples[i - 1]!.t);
	}

	// Inclusive cost: each call carries what it spent plus everything it
	// called. Self time ranks leaves; this ranks the decisions that reach them,
	// which is the question "what is this frame spending on" is asking.
	// deno-lint-ignore no-explicit-any
	const nodes: any[] = profile.nodes;
	const selfTicks = new Map<number, number>();
	for (const s of profile.samples as number[]) {
		selfTicks.set(s, (selfTicks.get(s) ?? 0) + 1);
	}
	const windowMs = (profile.endTime - profile.startTime) / 1000;
	const msPerTick = windowMs /
		Math.max(1, (profile.samples as number[]).length);
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

	// Fold by function name: one function reached down several call paths is
	// one cost, and its per-path split is not what this probe is asking.
	//
	// Ranked twice, and the unfiltered half is the one that matters first.
	// Filtering to `/src/` answers "which of my functions is worst", which is
	// only the right question once app code is known to be where the time goes.
	// On this document it is not: the app-code column accounted for three
	// percent of the window, and a ranking that cannot see the other
	// ninety-seven sends you to optimize the wrong layer.
	const rank = (keep: (url: string) => boolean) => {
		const byName = new Map<string, number>();
		for (const n of nodes) {
			const fn = n.callFrame?.functionName as string | undefined;
			const src = (n.callFrame?.url as string | undefined) ?? "";
			if (!keep(src)) continue;
			const name = fn && fn.length > 0 ? fn : "(anonymous)";
			const label = src.includes("/src/") ? name : `${name}  [${shortSource(src)}]`;
			byName.set(label, Math.max(byName.get(label) ?? 0, inclusive(n.id)));
		}
		return [...byName.entries()]
			.map(([name, ms]) => ({ name, ms, pct: (ms / windowMs) * 100 }))
			.sort((a, b) => b.ms - a.ms)
			.slice(0, 14);
	};

	return {
		label,
		frames,
		advance,
		loops,
		ranked: rank((url) => url.includes("/src/")),
		rankedAll: rank(() => true),
		windowMs,
	};
}

/** Where a non-app frame came from, in as few characters as identify it: the
 *  dependency name for a bundled module, the host for anything else, and the
 *  engine's own label for a frame with no script behind it. */
function shortSource(url: string): string {
	if (url.length === 0) return "vm";
	const dep = url.match(/deps\/([^.?]+)/) ?? url.match(/node_modules\/([^/]+)/);
	if (dep) return dep[1]!;
	try {
		const u = new URL(url);
		const tail = u.pathname.split("/").filter((s) => s.length > 0).pop();
		return tail ?? u.host;
	} catch {
		return url.slice(0, 24);
	}
}

const median = (xs: number[]) => {
	const s = [...xs].sort((a, b) => a - b);
	return s[Math.floor(s.length / 2)] ?? 0;
};
const pct = (xs: number[], p: number) => {
	const s = [...xs].sort((a, b) => a - b);
	return s[Math.min(s.length - 1, Math.floor(s.length * p))] ?? 0;
};

function report(pass: Pass) {
	const f = pass.frames;
	console.log(`\n=== ${pass.label} — ${seconds}s, throttle ${throttle}x ===`);
	console.log(
		`frame delta p50=${pct(f, 0.5).toFixed(1)}ms ` +
			`p90=${pct(f, 0.9).toFixed(1)}ms p99=${pct(f, 0.99).toFixed(1)}ms ` +
			`max=${pct(f, 1).toFixed(1)}ms`,
	);
	console.log(
		`frames over 20ms: ${f.filter((d) => d > 20).length}/${f.length}   ` +
			`over 33ms: ${f.filter((d) => d > 33).length}   ` +
			`over 50ms: ${f.filter((d) => d > 50).length}`,
	);
	const evenMedian = median(pass.advance);
	console.log(
		`clock advance per frame median=${evenMedian.toFixed(2)}ms  ` +
			`stalled: ${pass.advance.filter((d) => d === 0).length}  ` +
			`jumped past double: ${
				pass.advance.filter((d) => d > 2 * evenMedian).length
			}  (document replayed ${pass.loops}x)`,
	);
	const show = (title: string, ranked: Ranked) => {
		console.log(`${title} (window ${pass.windowMs.toFixed(0)}ms):`);
		for (const r of ranked) {
			console.log(
				`  ${r.ms.toFixed(1).padStart(8)}ms ${r.pct.toFixed(1).padStart(5)}%  ` +
					r.name,
			);
		}
	};
	show("inclusive cost, EVERYTHING", pass.rankedAll);
	show("inclusive cost, app code only", pass.ranked);
}

const drawn = await measure("EVERYTHING DRAWN", false);
const hidden = await measure("EVERYTHING HIDDEN (sync*Sprite skipped)", true);
report(drawn);
report(hidden);

// A pass whose clock never moved measured an idle picture, whatever else it
// printed. Say so instead of letting the frame deltas below read as playback.
for (const pass of [drawn, hidden]) {
	const moved = pass.advance.filter((d) => d > 0).length;
	if (moved < pass.advance.length / 4) {
		console.log(
			`\n!! ${pass.label}: the clock advanced on only ${moved} of ` +
				`${pass.advance.length} frames, so this pass measured a stopped ` +
				`picture and its numbers are not about playback.`,
		);
	}
}

console.log(`\n=== WHAT THE RENDER LAYER COSTS ===`);
console.log(
	`p50 drawn=${pct(drawn.frames, 0.5).toFixed(1)}ms  ` +
		`p50 hidden=${pct(hidden.frames, 0.5).toFixed(1)}ms`,
);
console.log(
	`frames over 33ms drawn=${drawn.frames.filter((d) => d > 33).length}  ` +
		`hidden=${hidden.frames.filter((d) => d > 33).length}`,
);
console.log(
	"A hidden pass that still misses its budget puts the cost upstream of\n" +
		"renderFrame, and the render layer is innocent.",
);

await browser.close();
