// The line mark, drawn as the rim band it is rather than as a stroke
// of even width.
//
// The shader's orange outline is a band whose thickness varies all the way
// round. That band is the region between the silhouette and the flesh inside
// it, so tracing both contours and filling between them carries the real
// widths instead of an average of them.
//
// A second band comes from the cap rendered with no stalk under it. Its lower
// edge is the brim across the whole span the stalk normally hides, so the
// drawing keeps the brim's organic bend and the cap reads as standing in
// front. The two bands are separate paths rather than subpaths of one, because
// the evenodd rule would punch each out of the other where they overlap.

import { type Fit, fitMask, type Read, RIM_CUT } from "./trace.ts";

/** The fit the bands take. Tighter than the filled layers' fit, because the
 * bend lives here and a heavier hand smooths it away. The loops are left in
 * the order the contour walk found them, since a band is not an outline with
 * holes and has no largest loop to lead with. */
const BAND: Fit = { minArea: 400, spacing: 1.4, turn: 0.4, soften: 2, sorted: false };

export type Bands = { full: string; cap: string; maxDev: number };

/** Both bands: the whole mark's, and the stalkless cap's. */
export function bands(mark: Read, cap: Read): Bands {
	const of = (shot: Read) => {
		const outer = new Float32Array(shot.w * shot.h);
		const inner = new Float32Array(shot.w * shot.h);
		for (let i = 0; i < shot.w * shot.h; i++) {
			outer[i] = shot.alpha[i] - 0.5;
			inner[i] = RIM_CUT - shot.lum[i];
		}
		const a = fitMask(shot, outer, BAND);
		const b = fitMask(shot, inner, BAND);
		return { d: a.d + b.d, maxDev: Math.max(a.maxDev, b.maxDev) };
	};
	const whole = of(mark);
	const stalkless = of(cap);
	return { full: whole.d, cap: stalkless.d, maxDev: Math.max(whole.maxDev, stalkless.maxDev) };
}
