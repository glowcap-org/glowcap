// How the mycelium grows. This file owns the threads as data: where each one
// starts, how it wanders, where it forks, and where it fuses with another.
// live.ts draws them.
//
// A handful of colonies sit past the edges of the window and send threads
// in. Each thread drifts around the direction it set out in, forks behind its
// tip, and stops where it meets a thread of another branch, fusing with it as
// hyphae do. A branch leaves at an angle and leans partway back alongside the
// thread it left. Then finer threads sprout from the ones that
// grew, and finer ones again from those, so the same shape repeats at three
// scales. Fine hairs wave off all of them, mostly short and a few long, so
// the colony looks furred. The seed is fixed per window size: every page in one window grows
// the same network, and a different window grows a different one.

/** How far a thread moves in one step, in CSS pixels. */
const STEP = 3.2;
/** The collision grid's cell size. A thread entering a cell another branch
 * already crossed has met that branch. */
const CELL = 6;
/** Steps a new branch grows before it can meet anything, so it does not fuse
 * straight back into the thread it left. */
const FREE_STEPS = 5;
/** Chance per step that a thread forks. */
const FORK_CHANCE = 0.04;
/** Chance a thread that meets another fuses with it rather than crossing. */
const FUSE_CHANCE = 0.8;
/** Chance per step that a thread puts out a side hair. */
const HAIR_CHANCE = 0.07;
/** One hair of fuzz offered for this many square pixels of window. */
const FUZZ_AREA = 80;
/** How many steps a hair of fuzz grows, at least and at most. Aerial hyphae
 * are mostly a short pile, with a few rising well clear to wave, so lengths
 * gather near the shortest and thin out toward the longest. */
const FUZZ_SHORTEST = 2;
const FUZZ_LONGEST = 12;
/** One of the finest threads for this many square pixels, on a plane drawn
 * close enough to show them, and half as many on one drawn too small to. */
const FINEST_AREA = 1100;
/** The share of offered fuzz a point at its colony keeps. The share rises to
 * all of it at the farthest point, the colony's margin. */
const FUZZ_AT_COLONY = 0.3;
/** Every thread is at least this wide. Thinner lines only lose alpha. */
const MIN_WIDTH = 0.3;
/** How far past the window threads may grow, so none starts at the edge. */
const MARGIN = 220;
/** How far past the window a colony sits at least. Its first threads leave
 * it as a fan from one point, which would read as a star rather than a
 * colony, so the window only ever meets them once they have spread. */
const COLONY_CLEARANCE = 70;
/** How far a branch turns back toward the thread it left. A hypha branches
 * off at an angle, then grows on alongside its parent, so a colony's threads
 * sweep outward together rather than standing off like twigs. */
const BRANCH_SETTLE = 0.3;
/** How far the finest threads settle. In a mat they run nearly alongside the
 * threads they leave, rather than standing off as stubs. */
const FINEST_SETTLE = 0.5;
/** How far a hair curls forward per step as it leaves, in radians, and how
 * much its course wanders per step after. An aerial hypha waves as it rises
 * and leans the way its colony grows. */
const HAIR_CURL = 0.1;
const HAIR_WANDER = 0.15;

/** Where the reading sits in the window, as fractions of its width and
 * height. Threads grow toward it and the light keeps away from it. */
export const READING = { x: 0.5, y: 0.44 };

/** Every point a thread passed through, in growth order, each with the point
 * before it on its thread. */
export interface Network {
	count: number;
	x: Float32Array;
	y: Float32Array;
	width: Float32Array;
	/** 1 where the point is on a hair, the fuzz standing off a thread. */
	hair: Uint8Array;
	/** The point before this one on its thread, or -1 at a colony. */
	parent: Int32Array;
	/** The growth step that reached this point. */
	born: Int32Array;
	/** How far this point lies along its threads from the colony. */
	reach: Float32Array;
	/** Where a thread fused into another, the point it joined, or -1. */
	join: Int32Array;
	/** The last growth step. */
	steps: number;
	/** The point nearest (x, y) within about 30 pixels, or -1. */
	nearest(x: number, y: number): number;
}

interface Tip {
	x: number;
	y: number;
	angle: number;
	/** The direction the thread set out in. It keeps drifting back toward
	 * it, so a thread wanders without ever coiling. */
	heading: number;
	turn: number;
	width: number;
	life: number;
	age: number;
	line: number;
	node: number;
	/** The growth step of the point it set out from. */
	start: number;
	hair: boolean;
}

function random(seed: number): () => number {
	let s = seed >>> 0;
	return () => {
		s = (s + 0x6d2b79f5) >>> 0;
		let t = s;
		t = Math.imul(t ^ (t >>> 15), t | 1);
		t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
}

/** Grow the whole network for a window of `w` by `h` CSS pixels. Without
 * `fuzz` it skips the last pass of hairs and thins the finest threads, for a
 * plane drawn too small to show them. */
export function grow(w: number, h: number, fuzz: boolean): Network {
	const rand = random(0x91c0ffee ^ Math.round(w) * 2654435761 ^ Math.round(h));
	const gauss = () => (rand() + rand() + rand() - 1.5) * 0.8;
	const budget = Math.round((w * h) / 3);
	const capacity = budget + 4096;
	const cols = Math.ceil((w + 2 * MARGIN) / CELL) + 1;
	const rows = Math.ceil((h + 2 * MARGIN) / CELL) + 1;
	const grid = new Int32Array(cols * rows);
	const cellOf = (x: number, y: number) => Math.floor((y + MARGIN) / CELL) * cols + Math.floor((x + MARGIN) / CELL);
	const net: Network = {
		count: 0,
		x: new Float32Array(capacity),
		y: new Float32Array(capacity),
		width: new Float32Array(capacity),
		hair: new Uint8Array(capacity),
		parent: new Int32Array(capacity),
		born: new Int32Array(capacity),
		reach: new Float32Array(capacity),
		join: new Int32Array(capacity).fill(-1),
		steps: 0,
		nearest(x, y) {
			let best = -1;
			let bestDistance = Infinity;
			const cx = Math.floor((x + MARGIN) / CELL);
			const cy = Math.floor((y + MARGIN) / CELL);
			for (let dy = -5; dy <= 5; dy++) {
				for (let dx = -5; dx <= 5; dx++) {
					const gx = cx + dx;
					const gy = cy + dy;
					if (gx < 0 || gy < 0 || gx >= cols || gy >= rows) continue;
					const i = grid[gy * cols + gx] - 1;
					if (i < 0) continue;
					const d = Math.hypot(net.x[i] - x, net.y[i] - y);
					if (d < bestDistance) [best, bestDistance] = [i, d];
				}
			}
			return best;
		},
	};
	// Which thread each point is on, so a thread never fuses with itself. Only
	// growth reads it, so the reordering at the end leaves it behind.
	const lineOf = new Int32Array(capacity);

	const add = (x: number, y: number, t: Pick<Tip, "width" | "line" | "hair">, parent: number, step: number) => {
		const i = net.count++;
		net.x[i] = x;
		net.y[i] = y;
		net.width[i] = t.width;
		net.hair[i] = t.hair ? 1 : 0;
		net.parent[i] = parent;
		net.born[i] = step;
		net.reach[i] = parent < 0 ? 0 : net.reach[parent] + Math.hypot(x - net.x[parent], y - net.y[parent]);
		lineOf[i] = t.line;
		return i;
	};

	let nextLine = 0;
	let tips: Tip[] = [];
	const tip = (node: number, angle: number, width: number, life: number, hair = false): Tip => ({
		x: net.x[node],
		y: net.y[node],
		angle,
		heading: angle,
		turn: 0,
		width,
		life,
		age: 0,
		line: nextLine++,
		node,
		start: net.born[node],
		hair,
	});

	// A branch leaves at its own angle and settles toward the thread it left.
	const branch = (t: Tip, from: number, settle: number): Tip => {
		t.heading = from + (t.angle - from) * (1 - settle);
		return t;
	};
	// A hair curls forward, toward the way its thread grows, and settles
	// leaning that way as a branch does. Each curls and leans its own amount,
	// so some stand straight out and some lie close, and a mat never reads as
	// combed.
	const curl = (t: Tip, from: number): Tip => {
		t.turn = Math.sign(from - t.angle) * HAIR_CURL * (0.3 + rand() * 1.4);
		return branch(t, from, BRANCH_SETTLE * rand() * 1.6);
	};

	// Colonies sit past the edges, one in each lower corner and one high on
	// each side, with a fifth below the fold on wide windows. Each sends a fan
	// of threads toward the middle of the window. A colony wanders along its
	// edge, and away from the window but never toward it.
	const diagonal = Math.hypot(w, h);
	const colonies: Array<[number, number]> = [[-0.04, 1.06], [1.05, 0.92], [-0.06, 0.18], [1.04, 0.08]];
	if (w > 900) colonies.push([0.52, 1.1]);
	for (const [cx, cy] of colonies) {
		const past = (at: number, size: number) => {
			const jitter = gauss() * 30;
			if (at < 0) return Math.min(at * size, -COLONY_CLEARANCE) - Math.abs(jitter);
			if (at > 1) return Math.max(at * size, size + COLONY_CLEARANCE) + Math.abs(jitter);
			return at * size + jitter;
		};
		const x = past(cx, w);
		const y = past(cy, h);
		const root = add(x, y, { width: 1.1, line: nextLine++, hair: false }, -1, 0);
		const toward = Math.atan2(h * READING.y - y, w * READING.x - x);
		const spokes = 9 + Math.floor(rand() * 6);
		for (let k = 0; k < spokes; k++) {
			const fan = (k / (spokes - 1) - 0.5) * 2.6 + gauss() * 0.12;
			tips.push(tip(root, toward + fan, 0.75 + rand() * 0.35, (diagonal * (0.45 + rand() * 0.55)) / STEP));
		}
	}

	const run = () => {
		while (tips.length > 0 && net.count < budget) {
			const next: Tip[] = [];
			for (const t of tips) {
				if (net.count >= budget) break;
				t.turn = t.turn * 0.9 + gauss() * (t.hair ? HAIR_WANDER : 0.016);
				t.angle += t.turn + gauss() * (t.hair ? 0.12 : 0.035) + (t.heading - t.angle) * 0.02;
				t.x += Math.cos(t.angle) * STEP;
				t.y += Math.sin(t.angle) * STEP;
				t.width = Math.max(MIN_WIDTH, t.width * 0.999);
				t.life--;
				t.age++;
				if (t.x < -MARGIN || t.y < -MARGIN || t.x > w + MARGIN || t.y > h + MARGIN) continue;
				// A thread's points are timed from where it set out, so a fork,
				// a finer thread, or a hair grows in with the thread it stands on.
				const step = t.start + t.age;
				const node = add(t.x, t.y, t, t.node, step);
				t.node = node;
				if (!t.hair) {
					const cell = cellOf(t.x, t.y);
					const met = grid[cell] - 1;
					grid[cell] = node + 1;
					if (met >= 0 && lineOf[met] !== t.line && t.age > FREE_STEPS && rand() < FUSE_CHANCE) {
						// Join the thread it met, unless that point lies behind it,
						// where a joining stroke would fold back into a hook.
						const ahead = (net.x[met] - t.x) * Math.cos(t.angle) + (net.y[met] - t.y) * Math.sin(t.angle);
						if (ahead > 0) net.join[add(net.x[met], net.y[met], t, node, step)] = met;
						continue;
					}
				}
				if (t.life <= 0) continue;
				next.push(t);
				if (t.hair) continue;
				if (rand() < FORK_CHANCE) {
					const angle = t.angle + (rand() < 0.5 ? -1 : 1) * (0.35 + rand() * 0.5);
					next.push(
						branch(
							tip(
								node,
								angle,
								Math.max(MIN_WIDTH, t.width * (0.75 + rand() * 0.15)),
								t.life * (0.55 + rand() * 0.45),
							),
							t.angle,
							BRANCH_SETTLE,
						),
					);
				}
				// Side hairs: short and curling, so a thread reads as living
				// rather than drawn.
				if (rand() < HAIR_CHANCE) {
					const angle = t.angle + (rand() < 0.5 ? -1 : 1) * (0.5 + rand() * 0.6);
					next.push(curl(tip(node, angle, MIN_WIDTH, 2 + rand() * 5, true), t.angle));
				}
			}
			tips = next;
		}
	};
	run();

	// Finer threads sprout from the ones already grown, into the spaces
	// between, the way a colony fills in behind its front. Each pass sprouts
	// from everything before it, shorter and thinner than the last.
	const sprout = (
		{ count, minWidth, shortest, longest, width, settle }: {
			count: number;
			minWidth: number;
			shortest: number;
			longest: number;
			width: number;
			settle: number;
		},
	) => {
		const grown = net.count;
		for (let f = 0; f < count; f++) {
			const i = 1 + Math.floor(rand() * (grown - 1));
			const p = net.parent[i];
			if (p < 0 || net.width[i] < minWidth) continue;
			const along = Math.atan2(net.y[i] - net.y[p], net.x[i] - net.x[p]);
			const angle = along + (rand() < 0.5 ? -1 : 1) * (0.35 + rand() * 0.5);
			tips.push(
				branch(
					tip(i, angle, width * (0.8 + rand() * 0.4), (shortest + rand() * (longest - shortest)) / STEP),
					along,
					settle,
				),
			);
		}
		run();
	};
	sprout({
		count: Math.round((w * h) / 1800),
		minWidth: 0.4,
		shortest: 40,
		longest: 260,
		width: 0.42,
		settle: BRANCH_SETTLE,
	});
	sprout({
		count: Math.round((w * h) / (fuzz ? FINEST_AREA : 2 * FINEST_AREA)),
		minWidth: MIN_WIDTH,
		shortest: 15,
		longest: 90,
		width: 0.32,
		settle: FINEST_SETTLE,
	});
	// Last, the fuzz: short hairs standing off the threads, so up close every
	// thread is furred and no line reads as drawn. A colony is most alive at
	// its margin, so the further a point lies from its colony, the more hairs
	// it gets.
	if (fuzz) {
		const grown = net.count;
		let farthest = 1;
		for (let i = 0; i < grown; i++) farthest = Math.max(farthest, net.reach[i]);
		for (let f = Math.round((w * h) / FUZZ_AREA); f > 0; f--) {
			const i = 1 + Math.floor(rand() * (grown - 1));
			const p = net.parent[i];
			const keep = FUZZ_AT_COLONY + (1 - FUZZ_AT_COLONY) * (net.reach[i] / farthest);
			if (p < 0 || rand() > keep) continue;
			const along = Math.atan2(net.y[i] - net.y[p], net.x[i] - net.x[p]);
			tips.push(
				curl(
					tip(
						i,
						along + (rand() < 0.5 ? -1 : 1) * (0.5 + rand() * 0.9),
						MIN_WIDTH,
						FUZZ_SHORTEST + rand() * rand() * (FUZZ_LONGEST - FUZZ_SHORTEST),
						true,
					),
					along,
				),
			);
		}
		run();
	}
	inGrowthOrder(net, grid);
	return net;
}

/** Put the points in the order they grew, so a range of steps is a range of
 * indexes, and point every reference at the new places. Threads grow from
 * many starts at once, so they are not added in that order. */
function inGrowthOrder(net: Network, grid: Int32Array) {
	const n = net.count;
	// Steps are small whole numbers, so a count of each places every point
	// in one pass, keeping points of one step in the order they were added.
	let last = 0;
	for (let i = 0; i < n; i++) last = Math.max(last, net.born[i]);
	const before = new Int32Array(last + 2);
	for (let i = 0; i < n; i++) before[net.born[i] + 1]++;
	for (let b = 1; b < before.length; b++) before[b] += before[b - 1];
	const place = new Int32Array(n);
	const order = new Int32Array(n);
	for (let i = 0; i < n; i++) {
		const k = before[net.born[i]]++;
		place[i] = k;
		order[k] = i;
	}
	const moved = (i: number) => (i < 0 ? i : place[i]);
	const permute = <T extends Float32Array | Int32Array | Uint8Array>(values: T, map = (v: number) => v) => {
		const old = values.slice(0, n);
		for (let k = 0; k < n; k++) values[k] = map(old[order[k]]);
	};
	permute(net.x);
	permute(net.y);
	permute(net.width);
	permute(net.hair);
	permute(net.born);
	permute(net.reach);
	permute(net.parent, moved);
	permute(net.join, moved);
	for (let c = 0; c < grid.length; c++) if (grid[c] > 0) grid[c] = place[grid[c] - 1] + 1;
	net.steps = last;
}

/** Each point's neighbors along its threads (its parent, its children, and
 * the point it fused with) as one flat list: `list[start[i]]` through
 * `list[start[i + 1] - 1]`. */
export interface Links {
	start: Int32Array;
	list: Int32Array;
}

export function linksOf(net: Network): Links {
	const degree = new Int32Array(net.count + 1);
	const edges = (visit: (a: number, b: number) => void) => {
		for (let i = 0; i < net.count; i++) {
			if (net.parent[i] >= 0) visit(i, net.parent[i]);
			if (net.join[i] >= 0) visit(i, net.join[i]);
		}
	};
	edges((a, b) => {
		degree[a]++;
		degree[b]++;
	});
	const start = new Int32Array(net.count + 1);
	for (let i = 0; i < net.count; i++) start[i + 1] = start[i] + degree[i];
	const fill = start.slice(0, net.count);
	const list = new Int32Array(start[net.count]);
	edges((a, b) => {
		list[fill[a]++] = b;
		list[fill[b]++] = a;
	});
	return { start, list };
}

/** The first point grown at or after `step`. Points are stored in growth
 * order, so a range of steps is a range of indexes. */
export function firstBorn(net: Network, step: number): number {
	return firstAtLeast(net.born, net.count, step);
}

/** The first index below `length` whose value is at least `value`, in values
 * sorted from least to most. */
export function firstAtLeast(values: ArrayLike<number>, length: number, value: number): number {
	let lo = 0;
	let hi = length;
	while (lo < hi) {
		const mid = (lo + hi) >>> 1;
		if (values[mid] < value) lo = mid + 1;
		else hi = mid;
	}
	return lo;
}
