/** The light by day: held at the mushroom, where by night it reaches out
 * as beams. Concatenated with the field, the light, and the scene, which it
 * calls into and which call it. */
export const DAY = `
// Over cream a glow reads by its colour and by following the thing it comes
// off, not by brightness: each window, and the light under the brim, is
// white at its heart and the lamps' cyan at its rim and in its spill. The
// strike is the windows flaring. Over the body it is screened on, so it
// lightens what it falls on and never darkens the rest. The dark page's
// pipeline never calls this.
fn dayLight(base: vec3f, id: f32, ro: vec3f, rd: vec3f, hit: f32, stroke: f32, lamps: Lamps, fr: Frame) -> vec3f {
	var col = base;
	var heart = 0.0;
	var fringe = 0.0;
	// The back window is behind the dome, and shows no light by day.
	for (var k = 0; k < 5; k = k + 1) {
		if (k == 3) { continue; }
		let w = poreWorld(k, fr.gCap, fr.squash, fr.bob, fr.detail);
		let d = length(cross(w - ro, rd)) / poreSize(k);
		heart = heart + exp(-d * d * 1.6);
		fringe = fringe + exp(-d * d * 0.45);
	}
	// The light under the brim follows the night's: it hangs from the
	// brim's edge the full width of it, white-hot at the two corners where
	// the edge meets the stalk, cyan a short way down the stalk's top and
	// further through the air beside it. It is the night's lit air, so it
	// keeps the air's beat and is gone at the strike. Below the brim is
	// measured as distance to the cap from below it, so nothing above the
	// brim is lit: on the stalk from its own surface, in the air from the
	// depth of the brim's front edge, and for the corners from the depth
	// of the stalk's axis, where a ray grazing the stalk is nearest it. In
	// the air it starts past the outline and never covers it, so the
	// outline keeps its shape, and there it tints the paper toward the
	// lamps' cyan, because cyan added to cream comes out white.
	let onBody = id >= 0.5;
	let airBeat = fr.gCap * clamp(fr.rays / 0.6, 0.0, 1.0);
	let below = toBody(select(ro + rd * dot(lamps.spill - ro, rd), ro + rd * hit, onBody), fr.bob, fr.detail);
	let toCap = capField(below, fr.cap, fr.squash, fr.detail);
	let capAbove = smoothstep(
		0.3,
		0.8,
		(capField(below - vec3f(0.0, 0.04, 0.0), fr.cap, fr.squash, fr.detail) - toCap) / 0.04,
	);
	let onStalk = smoothstep(-0.03, 0.03, toCap - stemField(below, fr.stem, fr.detail));
	let fall = select(max(toCap - fr.strokeW * 0.5, 0.0), max(toCap, 0.0), onBody);
	let underLit = capAbove * select(1.0 - stroke, onStalk, onBody) * airBeat;
	let underReach = fall / select(0.6, 0.4, onBody);
	let underFringe = exp(-underReach * underReach) * underLit;
	let axisT = -dot(ro.xz - vec2f(STEM_X, 0.0), rd.xz) / max(dot(rd.xz, rd.xz), 1e-4);
	let atAxis = toBody(ro + rd * axisT, fr.bob, fr.detail);
	let cornerCap = capField(atAxis, fr.cap, fr.squash, fr.detail);
	let cornerStem = stemField(atAxis, fr.stem, fr.detail);
	let corner = exp(-(cornerCap * cornerCap + cornerStem * cornerStem) / 0.04) * capAbove * airBeat;
	heart = heart + exp(-fall * fall / 0.01) * underLit * 0.15 + corner * 1.2;
	let strength = fr.lightPage * smoothstep(0.0, 0.3, fr.glow) * (1.0 + fr.flareMix * 1.5);
	if (id >= 0.5) {
		col = mix(min(col, vec3f(1.0)), fr.lamp, clamp(fringe * 0.6 * strength, 0.0, 0.6));
		col = mix(col, fr.lamp, clamp(underFringe * 0.85 * strength, 0.0, 0.85));
		col = mix(col, vec3f(1.0), clamp(heart * 1.4 * strength, 0.0, 1.0));
	} else {
		col = col + (vec3f(1.0) * heart * 0.9 + fr.lamp * fringe * 0.4) * strength;
		col = mix(col, fr.lamp, clamp(underFringe * 0.6 * strength, 0.0, 0.6) * (1.0 - stroke));
	}
	return col;
}
`;
