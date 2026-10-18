// The mycelium under the page: a network of fine threads grown behind the
// content of the Rooms page and the documentation site.
//
// It is grown, not tiled (network.ts owns the growth), so no two
// window sizes show the same network and nothing in it repeats.
// light.ts lays out the light that moves through the threads, renderer.ts
// draws both on the page's GPU device, and open_ground.ts says where the
// pointer is free to light them. This file owns the canvases and decides
// when the light runs.
//
// It is drawn with WebGPU and nothing else. A browser that cannot make a
// device shows the page's plain ground, and the page works the same.
//
// The threads lie in three planes at different depths, finer and fainter
// far away and softer up close, all fuzzed with short hairs.
//
// The threads stay out of the reader's way. The canvases sit under the
// content and take no pointer events, their colors come from `--mycelium`
// and `--mycelium-pulse` in ui/tokens.css, and a mask thins everything
// toward the middle of the window, where the reading is.
//
// It answers a little:
//
// - It fades in, slowly when the page is an arrival: a tab's first page, or
//   any load of a page that is arrived at each time, as Rooms is.
// - On an arrival the network also grows in from the edges, its tips lit.
// - `dim()` fades the threads down and stills their life, for a page whose
//   connection is lost. `regrow()` brings them back: the same network grows
//   in again from the edges, its tips lit.
// - Threads near the mouse light, and cool once it rests. The near plane
//   moves a little against the mouse.
// - A click or tap sends a wave of light out along the threads around it.
// - Both answer only over open ground. Over a control, text, or a surface,
//   the pointer is about the page, so the light fades and no wave starts.
// - Every few seconds, toward the edges, a point of light runs out along a
//   thread or a small wave flickers. `pulse()` sends a run on demand.
// - The threads breathe, very slowly.
//
// Under reduced motion only the fade in runs, and in a hidden tab nothing does.
// Between those, nothing is drawn: the threads are drawn once, and only a
// frame with light in it draws again.

/// <reference lib="dom" />

import { readColors } from "../gpu/color.ts";
import { keepOnPageDevice } from "../gpu/device.ts";
import { grow, type Links, linksOf, type Network, READING } from "./network.ts";
import { onOpenGround } from "./open_ground.ts";
import { runAlong, TRAIL, WAVE_BAND, WAVE_REACH, WAVE_SPEED, waveAlong } from "./light.ts";
import { GroundRenderer, type PlaneLook, type Sheet } from "./renderer.ts";
import { RUN_SLOTS, WAVE_SLOTS } from "./shader.ts";

/** First visit to a tab: how long the network takes to grow in, in ms. */
const GROW_MS = 1700;
/** How long the growing front takes to cool once growth ends, in ms. */
const COOL_MS = 1000;
/** How long the threads take to fade in when the page is an arrival, and
 * when it is one more page in a tab that has seen them. */
const ARRIVE_MS = 2600;
const RETURN_MS = 500;
/** One slow breath of the threads, in and out, in ms. */
const BREATH_MS = 18000;
/** How often a breath moves the threads' opacity. At its fastest a breath
 * changes it by a 255th, one step of an 8-bit channel, in this long, so a
 * faster beat would only redraw the same frame. */
const BREATH_STEP_MS = 125;
const GROWN_KEY = "glowcap.mycelium.grown";
/** How long the light under the mouse takes to rise once it is back over
 * open ground, and to fade once it rests, in ms. */
const RISE_MS = 260;
const LINGER = 1600;
/** How far the near plane moves against the pointer, at most, in CSS pixels.
 * Its canvas reaches this far past every edge, so moving it bares nothing. */
const PARALLAX = 5;
/** How long the near plane takes to follow the pointer, so it drifts rather
 * than jitters with every move. */
const PARALLAX_EASE = "translate 1.6s cubic-bezier(.2, .6, .2, 1)";
/** Life of its own: the wait before the next run or flicker is between
 * these, in ms, and this share of them are runs. */
const AMBIENT_MS = [2200, 6000] as const;
const RUN_SHARE = 0.55;
/** A run of light: the shortest thread it runs on, how much of the thread it
 * covers, and its speed in pixels per ms, all in CSS pixels. */
const RUN = { shortest: 200, length: 900, speed: [0.22, 0.32] } as const;
/** A run surges as it goes, the way cytoplasm streams: its speed swings this
 * share above and below its own on a period of 2π × SURGE_MS. */
const SURGE = 0.35;
const SURGE_MS = 260;
/** Ambient light starts outside this ellipse around the reading, as a share
 * of the half window, on threads at least this wide. */
const OUTSKIRT = 0.55;
const RUN_WIDTH = 0.45;
const FLICKER_WIDTH = 0.3;
/** A phone's toolbar changes the height by a strip, and regrowing for that
 * would swap the whole network under the reader's thumb. A resize regrows
 * only past this change in height, in CSS pixels, after this quiet, in ms. */
const RESIZE_SLACK = 140;
const RESIZE_QUIET = 220;
/** How much of their light the threads keep while dimmed, and how long
 * they take to dim, in ms. */
const DIM = 0.3;
const DIM_MS = 1600;

/** The planes of threads, far to near. Each grows for a window `grown` times
 * the real one and is drawn shrunk to fit, so a far plane is finer and
 * denser and a near one is coarser. Only the middle plane carries light, the
 * way only one depth is in focus. The near plane has a canvas of its own,
 * kept to the edges of the window, blurred by `blur` CSS pixels, and moving
 * a little against the pointer. */
const PLANES = [
	{ grown: 1.5, alpha: 0.5, blur: 0, fuzz: false, near: false },
	{ grown: 1, alpha: 1, blur: 0, fuzz: true, near: false },
	{ grown: 0.5, alpha: 0.4, blur: 1.4, fuzz: true, near: true },
] as const;
const FOCUS = 1;
/** The threads' color and their light's, from ui/tokens.css. */
const COLORS = { thread: "--mycelium", light: "--mycelium-pulse" } as const;

/** How far a run has gone after `ms`, in units of its own speed. Its pace
 * swings with the surge but never stops or turns back. */
function surged(ms: number): number {
	return ms + SURGE * SURGE_MS * (1 - Math.cos(ms / SURGE_MS));
}

export interface Mycelium {
	/** Send a point of light along a thread. Ignored under reduced motion. */
	pulse(): void;
	/** Fade the threads down and stop their life of their own. Ignored while
	 * dimmed. */
	dim(): void;
	/** Undo `dim()`: the threads fade back up while the same network grows in
	 * again from the edges. Under reduced motion or in a hidden tab only the
	 * fade runs. Ignored unless dimmed. */
	regrow(): void;
	/** Remove the canvases and stop every timer and listener. */
	stop(): void;
}

export interface MyceliumOptions {
	/** Treat this load as an arrival, whatever the tab has seen. A page that
	 * is opened rather than navigated to, as Rooms is, says so. */
	arriving?: boolean;
}

/** A canvas and its WebGPU context. */
interface Layer {
	canvas: HTMLCanvasElement;
	context: GPUCanvasContext;
}

/** A canvas fixed under the content, reaching `bleed` CSS pixels past every
 * edge. `middle` is how much of it shows in the middle of the window, where
 * the reading is. Null if the browser gives no WebGPU context. */
function fixedLayer(name: string, middle: number, bleed = 0): Layer | null {
	const canvas = document.createElement("canvas");
	const context = canvas.getContext("webgpu") as GPUCanvasContext | null;
	if (context === null) return null;
	canvas.className = name;
	canvas.setAttribute("aria-hidden", "true");
	const style = canvas.style;
	style.position = "fixed";
	style.inset = `${-bleed}px`;
	style.width = `calc(100% + ${2 * bleed}px)`;
	style.height = `calc(100% + ${2 * bleed}px)`;
	style.zIndex = "-1";
	style.pointerEvents = "none";
	const at = `50% ${READING.y * 100}%`;
	const mask = `radial-gradient(ellipse 62% 56% at ${at}, rgb(0 0 0 / ${middle}), ` +
		`rgb(0 0 0 / ${Math.min(1, middle * 2)}) 55%, #000 96%)`;
	style.maskImage = mask;
	style.setProperty("-webkit-mask-image", mask);
	return { canvas, context };
}

/** Start the mycelium under the page. Resolves to null, with nothing added
 * to the page, when the browser cannot draw it. */
export async function startMycelium(options: MyceliumOptions = {}): Promise<Mycelium | null> {
	const mid = fixedLayer("mycelium", 0.22);
	// Out of focus, it would only blur the reading, so none of it reaches the
	// middle of the window.
	const near = fixedLayer("mycelium-near", 0, PARALLAX);
	// Light draws the eye, so less of it reaches the text than of the threads.
	const light = fixedLayer("mycelium-light", 0.08);
	if (mid === null || near === null || light === null) return null;
	const shown = [mid, near, light];
	const read = readColors(document.body, COLORS);
	if (read === null) return null;
	let colors = read;

	let renderer: GroundRenderer | null = null;
	const release = await keepOnPageDevice({
		mount: (device, format) => {
			try {
				renderer = new GroundRenderer(device, format);
			} catch {
				// tolerant: a device that refuses the pipelines draws no threads.
				return false;
			}
			for (const { context } of shown) context.configure({ device, format, alphaMode: "premultiplied" });
			return true;
		},
		lost: () => {
			renderer?.destroy();
			renderer = null;
		},
		// Drawn again whole, with whatever light was alight left out.
		relit: () => {
			renderer!.load(planes, FOCUS);
			links = null;
			waves.length = 0;
			runs.length = 0;
			growth = null;
			paint();
		},
	});
	if (release === null) return null;
	document.body.prepend(...shown.map((l) => l.canvas));
	near.canvas.style.transition = PARALLAX_EASE;

	const still = matchMedia("(prefers-reduced-motion: reduce)");
	const scale = Math.min(2, devicePixelRatio || 1);
	let planes: Network[] = [];
	// The focal plane, which the light runs through, and its neighbors along
	// the threads, found when the first wave needs them.
	let focus: Network | null = null;
	let links: Links | null = null;
	let size = { w: 0, h: 0 };
	let frameId = 0;
	let ambient: ReturnType<typeof setTimeout> | undefined;
	// When the growth in progress on an arrival began.
	let growth: number | null = null;
	// The waves and runs alight, each in the slot its layout is written to.
	const waves: { slot: number; at: number; reach: number; peak: number }[] = [];
	const runs: { slot: number; at: number; speed: number; length: number }[] = [];
	// Where the mouse last moved over open ground, when, since when it has
	// been there without leaving for content, and whether it has left.
	const mouse = { x: 0, y: 0, at: -Infinity, since: -Infinity, away: true };

	const sheets = (): Sheet[] => [
		{ context: mid.context, w: size.w, h: size.h, bleed: 0 },
		{ context: near.context, w: size.w + 2 * PARALLAX, h: size.h + 2 * PARALLAX, bleed: PARALLAX },
	];
	const lightSheet = (): Sheet => ({ context: light.context, w: size.w, h: size.h, bleed: 0 });
	const looks: PlaneLook[] = PLANES.map((p) => ({
		sheet: p.near ? 1 : 0,
		shrink: 1 / p.grown,
		alpha: p.alpha,
		blur: p.blur * scale,
	}));

	const fit = ({ canvas }: Layer, bleed = 0) => {
		canvas.width = Math.round((size.w + 2 * bleed) * scale);
		canvas.height = Math.round((size.h + 2 * bleed) * scale);
	};

	// Every plane, each grown up to its step in `upTo`.
	const drawPlanes = (upTo: number[]) => renderer?.paint(sheets(), looks, upTo, colors.thread, scale);
	const paint = () => drawPlanes(planes.map((plane) => plane.steps));

	const lively = () => !still.matches && !document.hidden && focus !== null;
	const wake = () => {
		if (frameId === 0) frameId = requestAnimationFrame(frame);
	};

	// One frame of light: the mouse's, the growing front's, and every wave
	// and run alight. The last frame of any of them draws it gone, so the
	// light canvas is left empty when it rests.
	const frame = (now: number) => {
		frameId = 0;
		if (renderer === null || focus === null) return;
		let busy = false;
		const resting = now - mouse.at;
		let hover = 0;
		if (resting < LINGER) {
			hover = (1 - resting / LINGER) ** 3 * Math.min(1, (now - mouse.since) / RISE_MS);
			busy = true;
		}
		let upTo = 0;
		let front = 0;
		if (growth !== null) {
			// Every plane grows in step with the focal one.
			const t = Math.min(1, (now - growth) / GROW_MS);
			upTo = Math.round((1 - (1 - t) ** 2) * focus.steps);
			const steps = focus.steps;
			drawPlanes(planes.map((plane) => Math.round((upTo / steps) * plane.steps)));
			const cooling = Math.max(0, now - growth - GROW_MS) / COOL_MS;
			front = 1 - Math.min(1, cooling);
			if (cooling >= 1) growth = null;
			busy = true;
		}
		const alight = [];
		for (let k = waves.length - 1; k >= 0; k--) {
			const wave = waves[k];
			const elapsed = now - wave.at;
			const edge = elapsed * WAVE_SPEED;
			if (edge - WAVE_BAND > wave.reach) {
				waves.splice(k, 1);
				continue;
			}
			// A short swell at the start, so a wave arrives instead of popping on.
			alight.push({ slot: wave.slot, edge, reach: wave.reach, strength: wave.peak * Math.min(1, elapsed / 90) });
			busy = true;
		}
		const running = [];
		for (let k = runs.length - 1; k >= 0; k--) {
			const run = runs[k];
			const head = run.speed * surged(now - run.at);
			// A run is alight until it has run off the end of its thread and its
			// trail has followed.
			if (head - run.length > TRAIL) {
				runs.splice(k, 1);
				continue;
			}
			running.push({ slot: run.slot, head, running: head < run.length });
			busy = true;
		}
		renderer.light(lightSheet(), { mouse, hover, upTo, front, waves: alight, runs: running }, colors.light, scale);
		if (busy) frameId = requestAnimationFrame(frame);
	};

	const rebuild = (animate: boolean) => {
		cancelAnimationFrame(frameId);
		frameId = 0;
		size = { w: innerWidth, h: innerHeight };
		for (const l of [mid, light]) fit(l);
		fit(near, PARALLAX);
		planes = PLANES.map((p) => grow(size.w * p.grown, size.h * p.grown, p.fuzz));
		focus = planes[FOCUS];
		links = null;
		waves.length = 0;
		runs.length = 0;
		renderer?.load(planes, FOCUS);
		// A new size can cross a width where the tokens change.
		colors = readColors(document.body, COLORS) ?? colors;
		if (animate) {
			growth = performance.now();
			wake();
		} else {
			growth = null;
			paint();
		}
	};

	// Grow the network already there in again, from nothing.
	const replay = () => {
		cancelAnimationFrame(frameId);
		frameId = 0;
		drawPlanes(planes.map(() => -1));
		waves.length = 0;
		runs.length = 0;
		growth = performance.now();
		wake();
	};

	// A point toward the edges of the window, away from the reading, on a
	// thread at least `minWidth` wide. -1 if none turned up.
	const outskirt = (net: Network, minWidth: number): number => {
		for (let tries = 0; tries < 60; tries++) {
			const i = Math.floor(Math.random() * net.count);
			const x = net.x[i];
			const y = net.y[i];
			const dx = (x - size.w * READING.x) / (size.w / 2);
			const dy = (y - size.h * READING.y) / (size.h / 2);
			const inside = x >= 0 && y >= 0 && x <= size.w && y <= size.h;
			if (inside && dx * dx + dy * dy > OUTSKIRT && net.width[i] >= minWidth && net.hair[i] === 0) return i;
		}
		return -1;
	};

	// The slot a new light takes: a free one, or the oldest light's, which it
	// then replaces.
	const slotFor = (lights: { slot: number }[], slots: number): number => {
		for (let slot = 0; slot < slots; slot++) if (!lights.some((l) => l.slot === slot)) return slot;
		return lights.shift()!.slot;
	};

	const startWave = (net: Network, from: number, reach: number, peak: number) => {
		if (renderer === null) return;
		links ??= linksOf(net);
		const slot = slotFor(waves, WAVE_SLOTS);
		renderer.setWave(slot, waveAlong(net, links, from, reach));
		waves.push({ slot, at: performance.now(), reach, peak });
		wake();
	};

	const pulse = () => {
		if (!lively() || renderer === null) return;
		const net = focus!;
		const end = outskirt(net, RUN_WIDTH);
		if (end < 0 || net.reach[end] < RUN.shortest) return;
		const path = runAlong(net, end, RUN.length);
		const slot = slotFor(runs, RUN_SLOTS);
		if (!renderer.setRun(slot, path.threads)) return;
		const [slow, fast] = RUN.speed;
		const speed = slow + Math.random() * (fast - slow);
		runs.push({ slot, at: performance.now(), speed, length: path.length });
		wake();
	};

	// A small wave that starts by itself, dimmer and shorter than one from a
	// touch. Seeing one is how a reader learns that touching makes one.
	const flicker = () => {
		if (!lively()) return;
		const from = outskirt(focus!, FLICKER_WIDTH);
		if (from >= 0) startWave(focus!, from, 220 + Math.random() * 160, 0.55);
	};

	const touch = (event: PointerEvent) => {
		if (!lively() || event.button > 0 || !onOpenGround(event.target)) return;
		const from = focus!.nearest(event.clientX, event.clientY);
		if (from >= 0) startWave(focus!, from, WAVE_REACH, 1);
	};

	const hover = (event: PointerEvent) => {
		if (event.pointerType !== "mouse" || !lively()) return;
		const now = performance.now();
		// Over content the light is left to fade where it was, and it rises
		// again, not all at once, when the mouse comes back to open ground.
		// The near plane holds still too, so reading never moves it.
		if (!onOpenGround(event.target)) {
			mouse.away = true;
			return;
		}
		if (mouse.away || now - mouse.at > LINGER) mouse.since = now;
		mouse.away = false;
		mouse.x = event.clientX;
		mouse.y = event.clientY;
		mouse.at = now;
		const dx = (mouse.x / size.w - 0.5) * 2;
		const dy = (mouse.y / size.h - 0.5) * 2;
		near.canvas.style.translate = `${-dx * PARALLAX}px ${-dy * PARALLAX}px`;
		wake();
	};

	// Life of its own: every few seconds a point of light runs, or a small
	// wave flickers, somewhere toward the edges.
	const scheduleAmbient = (delay = AMBIENT_MS[0] + Math.random() * (AMBIENT_MS[1] - AMBIENT_MS[0])) => {
		clearTimeout(ambient);
		ambient = setTimeout(() => {
			if (Math.random() < RUN_SHARE) pulse();
			else flicker();
			scheduleAmbient();
		}, delay);
	};

	let stopped = false;
	let arrival = options.arriving === true;
	try {
		arrival ||= sessionStorage.getItem(GROWN_KEY) === null;
		sessionStorage.setItem(GROWN_KEY, "1");
	} catch (_) {
		// tolerant: no storage means no memory of a first visit, so it never grows in
	}
	rebuild(arrival && !still.matches);
	scheduleAmbient(arrival ? GROW_MS + COOL_MS + 400 : 1200);

	// The threads fade in, then breathe very slowly. The compositor runs the
	// fades, so they cost no drawing. A fade is not motion, so it runs for
	// everyone. An arrival rises early and settles slowly, so the growth is
	// not spent in the dark.
	const rest = still.matches ? 1 : 0.82;
	const depths = [mid.canvas, near.canvas];
	// The fades that hold each shown canvas where it is, and the timer that
	// moves the breath once the threads are fully up.
	let fades: Animation[] = [];
	let breathing: ReturnType<typeof setTimeout> | undefined;
	let dimmed = false;
	// The near plane breathes half a breath behind, so the depths move apart,
	// and holds at rest until its breath begins. Each breath eases in and out.
	const breathe = (began: number) => {
		const half = BREATH_MS / 2;
		for (const canvas of depths) canvas.style.opacity = String(rest);
		for (const fade of fades.slice(0, depths.length)) fade.cancel();
		const step = () => {
			const now = performance.now();
			if (!document.hidden) {
				depths.forEach((canvas, k) => {
					const t = (now - began) / half - k;
					if (t < 0) return;
					const x = Math.floor(t) % 2 === 0 ? t % 1 : 1 - (t % 1);
					canvas.style.opacity = String(rest + ((1 - rest) * (1 - Math.cos(Math.PI * x))) / 2);
				});
			}
			breathing = setTimeout(step, BREATH_STEP_MS);
		};
		step();
	};
	// Each shown canvas fades from `from` to `level` of its full light.
	const fadeTo = (from: readonly (number | string)[], level: number, timing: KeyframeAnimationOptions) => {
		const full = [rest, rest, 1];
		fades = shown.map(({ canvas }, k) =>
			canvas.animate([{ opacity: from[k] }, { opacity: full[k] * level }], { ...timing, fill: "forwards" })
		);
		const mine = fades;
		mine[0].finished.then(() => {
			if (still.matches || stopped || dimmed || fades !== mine) return;
			breathe(performance.now());
		}, () => {
			// tolerant: a fade cancelled by stop(), dim(), or regrow() leaves nothing to breathe
		});
	};
	// Stop every fade and the breath, and say where each canvas stood.
	const halt = () => {
		const from = shown.map(({ canvas }) => getComputedStyle(canvas).opacity);
		for (const a of fades) a.cancel();
		clearTimeout(breathing);
		return from;
	};
	const arriving = {
		duration: ARRIVE_MS,
		easing: "cubic-bezier(.25, .5, .3, 1)",
	};
	fadeTo(
		[0, 0, 0],
		1,
		arrival ? arriving : { duration: RETURN_MS, easing: "cubic-bezier(.4, 0, .2, 1)" },
	);

	const dim = () => {
		if (dimmed || stopped) return;
		dimmed = true;
		clearTimeout(ambient);
		fadeTo(halt(), DIM, { duration: DIM_MS, easing: "cubic-bezier(.4, 0, .2, 1)" });
	};

	const regrow = () => {
		if (!dimmed || stopped) return;
		dimmed = false;
		const from = halt();
		const growing = lively();
		if (growing) replay();
		fadeTo(from, 1, arriving);
		scheduleAmbient(growing ? GROW_MS + COOL_MS + 400 : 1200);
	};

	let resizing: ReturnType<typeof setTimeout> | undefined;
	const onResize = () => {
		clearTimeout(resizing);
		resizing = setTimeout(() => {
			if (innerWidth !== size.w || Math.abs(innerHeight - size.h) > RESIZE_SLACK) rebuild(false);
		}, RESIZE_QUIET);
	};
	const recolor = () => {
		colors = readColors(document.body, COLORS) ?? colors;
		if (growth === null) paint();
	};
	const themes = new MutationObserver(recolor);
	themes.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme", "class"] });
	addEventListener("resize", onResize);
	addEventListener("pointermove", hover, { passive: true });
	addEventListener("pointerdown", touch, { passive: true });

	return {
		pulse,
		dim,
		regrow,
		stop() {
			stopped = true;
			release();
			cancelAnimationFrame(frameId);
			for (const a of fades) a.cancel();
			clearTimeout(breathing);
			clearTimeout(ambient);
			clearTimeout(resizing);
			themes.disconnect();
			removeEventListener("resize", onResize);
			removeEventListener("pointermove", hover);
			removeEventListener("pointerdown", touch);
			for (const l of shown) l.canvas.remove();
			// The buffers are the threads' and go with them; the device is the
			// page's and stays.
			renderer?.destroy();
			renderer = null;
		},
	};
}
