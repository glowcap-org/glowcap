// The mycelium under the page: a network of fine threads grown behind the
// content of the Rooms page and the documentation site.
//
// It is grown, not tiled (ui/mycelium_network.ts owns the growth), so no two
// window sizes show the same network and nothing in it repeats.
// ui/mycelium_light.ts draws the threads and the light that moves through
// them, and ui/open_ground.ts says where the pointer is free to light them.
// This file owns the canvases and decides when the light runs.
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

/// <reference lib="dom" />

import { firstBorn, grow, type Links, linksOf, type Network, READING } from "./mycelium_network.ts";
import { onOpenGround } from "./open_ground.ts";
import {
	bundle,
	drawFront,
	drawRun,
	drawWave,
	pathOutward,
	type Run,
	spreadWave,
	stroke,
	type Wave,
	WAVE_REACH,
} from "./mycelium_light.ts";

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
const GROWN_KEY = "glowcap.mycelium.grown";
/** How far from the mouse threads light, in CSS pixels. */
const REACH = 160;
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
/** Most waves alight at once. A new one retires the oldest. */
const MAX_WAVES = 4;
/** Life of its own: the wait before the next run or flicker is between
 * these, in ms, and this share of them are runs. */
const AMBIENT_MS = [2200, 6000] as const;
const RUN_SHARE = 0.55;
/** A run of light: the shortest thread it runs on, how much of the thread it
 * covers, and its speed in pixels per ms, all in CSS pixels. */
const RUN = { shortest: 200, length: 900, speed: [0.22, 0.32] } as const;
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

/** The planes of threads, far to near. Each grows for a window `grown` times
 * the real one and is drawn shrunk to fit, so a far plane is finer and
 * denser and a near one is coarser. Only the middle plane carries light, the
 * way only one depth is in focus. The near plane has a canvas of its own,
 * kept to the edges of the window and moving a little against the pointer.
 * Safari ignores a canvas filter, so there the near plane is sharp. */
const PLANES = [
	{ grown: 1.5, alpha: 0.5, blur: 0, fuzz: false, near: false },
	{ grown: 1, alpha: 1, blur: 0, fuzz: true, near: false },
	{ grown: 0.5, alpha: 0.4, blur: 1.4, fuzz: true, near: true },
] as const;
const FOCUS = 1;

export interface Mycelium {
	/** Send a point of light along a thread. Ignored under reduced motion. */
	pulse(): void;
	/** Remove the canvases and stop every timer and listener. */
	stop(): void;
}

export interface MyceliumOptions {
	/** Treat this load as an arrival, whatever the tab has seen. A page that
	 * is opened rather than navigated to, as Rooms is, says so. */
	arriving?: boolean;
}

/** A canvas and its drawing context. */
interface Layer {
	canvas: HTMLCanvasElement;
	c: CanvasRenderingContext2D;
}

/** A canvas and its context. Null if the browser gives no 2D context. */
function canvasLayer(): Layer | null {
	const canvas = document.createElement("canvas");
	const c = canvas.getContext("2d");
	return c === null ? null : { canvas, c };
}

/** A canvas fixed under the content, reaching `bleed` CSS pixels past every
 * edge. `middle` is how much of it shows in the middle of the window, where
 * the reading is. Null if the browser gives no 2D context. */
function fixedLayer(name: string, middle: number, bleed = 0): Layer | null {
	const l = canvasLayer();
	if (l === null) return null;
	l.canvas.className = name;
	l.canvas.setAttribute("aria-hidden", "true");
	const style = l.canvas.style;
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
	return l;
}

/** Read a color token as the browser resolves it, `light-dark()` included. */
function resolve(probe: HTMLElement, token: string): string {
	probe.style.color = `var(${token})`;
	const color = getComputedStyle(probe).color;
	probe.style.color = "";
	return color;
}

export function startMycelium(options: MyceliumOptions = {}): Mycelium | null {
	const mid = fixedLayer("mycelium", 0.22);
	// Out of focus, it would only blur the reading, so none of it reaches the
	// middle of the window.
	const near = fixedLayer("mycelium-near", 0, PARALLAX);
	// Light draws the eye, so less of it reaches the text than of the threads.
	const light = fixedLayer("mycelium-light", 0.08);
	// The focal plane's threads in the light's color, kept off the page. The
	// light under the mouse is cut from it.
	const lit = canvasLayer();
	if (mid === null || near === null || light === null || lit === null) return null;
	const shown = [mid, near, light];
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
	let threadColor = "";
	let lightColor = "";
	let frameId = 0;
	let ambient: ReturnType<typeof setTimeout> | undefined;
	// The growth in progress on an arrival: when it began and how many points
	// of each plane are already drawn.
	let growth: { at: number; drawn: number[] } | null = null;
	const waves: Wave[] = [];
	const runs: Run[] = [];
	// Where the mouse last moved over open ground, when, since when it has
	// been there without leaving for content, and whether it has left.
	const mouse = { x: 0, y: 0, at: -Infinity, since: -Infinity, away: true };

	const fit = ({ canvas, c }: Layer, bleed = 0) => {
		canvas.width = Math.round((size.w + 2 * bleed) * scale);
		canvas.height = Math.round((size.h + 2 * bleed) * scale);
		c.setTransform(scale, 0, 0, scale, bleed * scale, bleed * scale);
		c.lineCap = "round";
	};

	// Points `first` up to `end` of plane `k`, onto its layer.
	const drawPlane = (k: number, first: number, end: number) => {
		const { grown, alpha, blur } = PLANES[k];
		const { c } = PLANES[k].near ? near : mid;
		c.save();
		c.scale(1 / grown, 1 / grown);
		// A filter ignores the transform, so the blur is in device pixels.
		if (blur > 0) c.filter = `blur(${blur * scale}px)`;
		stroke(c, bundle(planes[k], first, end), threadColor, { alpha });
		c.restore();
	};

	const paint = () => {
		if (focus === null) return;
		const bled = 2 * PARALLAX;
		for (const { c } of [mid, near, lit]) c.clearRect(-PARALLAX, -PARALLAX, size.w + bled, size.h + bled);
		planes.forEach((plane, k) => drawPlane(k, 0, plane.count));
		// Only real threads take the light under the mouse. Lit, the fuzz
		// would fill the disc it is cut to and show its shape.
		stroke(lit.c, bundle(focus, 0, focus.count), lightColor, { widen: 0.5, withHairs: false });
	};

	const lively = () => !still.matches && !document.hidden && focus !== null;
	const wake = () => {
		if (frameId === 0) frameId = requestAnimationFrame(frame);
	};

	// The light under the mouse, cut from the lit threads to a soft disc.
	// It goes first, because the cut clears everything else on the canvas.
	const drawHover = (c: CanvasRenderingContext2D, now: number): boolean => {
		const resting = now - mouse.at;
		if (resting >= LINGER) return false;
		const { x, y } = mouse;
		const fade = (1 - resting / LINGER) ** 3 * Math.min(1, (now - mouse.since) / RISE_MS);
		const side = REACH * 2;
		const sx = (x - REACH) * scale;
		const sy = (y - REACH) * scale;
		c.drawImage(lit.canvas, sx, sy, side * scale, side * scale, x - REACH, y - REACH, side, side);
		const disc = c.createRadialGradient(x, y, 0, x, y, REACH);
		disc.addColorStop(0, `rgb(0 0 0 / ${0.95 * fade})`);
		disc.addColorStop(0.45, `rgb(0 0 0 / ${0.5 * fade})`);
		disc.addColorStop(1, "transparent");
		c.globalCompositeOperation = "destination-in";
		c.fillStyle = disc;
		c.fillRect(0, 0, size.w, size.h);
		return true;
	};

	// One more frame of growth, every plane in step with the focal one.
	const drawGrowth = (c: CanvasRenderingContext2D, focus: Network, now: number) => {
		if (growth === null) return false;
		const t = Math.min(1, (now - growth.at) / GROW_MS);
		const upTo = Math.round((1 - (1 - t) ** 2) * focus.steps);
		const drawn = growth.drawn;
		planes.forEach((plane, k) => {
			const end = firstBorn(plane, Math.round((upTo / focus.steps) * plane.steps) + 1);
			drawPlane(k, drawn[k], end);
			drawn[k] = end;
		});
		const cooling = Math.max(0, now - growth.at - GROW_MS) / COOL_MS;
		drawFront(c, focus, upTo, 1 - Math.min(1, cooling), lightColor);
		if (cooling >= 1) {
			growth = null;
			// Growth drew the planes but not the lit threads the hover light is
			// cut from, so the whole network is painted once more.
			paint();
		}
		return true;
	};

	const frame = (now: number) => {
		frameId = 0;
		if (focus === null) return;
		const { c } = light;
		c.clearRect(0, 0, size.w, size.h);
		let busy = drawHover(c, now);
		c.globalCompositeOperation = "lighter";
		if (drawGrowth(c, focus, now)) busy = true;
		for (let k = waves.length - 1; k >= 0; k--) {
			if (drawWave(c, focus, waves[k], now, lightColor)) busy = true;
			else waves.splice(k, 1);
		}
		for (let k = runs.length - 1; k >= 0; k--) {
			if (drawRun(c, runs[k], now, lightColor)) busy = true;
			else runs.splice(k, 1);
		}
		c.globalCompositeOperation = "source-over";
		if (busy) frameId = requestAnimationFrame(frame);
	};

	const readColors = () => {
		threadColor = resolve(mid.canvas, "--mycelium");
		lightColor = resolve(light.canvas, "--mycelium-pulse");
	};

	const rebuild = (animate: boolean) => {
		cancelAnimationFrame(frameId);
		frameId = 0;
		size = { w: innerWidth, h: innerHeight };
		for (const l of [mid, light, lit]) fit(l);
		fit(near, PARALLAX);
		planes = PLANES.map((p) => grow(size.w * p.grown, size.h * p.grown, p.fuzz));
		focus = planes[FOCUS];
		links = null;
		waves.length = 0;
		runs.length = 0;
		readColors();
		if (animate) {
			growth = { at: performance.now(), drawn: PLANES.map(() => 0) };
			wake();
		} else {
			growth = null;
			paint();
		}
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

	const startWave = (net: Network, from: number, reach: number, peak: number) => {
		links ??= linksOf(net);
		waves.push(spreadWave(net, links, from, performance.now(), reach, peak));
		if (waves.length > MAX_WAVES) waves.shift();
		wake();
	};

	const pulse = () => {
		if (!lively()) return;
		const net = focus!;
		const end = outskirt(net, RUN_WIDTH);
		if (end < 0 || net.reach[end] < RUN.shortest) return;
		const [slow, fast] = RUN.speed;
		const speed = slow + Math.random() * (fast - slow);
		runs.push({ points: pathOutward(net, end, RUN.length), at: performance.now(), speed });
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
	let first = options.arriving === true;
	try {
		first ||= sessionStorage.getItem(GROWN_KEY) === null;
		sessionStorage.setItem(GROWN_KEY, "1");
	} catch (_) {
		// tolerant: no storage means no memory of a first visit, so it never grows in
	}
	rebuild(first && !still.matches);
	scheduleAmbient(first ? GROW_MS + COOL_MS + 400 : 1200);

	// The threads fade in, then breathe very slowly. The compositor runs both,
	// so they cost no drawing. A fade is not motion, so it runs for everyone.
	// An arrival rises early and settles slowly, so the growth is not spent
	// in the dark.
	const fade = {
		duration: first ? ARRIVE_MS : RETURN_MS,
		easing: first ? "cubic-bezier(.25, .5, .3, 1)" : "cubic-bezier(.4, 0, .2, 1)",
	};
	const rest = still.matches ? 1 : 0.82;
	const depths = [mid.canvas, near.canvas];
	const arrivals = [
		...depths.map((canvas) => canvas.animate([{ opacity: 0 }, { opacity: rest }], { ...fade, fill: "forwards" })),
		light.canvas.animate([{ opacity: 0 }, { opacity: 1 }], fade),
	];
	let breaths: Animation[] = [];
	arrivals[0].finished.then(() => {
		if (still.matches || stopped) return;
		// The near plane breathes half a breath behind, so the depths move
		// apart. Until it starts, the fade holds it at rest.
		breaths = depths.map((canvas, k) =>
			canvas.animate([{ opacity: rest }, { opacity: 1 }], {
				duration: BREATH_MS / 2,
				delay: k * (BREATH_MS / 2),
				direction: "alternate",
				iterations: Infinity,
				easing: "ease-in-out",
			})
		);
	}, () => {
		// tolerant: a fade cancelled by stop() leaves nothing to breathe
	});

	let resizing: ReturnType<typeof setTimeout> | undefined;
	const onResize = () => {
		clearTimeout(resizing);
		resizing = setTimeout(() => {
			if (innerWidth !== size.w || Math.abs(innerHeight - size.h) > RESIZE_SLACK) rebuild(false);
		}, RESIZE_QUIET);
	};
	const recolor = () => {
		readColors();
		if (growth === null) paint();
	};
	const themes = new MutationObserver(recolor);
	themes.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme", "class"] });
	addEventListener("resize", onResize);
	addEventListener("pointermove", hover, { passive: true });
	addEventListener("pointerdown", touch, { passive: true });

	return {
		pulse,
		stop() {
			stopped = true;
			cancelAnimationFrame(frameId);
			for (const a of [...arrivals, ...breaths]) a.cancel();
			clearTimeout(ambient);
			clearTimeout(resizing);
			themes.disconnect();
			removeEventListener("resize", onResize);
			removeEventListener("pointermove", hover);
			removeEventListener("pointerdown", touch);
			for (const l of shown) l.canvas.remove();
		},
	};
}
