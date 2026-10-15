// How the mycelium is drawn: the threads themselves, and the light that
// moves through them. ui/mycelium_network.ts grows the threads, and
// ui/mycelium.ts decides when each kind of light runs.
//
// Three kinds of light, each following the threads rather than the screen:
//
// - the growing front, where new threads glow as they extend and cool behind
// - a wave from a touch, spreading out along every thread at once and
//   fading with the distance it has traveled through the network
// - a single point of light running out along one thread

/// <reference lib="dom" />

import { firstAtLeast, firstBorn, type Links, type Network } from "./mycelium_network.ts";

/** How many growth steps behind the front still glow. */
const FRONT = 18;
/** How fast a wave travels along the threads, in pixels per ms. */
const WAVE_SPEED = 0.55;
/** How far through the network a wave from a touch reaches. */
export const WAVE_REACH = 720;
/** The width of the lit band at a wave's edge, in pixels of thread. */
const WAVE_BAND = 150;
/** How far along the threads a wave runs before it is at full strength. */
const WAVE_START = 90;
/** The length of the trail behind a running point of light. */
const TRAIL = 150;
/** The length of its brightest stretch, at the head. */
const HEAD = 24;
/** Alpha steps a fading stroke is quantized to, so a frame is a few calls. */
const LEVELS = 6;

/** Strokes for points `first` up to `end`, the threads grouped by width so
 * a whole network draws in a dozen calls, and the hairs apart from them. */
export interface Bundle {
	threads: Map<number, Path2D>;
	hairs: Path2D;
}

export function bundle(net: Network, first: number, end: number): Bundle {
	const threads = new Map<number, Path2D>();
	const hairs = new Path2D();
	for (let i = first; i < end; i++) {
		const p = net.parent[i];
		if (p < 0) continue;
		let path = hairs;
		if (net.hair[i] === 0) {
			const key = Math.round(net.width[i] * 8) / 8;
			path = threads.get(key) ?? new Path2D();
			threads.set(key, path);
		}
		segment(path, net, p, i);
	}
	return { threads, hairs };
}

/** Stroke a bundle, and its hairs unless `hairs` is false. `widen` thickens
 * every stroke, for the light, and `alpha` fades them all, for a plane
 * further from the eye. */
export function stroke(
	c: CanvasRenderingContext2D,
	{ threads, hairs }: Bundle,
	color: string,
	{ widen = 0, alpha = 1, withHairs = true } = {},
) {
	c.strokeStyle = color;
	const draw = (width: number, path: Path2D) => {
		c.lineWidth = width + widen;
		c.globalAlpha = alpha * Math.min(1, 0.35 + width * 0.5);
		c.stroke(path);
	};
	for (const [width, path] of threads) draw(width, path);
	if (withHairs) draw(HAIR, hairs);
	c.globalAlpha = 1;
}

/** How wide a hair is drawn. */
const HAIR = 0.3;

function segment(path: Path2D, net: Network, a: number, b: number) {
	path.moveTo(net.x[a], net.y[a]);
	path.lineTo(net.x[b], net.y[b]);
}

/** The alpha step for a strength from 0 to 1. */
function levelOf(strength: number): number {
	return Math.max(0, Math.min(LEVELS - 1, Math.floor(strength * LEVELS)));
}

function levels(): Path2D[] {
	return Array.from({ length: LEVELS }, () => new Path2D());
}

function strokeLevels(c: CanvasRenderingContext2D, paths: Path2D[], peak: number) {
	for (let l = 0; l < LEVELS; l++) {
		c.globalAlpha = (peak * (l + 1)) / LEVELS;
		c.stroke(paths[l]);
	}
	c.globalAlpha = 1;
}

/** The newest threads while the network grows in: brightest at the tips. */
export function drawFront(c: CanvasRenderingContext2D, net: Network, upTo: number, fade: number, color: string) {
	const first = firstBorn(net, upTo - FRONT);
	const end = firstBorn(net, upTo + 1);
	const paths = levels();
	for (let i = first; i < end; i++) {
		const p = net.parent[i];
		if (p < 0) continue;
		segment(paths[levelOf(1 - (upTo - net.born[i]) / FRONT)], net, p, i);
	}
	c.strokeStyle = color;
	c.lineWidth = 1.1;
	strokeLevels(c, paths, 0.5 * fade);
}

/** A wave of light from one point, laid out once: every point it reaches,
 * the neighbor it came from, and how far along the threads it is. */
export interface Wave {
	at: number;
	/** How far through the network it reaches before it is spent. */
	reach: number;
	/** How bright it starts. A touch is 1. */
	peak: number;
	node: Int32Array;
	via: Int32Array;
	far: Float32Array;
}

export function spreadWave(net: Network, links: Links, from: number, at: number, reach: number, peak: number): Wave {
	const far = new Map<number, number>([[from, 0]]);
	const order: number[] = [];
	const came: number[] = [];
	const queue = [from];
	for (let q = 0; q < queue.length; q++) {
		const i = queue[q];
		const d = far.get(i)!;
		for (let k = links.start[i]; k < links.start[i + 1]; k++) {
			const j = links.list[k];
			if (far.has(j)) continue;
			const dj = d + Math.hypot(net.x[j] - net.x[i], net.y[j] - net.y[i]);
			if (dj > reach) continue;
			far.set(j, dj);
			order.push(j);
			came.push(i);
			queue.push(j);
		}
	}
	const sorted = order.map((_, k) => k).sort((a, b) => far.get(order[a])! - far.get(order[b])!);
	return {
		at,
		reach,
		peak,
		node: Int32Array.from(sorted, (k) => order[k]),
		via: Int32Array.from(sorted, (k) => came[k]),
		far: Float32Array.from(sorted, (k) => far.get(order[k])!),
	};
}

/** Draw a wave's lit band. False once spent. */
export function drawWave(c: CanvasRenderingContext2D, net: Network, wave: Wave, now: number, color: string): boolean {
	const elapsed = now - wave.at;
	const edge = elapsed * WAVE_SPEED;
	if (edge - WAVE_BAND > wave.reach) return false;
	const paths = levels();
	const hairs = levels();
	const n = wave.far.length;
	const end = firstAtLeast(wave.far, n, edge);
	for (let k = firstAtLeast(wave.far, n, edge - WAVE_BAND); k < end; k++) {
		const d = wave.far[k];
		// Dark where it starts, so the light leaves the touch along the threads
		// and does not pool around it.
		const leaving = Math.min(1, d / WAVE_START);
		const strength = leaving * leaving * Math.sqrt(1 - d / wave.reach) * (1 - (edge - d) / WAVE_BAND);
		const i = wave.node[k];
		segment((net.hair[i] ? hairs : paths)[levelOf(strength)], net, wave.via[k], i);
	}
	c.strokeStyle = color;
	// A short swell at the start, so a wave arrives instead of popping on.
	const swell = wave.peak * Math.min(1, elapsed / 90);
	c.lineWidth = 1.4;
	strokeLevels(c, paths, swell);
	// The fuzz glows finer and fainter than the threads it stands on.
	c.lineWidth = 0.6;
	strokeLevels(c, hairs, swell * 0.55);
	return true;
}

/** A single point of light running along a list of points. */
export interface Run {
	points: Float32Array;
	at: number;
	speed: number;
}

/** The last `reach` pixels of the thread that ends at `to`, in the order
 * they grew, so the light runs away from the colony. */
export function pathOutward(net: Network, to: number, reach: number): Float32Array {
	const back: number[] = [];
	for (let i = to; i >= 0 && net.reach[to] - net.reach[i] < reach; i = net.parent[i]) back.push(i);
	const points = new Float32Array(back.length * 2);
	back.reverse().forEach((i, k) => {
		points[2 * k] = net.x[i];
		points[2 * k + 1] = net.y[i];
	});
	return points;
}

/** Draw one running point of light and its trail. False once it has run off
 * the end of its thread and its trail has followed. */
export function drawRun(c: CanvasRenderingContext2D, run: Run, now: number, color: string): boolean {
	const { points, at, speed } = run;
	const head = (now - at) * speed;
	const paths = levels();
	// The head is the last stretch of the trail, drawn again wider, so the
	// light is in the thread rather than a dot laid on it.
	const tip = new Path2D();
	let walked = 0;
	let headX = points[0];
	let headY = points[1];
	let running = false;
	for (let k = 2; k < points.length; k += 2) {
		const ax = points[k - 2];
		const ay = points[k - 1];
		walked += Math.hypot(points[k] - ax, points[k + 1] - ay);
		if (walked > head) {
			running = true;
			break;
		}
		headX = points[k];
		headY = points[k + 1];
		const behind = head - walked;
		if (behind > TRAIL) continue;
		const level = levelOf(1 - behind / TRAIL);
		paths[level].moveTo(ax, ay);
		paths[level].lineTo(headX, headY);
		if (behind < HEAD) {
			tip.moveTo(ax, ay);
			tip.lineTo(headX, headY);
		}
	}
	c.strokeStyle = color;
	c.lineWidth = 1.2;
	strokeLevels(c, paths, 0.85);
	if (running) {
		c.lineWidth = 2.2;
		c.globalAlpha = 0.6;
		c.stroke(tip);
		c.globalAlpha = 1;
		return true;
	}
	return head - walked <= TRAIL;
}
