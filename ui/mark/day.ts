/** The light by day: held at the mushroom, where by night it reaches out
 * as beams. Concatenated with the field, the light, and the scene, which it
 * calls into and which call it. */
export const DAY = `
// Over cream a glow reads by its colour and by following the thing it comes
// off, not by brightness: each window is white at its heart and the lamps'
// cyan at its rim and in its spill. The strike is the windows flaring. Over
// the body it is screened on, so it lightens what it falls on and never
// darkens the rest. The outline takes little of the spill: on cream the line
// is what draws the mark, and a window's spill reaching the silhouette washes
// it out. A heart stays whole where it touches a line, or a window's rim
// shows the line in a dotted arc. The dark page's pipeline never calls this.
fn dayLight(base: vec3f, id: f32, ro: vec3f, rd: vec3f, line: f32, lamps: Lamps, fr: Frame) -> vec3f {
	var col = base;
	var heart = 0.0;
	var fringe = 0.0;
	// The back window is behind the dome, and shows no light by day.
	for (var k = 0; k < 5; k = k + 1) {
		if (k == 3) { continue; }
		let d = length(cross(lamps.window[k] - ro, rd)) / poreSize(k);
		// Four of its own sizes out, a window's fringe at the strike's height
		// is under a quarter of a level of the target. Most of the canvas is
		// that far from every window and skips the exponentials.
		if (d > 4.0) { continue; }
		heart = heart + exp(-d * d * 1.6);
		fringe = fringe + exp(-d * d * 0.45);
	}
	let strength = fr.lightPage * smoothstep(0.0, 0.3, fr.glow) * (1.0 + fr.flareMix * 1.5);
	fringe = fringe * (1.0 - 0.75 * line);
	if (id >= 0.5) {
		col = mix(min(col, vec3f(1.0)), fr.lamp, clamp(fringe * 0.6 * strength, 0.0, 0.6));
		col = mix(col, vec3f(1.0), clamp(heart * 1.4 * strength, 0.0, 1.0));
	} else {
		col = col + (vec3f(1.0) * heart * 0.9 + fr.lamp * fringe * 0.4) * strength;
	}
	return col;
}
`;
