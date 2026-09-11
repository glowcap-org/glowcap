// The four-tone trace: one render to four filled paths and the colors they are
// painted in.
//
// The unlit render is a cel drawing rather than a shaded one. Its luminance
// falls into four flat tones with near-empty gaps between them, so cutting it
// at three levels recovers the render's own layers instead of reducing it:
// the amber rim, the lit flesh, the shaded flesh, and the dark windows. Each
// layer is extracted at its own level, fitted as smooth closed cubics, and
// stacked back to front.
//
// The tones are measured off the render's core pixels rather than picked by
// eye, so the drawing and the shader agree on color without anyone deciding
// twice.

import { area, contours, deviation, pathData, type Pt, resampleByTurn, smooth, toCubics } from "./contour.ts";
import type { Frame, View } from "./capture.ts";

/** The luminance levels the four tones fall between. The gaps around them are
 * nearly empty, so a level anywhere inside a gap cuts the same shape; these sit
 * in the middle of each. */
export const RIM_CUT = 0.33;
const SHADE_CUT = 0.17;
const WINDOW_CUT = 0.095;

/** A frame read as straight color and coverage, plus the luminance every cut
 * is taken against. Outside the silhouette that luminance reads as bright, so
 * every "darker than" mask closes on the silhouette instead of leaking out
 * across the page. */
export type Read = {
	w: number;
	h: number;
	view: View;
	alpha: Float32Array;
	lum: Float32Array;
	rgb: Float32Array;
};

export function read(frame: Frame, view: View): Read {
	const { w, h, px } = frame;
	const alpha = new Float32Array(w * h);
	const lum = new Float32Array(w * h);
	const rgb = new Float32Array(w * h * 3);
	for (let i = 0; i < w * h; i++) {
		const a = px[i * 4 + 3] / 255;
		alpha[i] = a;
		if (a <= 0.0001) {
			lum[i] = 1;
			continue;
		}
		const r = px[i * 4] / 255 / a;
		const g = px[i * 4 + 1] / 255 / a;
		const b = px[i * 4 + 2] / 255 / a;
		rgb[i * 3] = r;
		rgb[i * 3 + 1] = g;
		rgb[i * 3 + 2] = b;
		lum[i] = a < 0.5 ? 1 : 0.2126 * r + 0.7152 * g + 0.0722 * b;
	}
	return { w, h, view, alpha, lum, rgb };
}

/** A pixel's layer, by the same cuts the masks are taken at. */
function layerAt(shot: Read, i: number): LayerName | null {
	if (shot.alpha[i] < 0.5) return null;
	const l = shot.lum[i];
	if (l > RIM_CUT) return "silhouette";
	if (l > SHADE_CUT) return "flesh";
	if (l > WINDOW_CUT) return "shade";
	return "windows";
}

export type LayerName = "silhouette" | "flesh" | "shade" | "windows";

export type Layer = {
	name: LayerName;
	d: string;
	fill: string;
	loops: number;
	anchors: number;
	maxDev: number;
};

export type Trace = {
	viewBox: View;
	layers: Layer[];
};

/** Where one mask's fit is allowed to sit: how small a loop is noise, how far
 * anchors may run, how sharp a turn forces one, and how hard the contour is
 * smoothed first. `sorted` puts the largest loop first, which is what a filled
 * layer wants so its outline leads and its holes follow. */
export type Fit = {
	minArea: number;
	spacing: number;
	turn: number;
	soften: number;
	sorted: boolean;
};

/** Grid coordinates to the shader's own box units. */
const toBox = (shot: Read) => (p: Pt): Pt => ({
	x: (p.x / shot.w) * shot.view.w + shot.view.x,
	y: (p.y / shot.h) * shot.view.h + shot.view.y,
});

/** Fit every loop of one mask into a single evenodd path, and report how far
 * the fit strays from the trace it came from. */
export function fitMask(
	shot: Read,
	field: Float32Array,
	fit: Fit,
): {
	d: string;
	loops: number;
	anchors: number;
	maxDev: number;
	bbox: { x0: number; y0: number; x1: number; y1: number };
} {
	const box = toBox(shot);
	const loops = contours(field, shot.w, shot.h, 0).filter((loop) => area(loop) >= fit.minArea);
	if (fit.sorted) loops.sort((a, b) => area(b) - area(a));
	const bbox = { x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity };
	let d = "";
	let maxDev = 0;
	let anchorCount = 0;
	for (const raw of loops) {
		const traced = raw.map(box);
		// Smoothing is per mask. The silhouette takes the lightest touch,
		// because a heavy hand eats the concave turn under the brim before the
		// anchors ever see it. The interior tone boundaries take more, because
		// each is a level drawn through a soft gradient and carries its noise.
		const anchors = resampleByTurn(smooth(traced, fit.soften), fit.spacing, fit.turn);
		const cubics = toCubics(anchors);
		maxDev = Math.max(maxDev, deviation(traced, anchors, cubics));
		anchorCount += anchors.length;
		for (const p of traced) {
			bbox.x0 = Math.min(bbox.x0, p.x);
			bbox.y0 = Math.min(bbox.y0, p.y);
			bbox.x1 = Math.max(bbox.x1, p.x);
			bbox.y1 = Math.max(bbox.y1, p.y);
		}
		d += pathData(anchors, cubics);
	}
	return { d, loops: loops.length, anchors: anchorCount, maxDev, bbox };
}

/** The mean color of a band's core, ignoring every pixel whose neighborhood
 * crosses into another band. A transition pixel is a blend of two tones, so
 * including it would report a color the render never paints. `skip` leaves out
 * more, which is how the lit reading asks for the body's own tone without the
 * light lying across it. */
export function coreColour(
	shot: Read,
	source: Read,
	want: LayerName,
	skip?: (i: number) => boolean,
): string {
	let r = 0, g = 0, b = 0, n = 0;
	for (let y = 2; y < shot.h - 2; y++) {
		for (let x = 2; x < shot.w - 2; x++) {
			const i = y * shot.w + x;
			if (layerAt(shot, i) !== want) continue;
			if (skip !== undefined && skip(i)) continue;
			let pure = true;
			for (let dy = -2; dy <= 2 && pure; dy++) {
				for (let dx = -2; dx <= 2; dx++) {
					if (layerAt(shot, i + dy * shot.w + dx) !== want) {
						pure = false;
						break;
					}
				}
			}
			if (!pure) continue;
			if (source.alpha[i] < 0.5) continue;
			r += source.rgb[i * 3];
			g += source.rgb[i * 3 + 1];
			b += source.rgb[i * 3 + 2];
			n++;
		}
	}
	if (n === 0) throw new Error(`the ${want} layer has no core pixels to measure a tone from`);
	const channel = (c: number) => Math.round(Math.min(1, Math.max(0, c / n)) * 255).toString(16).padStart(2, "0");
	return "#" + channel(r) + channel(g) + channel(b);
}

const fits: Record<LayerName, Fit> = {
	// The shade mask picks up hairline slivers where the transition band grazes
	// its level. They carry no shape, so they are dropped by area rather than
	// drawn: a sliver a fraction of a box unit across is noise at every size
	// the mark is set at.
	silhouette: { minArea: 400, spacing: 1.8, turn: 0.42, soften: 2, sorted: true },
	flesh: { minArea: 400, spacing: 1.8, turn: 0.42, soften: 2, sorted: true },
	shade: { minArea: 2200, spacing: 2.2, turn: 0.5, soften: 5, sorted: true },
	windows: { minArea: 600, spacing: 1.5, turn: 0.42, soften: 3, sorted: true },
};

/** The whole trace: four masks, four fitted paths, four measured tones, and
 * the frame the drawing needs. */
export function trace(shot: Read): Trace {
	const of = (name: LayerName): Float32Array => {
		const f = new Float32Array(shot.w * shot.h);
		for (let i = 0; i < shot.w * shot.h; i++) {
			f[i] = name === "silhouette"
				? shot.alpha[i] - 0.5
				: (name === "flesh" ? RIM_CUT : name === "shade" ? SHADE_CUT : WINDOW_CUT) - shot.lum[i];
		}
		return f;
	};
	const names: LayerName[] = ["silhouette", "flesh", "shade", "windows"];
	const fitted = names.map((name) => ({ name, ...fitMask(shot, of(name), fits[name]) }));
	const layers: Layer[] = fitted.map((f) => ({
		name: f.name,
		d: f.d,
		fill: coreColour(shot, shot, f.name),
		loops: f.loops,
		anchors: f.anchors,
		maxDev: f.maxDev,
	}));

	// The frame is the mark's own bounds with a tenth of a unit of air, kept in
	// the shader's own coordinates so the drawing and the render lie over each
	// other without a second mapping to get wrong.
	const bb = fitted[0].bbox;
	const down = (n: number) => Math.floor(n * 10) / 10;
	const up = (n: number) => Math.ceil(n * 10) / 10;
	const x = down(bb.x0 - 0.1);
	const y = down(bb.y0 - 0.1);
	const viewBox = {
		x,
		y,
		w: Number((up(bb.x1 + 0.1) - x).toFixed(1)),
		h: Number((up(bb.y1 + 0.1) - y).toFixed(1)),
	};
	return { viewBox, layers };
}
