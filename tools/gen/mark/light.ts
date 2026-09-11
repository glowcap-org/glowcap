// Where the light is, and what color it is.
//
// The lit and the unlit frames are the same pose on the same grid, so a pixel
// can be compared with itself. What the lamps add is the difference between
// the two, and cutting that difference high leaves the emissive cores alone:
// the four windows, and the line of light along the underside of the brim.
// That line is not a layer of the unlit drawing, so there is no way to reach
// it except by asking the light where it is.
//
// The color is measured the same way, off the pixels inside that cut, so the
// still lit mark is painted in the color the shader actually emits rather than
// a teal picked to look right.

import { area, contours, deviation, pathData, resampleByTurn, smooth, toCubics } from "./contour.ts";
import type { Read } from "./trace.ts";

/** How far above the unlit frame a pixel must sit to count as the light
 * itself rather than its spill. The lamps lift their own cores by about three
 * quarters, and the spill falls away smoothly from there, so a cut at half
 * takes the cores with none of the haze around them. */
const CORE_LIFT = 0.5;

/** The ground the two frames are compared over. Both are drawn with an alpha
 * channel, and a difference in coverage is not a difference in light, so each
 * is composited over the page's night before it is measured. */
const NIGHT: [number, number, number] = [0x21 / 255, 0x19 / 255, 0x11 / 255];

/** The fit the cores take. The brim's line is a few pixels tall at this
 * sampling, so the anchors run short and the smoothing is light; anything
 * smaller than `minArea` is a speck the cut caught at the edge of the
 * transition, not a lamp. */
const FIT = { minArea: 300, spacing: 1.1, turn: 0.38, soften: 2 };

export type Light = {
	/** Every emissive core as one evenodd path, in box units. */
	d: string;
	/** The color those cores emit, straight rather than over the ground. */
	core: string;
	/** How many separate lamps the cut found. */
	lamps: number;
	maxDev: number;
	/** How much brighter each pixel is with the lamps on, so a caller reading
	 * the body's own tones can leave out everything the light touched. */
	lift: Float32Array;
};

const luminance = (r: number, g: number, b: number) => 0.2126 * r + 0.7152 * g + 0.0722 * b;

/** One frame's luminance composited over the night ground. */
function overNight(shot: Read, i: number): number {
	const a = shot.alpha[i];
	return luminance(
		shot.rgb[i * 3] * a + NIGHT[0] * (1 - a),
		shot.rgb[i * 3 + 1] * a + NIGHT[1] * (1 - a),
		shot.rgb[i * 3 + 2] * a + NIGHT[2] * (1 - a),
	);
}

/** The light the lamps add, and the color they add it in. */
export function light(lit: Read, unlit: Read): Light {
	const { w, h } = lit;
	const lift = new Float32Array(w * h);
	const field = new Float32Array(w * h);
	for (let i = 0; i < w * h; i++) {
		lift[i] = overNight(lit, i) - overNight(unlit, i);
		field[i] = lift[i] - CORE_LIFT;
	}

	let r = 0, g = 0, b = 0, n = 0;
	for (let i = 0; i < w * h; i++) {
		if (field[i] < 0 || lit.alpha[i] < 0.5) continue;
		r += lit.rgb[i * 3];
		g += lit.rgb[i * 3 + 1];
		b += lit.rgb[i * 3 + 2];
		n++;
	}
	if (n === 0) throw new Error("the lit frame emits nothing; the lamps are off in the frame the generator asked for");
	const channel = (c: number) => Math.round(Math.min(1, Math.max(0, c / n)) * 255).toString(16).padStart(2, "0");

	const box = (p: { x: number; y: number }) => ({
		x: (p.x / w) * lit.view.w + lit.view.x,
		y: (p.y / h) * lit.view.h + lit.view.y,
	});
	const loops = contours(field, w, h, 0).filter((loop) => area(loop) >= FIT.minArea);
	loops.sort((a, c) => area(c) - area(a));
	let d = "";
	let maxDev = 0;
	for (const raw of loops) {
		const traced = raw.map(box);
		const anchors = resampleByTurn(smooth(traced, FIT.soften), FIT.spacing, FIT.turn);
		const cubics = toCubics(anchors);
		maxDev = Math.max(maxDev, deviation(traced, anchors, cubics));
		d += pathData(anchors, cubics);
	}
	return { d, core: "#" + channel(r) + channel(g) + channel(b), lamps: loops.length, maxDev, lift };
}
