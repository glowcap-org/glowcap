// The light in the air: what one lamp puts into the mist at a point, and the
// one halo that has a closed form.
//
// These are sampled by the scene's march. They know the windows' throw and
// size from the field, and nothing about the page, the beat, or the pixel.

/** The lamps, as WGSL. Concatenated between the field and the scene. */
export const LIGHT = `
/** The mist lit by a lamp, along one ray, in closed form.
 *
 * A small light in a uniform mist lights the air around it with the square
 * of the distance, and the eye sees the sum of that along its whole ray.
 * That sum has an exact answer, so the halo is not sampled at all: it is
 * the arctangent of where the ray passes the lamp, divided by how close it
 * passed. This is the glow that hangs round a street lamp on a wet night,
 * and it is what makes the lit air read as air rather than a soft brush. */
fn inscatter(ro: vec3f, rd: vec3f, near: f32, far: f32, lamp: vec3f) -> f32 {
	let oc = ro - lamp;
	let b = dot(oc, rd);
	let h = sqrt(max(dot(oc, oc) - b * b, 0.0009));
	return (atan((far + b) / h) - atan((near + b) / h)) / h;
}

/** The light that spills down from under the brim: one wide, short cone
 * from the chamber, pointing at the ground, lighting the mist over the
 * stalk and the pool it lands in. The same rules as a beam, opened out. */
fn spillAt(q: vec3f, origin: vec3f, mist: f32) -> f32 {
	let v = q - origin;
	let along = -v.y;
	if (along < -0.1) { return 0.0; }
	let across = length(v.xz);
	let tanA = across / (along + 1.0);
	let profile = exp(-tanA * tanA / 1.4);
	let d = (along + 0.3) / 1.5;
	let fall = exp(-d * 1.3) / (1.0 + d * d * 2.0);
	return profile * fall * mist * 0.42;
}

/** One window's beam, sampled at a point in the mist.
 *
 * A torch through a misting night is not a drawn wedge. It is a cone of
 * angles: bright near the axis and soft out to a wide skirt, with nothing
 * sharp anywhere across it, because the mist is what is lit and mist has no
 * edges. The apex sits a little behind the window so the beam leaves with a
 * width rather than from a point, and its near end is soft too: a cut plane
 * through the origin drew a straight edge at the base of every ray. Along
 * the axis the light is measured from a little behind the window, so it is
 * already on its way down at the window itself and there is no spike at the
 * apex, and then it is plainly dimmer with every unit it travels: the same
 * intensity all the way along is a bar, not light. Over the last two thirds
 * of its reach the cone tapers back toward its axis, the way a drawn ray
 * closes as it fades. It is brighter looked into than looked across, because
 * water droplets throw light forward. */
fn coneAt(q: vec3f, origin: vec3f, dir: vec3f, i: i32, mist: f32, rd: vec3f) -> f32 {
	let v = q - origin;
	let along = dot(v, dir);
	if (along < -0.3) { return 0.0; }
	let across = length(v - dir * along);
	let carry = poreThrow(i);
	let reach = (0.9 + carry * 1.8) * 2.4;
	let taper = 1.0 - smoothstep(reach * 0.3, reach, along);
	let tanA = across / ((along + poreSize(i) * 3.3) * mix(0.2, 1.0, taper) * poreSpread(i));
	let profile = exp(-tanA * tanA / 0.03) + 0.06 * exp(-tanA * tanA / 0.16);
	let d = (along + 0.6) / (0.7 + carry * 1.1);
	let fall = exp(-d * 1.1) / (1.0 + d * d * 2.2) * taper * smoothstep(-0.3, 0.12, along);
	// Henyey-Greenstein, mildly forward: the light comes down the beam and
	// the eye looks along the ray, so the alignment of the two is the phase.
	let mu = dot(dir, -rd);
	let g = 0.15;
	let phase = (1.0 - g * g) / pow(1.0 + g * g - 2.0 * g * mu, 1.5);
	return profile * fall * phase * mist * carry * (0.5 + poreSize(i) * 2.0) * 2.1;
}
`;
