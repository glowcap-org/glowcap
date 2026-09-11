// Marching squares on a scalar field, then a smooth closed cubic fit through
// what it finds.
//
// The field is sampled sub-pixel, so a traced edge is the render's own edge
// rather than a staircase of whole pixels. Anchors are placed by curvature as
// well as by length: an evenly spaced walk spends them on the long calm arcs
// and starves the tight turn where the cap meets the stalk, which is exactly
// where a rounded-off corner would show.

export type Pt = { x: number; y: number };

const dist = (a: Pt, b: Pt) => Math.hypot(a.x - b.x, a.y - b.y);

/** Every closed contour of `field` at the `iso` level, on a w by h grid, in
 * grid coordinates. */
export function contours(field: Float32Array, w: number, h: number, iso = 0.5): Pt[][] {
	const links = new Map<number, number[]>();
	const at = (x: number, y: number) => field[y * w + x];
	const lerp = (x0: number, y0: number, x1: number, y1: number): Pt => {
		const a = at(x0, y0);
		const b = at(x1, y1);
		const t = Math.abs(b - a) < 1e-9 ? 0.5 : (iso - a) / (b - a);
		return { x: x0 + (x1 - x0) * t, y: y0 + (y1 - y0) * t };
	};
	const pts: Pt[] = [];
	const idOf = new Map<string, number>();
	const edgePoint = (x0: number, y0: number, x1: number, y1: number): number => {
		const name = `${x0},${y0},${x1},${y1}`;
		const had = idOf.get(name);
		if (had !== undefined) return had;
		const id = pts.length;
		pts.push(lerp(x0, y0, x1, y1));
		idOf.set(name, id);
		return id;
	};
	const join = (a: number, b: number) => {
		if (!links.has(a)) links.set(a, []);
		if (!links.has(b)) links.set(b, []);
		links.get(a)!.push(b);
		links.get(b)!.push(a);
	};

	for (let y = 0; y < h - 1; y++) {
		for (let x = 0; x < w - 1; x++) {
			const tl = at(x, y) >= iso ? 1 : 0;
			const tr = at(x + 1, y) >= iso ? 2 : 0;
			const br = at(x + 1, y + 1) >= iso ? 4 : 0;
			const bl = at(x, y + 1) >= iso ? 8 : 0;
			const code = tl | tr | br | bl;
			if (code === 0 || code === 15) continue;
			const top = () => edgePoint(x, y, x + 1, y);
			const right = () => edgePoint(x + 1, y, x + 1, y + 1);
			const bottom = () => edgePoint(x, y + 1, x + 1, y + 1);
			const left = () => edgePoint(x, y, x, y + 1);
			switch (code) {
				case 1:
				case 14:
					join(left(), top());
					break;
				case 2:
				case 13:
					join(top(), right());
					break;
				case 3:
				case 12:
					join(left(), right());
					break;
				case 4:
				case 11:
					join(right(), bottom());
					break;
				case 6:
				case 9:
					join(top(), bottom());
					break;
				case 7:
				case 8:
					join(left(), bottom());
					break;
				case 5:
					join(left(), top());
					join(right(), bottom());
					break;
				case 10:
					join(top(), right());
					join(left(), bottom());
					break;
			}
		}
	}

	// Walk the links into closed loops.
	const seen = new Set<number>();
	const loops: Pt[][] = [];
	for (const start of links.keys()) {
		if (seen.has(start)) continue;
		const loop: Pt[] = [];
		let prev = -1;
		let cur = start;
		while (true) {
			seen.add(cur);
			loop.push(pts[cur]);
			const next = (links.get(cur) ?? []).find((n) => n !== prev && !seen.has(n));
			if (next === undefined) break;
			prev = cur;
			cur = next;
		}
		if (loop.length > 8) loops.push(loop);
	}
	return loops;
}

/** Twice the enclosed area of a closed polyline, unsigned. Small loops are how
 * a luminance cut shows where it grazes a transition, and they carry no shape,
 * so each mask drops them by area. */
export function area(loop: Pt[]): number {
	let a = 0;
	for (let i = 0; i < loop.length; i++) {
		const p = loop[i];
		const q = loop[(i + 1) % loop.length];
		a += p.x * q.y - q.x * p.y;
	}
	return Math.abs(a) / 2;
}

/** A light closed moving average. The render is anti-aliased, so a contour
 * carries a little pixel noise the surface it came from does not have. */
export function smooth(loop: Pt[], radius: number): Pt[] {
	if (radius < 1) return loop;
	const n = loop.length;
	return loop.map((_, i) => {
		let x = 0, y = 0, k = 0;
		for (let d = -radius; d <= radius; d++) {
			const p = loop[(i + d + n * 2) % n];
			x += p.x;
			y += p.y;
			k++;
		}
		return { x: x / k, y: y / k };
	});
}

/** Resample by curvature as well as length: an anchor lands whenever the walk
 * has covered `maxArc` or turned through `maxTurn` radians since the last. */
export function resampleByTurn(loop: Pt[], maxArc: number, maxTurn: number): Pt[] {
	const n = loop.length;
	const out: Pt[] = [loop[0]];
	let arc = 0;
	let turn = 0;
	for (let i = 1; i < n; i++) {
		const prev = loop[i - 1], cur = loop[i], next = loop[(i + 1) % n];
		arc += dist(prev, cur);
		const a1 = Math.atan2(cur.y - prev.y, cur.x - prev.x);
		const a2 = Math.atan2(next.y - cur.y, next.x - cur.x);
		let d = a2 - a1;
		while (d > Math.PI) d -= 2 * Math.PI;
		while (d < -Math.PI) d += 2 * Math.PI;
		turn += Math.abs(d);
		if (arc >= maxArc || turn >= maxTurn) {
			out.push(cur);
			arc = 0;
			turn = 0;
		}
	}
	// A hair-thin final span makes the closing tangent wild.
	if (out.length > 2 && dist(out[out.length - 1], out[0]) < maxArc * 0.35) out.pop();
	return out;
}

export type Cubic = { c1: Pt; c2: Pt; to: Pt };

/** A closed Catmull-Rom through the anchors, as cubic Beziers. The conversion
 * is exact, so the curve passes through every anchor and the path stays
 * something a person could open and nudge. */
export function toCubics(loop: Pt[]): Cubic[] {
	const n = loop.length;
	const at = (i: number) => loop[(i + n * 2) % n];
	const out: Cubic[] = [];
	for (let i = 0; i < n; i++) {
		const p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2);
		out.push({
			c1: { x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6 },
			c2: { x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6 },
			to: p2,
		});
	}
	return out;
}

const cubicAt = (p0: Pt, c: Cubic, t: number): Pt => {
	const u = 1 - t;
	const a = u * u * u, b = 3 * u * u * t, c2 = 3 * u * t * t, d = t * t * t;
	return {
		x: a * p0.x + b * c.c1.x + c2 * c.c2.x + d * c.to.x,
		y: a * p0.y + b * c.c1.y + c2 * c.c2.y + d * c.to.y,
	};
};

/** How far the fitted curve strays from the traced contour, in the contour's
 * own units. This is the number that says whether "as exact as possible" was
 * reached, and the generator refuses to write a drawing that has drifted past
 * its budget. */
export function deviation(loop: Pt[], anchors: Pt[], cubics: Cubic[]): number {
	let worst = 0;
	for (let i = 0; i < cubics.length; i++) {
		const from = anchors[i % anchors.length];
		for (let s = 0; s < 12; s++) {
			const sample = cubicAt(from, cubics[i], s / 12);
			let best = Infinity;
			for (const p of loop) {
				const d = dist(sample, p);
				if (d < best) best = d;
			}
			if (best > worst) worst = best;
		}
	}
	return worst;
}

/** Path data, rounded so the same trace always writes the same string. */
export function pathData(anchors: Pt[], cubics: Cubic[]): string {
	const f = (n: number) => String(Number(n.toFixed(2)));
	let d = `M${f(anchors[0].x)} ${f(anchors[0].y)}`;
	for (const c of cubics) {
		d += `C${f(c.c1.x)} ${f(c.c1.y)} ${f(c.c2.x)} ${f(c.c2.y)} ${f(c.to.x)} ${f(c.to.y)}`;
	}
	return d + "Z";
}
