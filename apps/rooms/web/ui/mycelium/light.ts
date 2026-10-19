// The light that moves through the mycelium, and where each kind of it falls.
// network.ts grows the threads, renderer.ts draws them and the light, and
// live.ts decides when each kind of light runs.
//
// Three kinds of light, each following the threads rather than the screen:
//
// - the growing front, where new threads glow as they extend and cool behind
// - a wave from a touch, spreading out along every thread at once and
//   fading with the distance it has traveled through the network
// - a single point of light running out along one thread
//
// This file lays out the light once, when it starts: how far along the
// threads a wave reaches each thread, and which threads a run follows. The
// shader reads those and the moment, and lights each thread from them.

import type { Links, Network } from "./network.ts";

/** How many growth steps behind the front still glow. */
export const FRONT = 18;
/** How fast a wave travels along the threads, in pixels per ms. */
export const WAVE_SPEED = 1.4;
/** How far through the network a wave from a touch reaches. */
export const WAVE_REACH = 720;
/** The width of the lit band at a wave's edge, in pixels of thread. */
export const WAVE_BAND = 150;
/** The share of the band, from its leading edge, over which the light rises
 * to its peak. A wave through living threads swells ahead and fades behind,
 * with no hard bright front. */
export const WAVE_RISE = 0.25;
/** How far along the threads a wave runs before it is at full strength. */
export const WAVE_START = 90;
/** The length of the trail behind a running point of light. */
export const TRAIL = 150;
/** The length of its brightest stretch, at the head. */
export const HEAD = 24;
/** Alpha steps the light is drawn in, so a wave's band and a run's trail
 * read as a few bright rings rather than a smear. */
export const LEVELS = 6;
/** How wide a hair is drawn. */
export const HAIR = 0.3;
/** How strongly a hair takes a wave's light, against its thread, and how wide
 * it is drawn lit. The light runs in the threads, as foxfire does, and the
 * fuzz around them stays mostly dark. */
export const HAIR_GLOW = 0.25;
export const HAIR_LIT = 0.4;

/** How far along the threads a wave from point `from` reaches each thread,
 * in pixels, indexed by the point that ends the thread (the one whose
 * `parent` starts it). -1 where it does not reach. A wave walks every way
 * along the threads, out along forks and back toward the colony, and first
 * arrival lights each thread. */
export function waveAlong(net: Network, links: Links, from: number, reach: number): Float32Array {
	// A tap lays out tens of thousands of points, so the walk keeps them in
	// flat arrays: each point's distance by index (-1 until reached), and the
	// points reached in the order they were, which is the walk's own queue.
	const far = new Float64Array(net.count).fill(-1);
	const order = new Int32Array(net.count);
	const came = new Int32Array(net.count);
	far[from] = 0;
	order[0] = from;
	let reached = 1;
	for (let q = 0; q < reached; q++) {
		const i = order[q];
		const d = far[i];
		for (let k = links.start[i]; k < links.start[i + 1]; k++) {
			const j = links.list[k];
			if (far[j] >= 0) continue;
			const dj = d + Math.hypot(net.x[j] - net.x[i], net.y[j] - net.y[i]);
			if (dj > reach) continue;
			far[j] = dj;
			order[reached] = j;
			came[reached] = i;
			reached++;
		}
	}
	// Each step of the walk crossed one thread, lit by the distance at its
	// far end. A step onto a fused point crosses no length, so it lights
	// nothing.
	const along = new Float32Array(net.count).fill(-1);
	for (let k = 1; k < reached; k++) {
		const i = order[k];
		const v = came[k];
		if (net.parent[i] === v) along[i] = far[i];
		else if (net.parent[v] === i) along[v] = far[i];
	}
	return along;
}

/** The threads a run of light follows: the last `reach` pixels of the thread
 * that ends at `to`, in the order they grew, so the light runs away from the
 * colony. Each thread is five numbers, its two ends and how far along the run
 * its far end lies. */
export interface RunPath {
	threads: Float32Array;
	/** How far the run is from end to end. */
	length: number;
}

export function runAlong(net: Network, to: number, reach: number): RunPath {
	const back: number[] = [];
	for (let i = to; i >= 0 && net.reach[to] - net.reach[i] < reach; i = net.parent[i]) back.push(i);
	back.reverse();
	const threads = new Float32Array(Math.max(0, back.length - 1) * 5);
	let walked = 0;
	for (let k = 1; k < back.length; k++) {
		const a = back[k - 1];
		const b = back[k];
		walked += Math.hypot(net.x[b] - net.x[a], net.y[b] - net.y[a]);
		threads.set([net.x[a], net.y[a], net.x[b], net.y[b], walked], (k - 1) * 5);
	}
	return { threads, length: walked };
}
