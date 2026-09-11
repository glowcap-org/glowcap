// The mushroom as a distance field: its proportions, its two bodies, the
// frame the cap lives in, and the windows the light leaves by.
//
// Everything that asks where the mushroom is asks this file. The scene traces
// it, the lamps are seated by it, the outline is measured against it. That is
// the whole reason it is one file: a beam that placed its own cap once
// started beside its window instead of in it.

/** The field half of the scene shader. Module-scope WGSL declarations can
 * come in any order, so this concatenates ahead of the light and the entry
 * point with no forward declarations. */
export const FIELD = `
/* A big round bun on a short chubby stalk. Cute is proportion before it is
   anything else: the head is most of the character, the body is stubby, and
   nothing tapers to a point. */
const CAP_Y = 1.38;
const CAP_R = vec3f(1.6, 1.5, 1.5);
const STEM_TOP = 1.3;
/* The stalk stands left of the cap's centre. In the drawing that offset is
   most of the character: a mushroom centred under its own cap is a diagram. */
const STEM_X = -0.14;
/* How far the stalk's base dips below the floor at its axis: the depth of
   the ellipse that is a cylinder's bottom rim seen from a little above. The
   floor's pool projects to the same ellipse; the two move together. */
const STEM_DIP = 0.06;
/* And the cap sits over on a tilt, because nothing that grew is level. */
const TILT = 0.085;
/* The whole mushroom leans, as a shear that grows with height, so the foot
   stays flat on the ground and the lean reads as the thing growing crooked
   rather than the hat being on askew. */
const SWAY = 0.09;
/* The chamber under the brim, where the spill and its halo come from. */
const MOUTH = vec3f(0.0, 0.80, 0.0);
/* The frame. The flat mark is drawn in a 24-unit box that its silhouette
   fills, and its light leaves that box into the air around it. This drawing
   keeps that contract: BOX is how much of the world the box holds, so the
   mushroom fills the element it is given the way the masks do, and only the
   beams and the pool spill past it. The lens follows from BOX and the
   camera's distance, so the mushroom is the same size in the box at every
   size the box is drawn. */
const BOX = 4.0;
const DIST = 15.0;
const FOCAL = DIST / BOX;
/* The drawing's stalk leans a little right of a planted foot. One shear says
   that, and it is the difference between the mark and a mushroom. */
const LEAN = 0.14;

fn hash(p: vec2f) -> f32 {
	return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453123);
}

fn noise3(p: vec3f) -> f32 {
	let i = floor(p);
	let f = fract(p);
	let w = f * f * (3.0 - 2.0 * f);
	let n = i.x + i.y * 57.0 + i.z * 113.0;
	let a = mix(hash(vec2f(n, 0.0)), hash(vec2f(n + 1.0, 0.0)), w.x);
	let b = mix(hash(vec2f(n + 57.0, 0.0)), hash(vec2f(n + 58.0, 0.0)), w.x);
	let c = mix(hash(vec2f(n + 113.0, 0.0)), hash(vec2f(n + 114.0, 0.0)), w.x);
	let d = mix(hash(vec2f(n + 170.0, 0.0)), hash(vec2f(n + 171.0, 0.0)), w.x);
	return mix(mix(a, b, w.y), mix(c, d, w.y), w.z);
}

/** The usual bound: exact enough to trace, cheap enough to call four times a
 * step for the normal. */
fn sdEllipsoid(p: vec3f, r: vec3f) -> f32 {
	let k0 = length(p / r);
	let k1 = length(p / (r * r));
	return k0 * (k0 - 1.0) / max(k1, 0.0001);
}

fn smin(a: f32, b: f32, k: f32) -> f32 {
	let h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
	return mix(b, a, h) - k * h * (1.0 - h);
}

/** Intersection with a fillet. A plain max leaves a knife edge wherever two
 * surfaces meet, and a brim that ends on a knife edge is the least cute thing
 * a mushroom can do. */
fn smax(a: f32, b: f32, k: f32) -> f32 {
	return -smin(-a, -b, k);
}

/** The five windows, as directions out of the cap's centre. Keeping them as
 * directions is what puts them exactly on the dome at any size the cap has
 * grown to. Four sit on the face of the cap, not its edge, because a dot on
 * the silhouette notches the outline; the fifth is on the back of the dome,
 * never drawn, and exists for its beam. */
fn poreDir(i: i32) -> vec3f {
	if (i == 0) { return normalize(vec3f(-0.28, 0.60, 0.76)); }
	if (i == 1) { return normalize(vec3f(-0.68, 0.3, 0.68)); }
	if (i == 2) { return normalize(vec3f(0.64, 0.36, 0.68)); }
	if (i == 3) { return normalize(vec3f(0.3, 0.7, -0.65)); }
	// A small one low on the front, a little to the viewer's left.
	return normalize(vec3f(0.18, 0.28, 0.94));
}

/** How far each window throws. Near enough equal: a cartoon lantern throws
 * the beams you can count. The back one is a touch shorter, the small one
 * half. */
fn poreThrow(i: i32) -> f32 {
	if (i == 3) { return 1.0; }
	if (i == 4) { return 0.55; }
	return 1.1;
}

/** How wide each window's beam opens, as a multiple of the ordinary cone.
 * The small one is a softer lamp: its beam is broader and gentler, a glow
 * that leaves the cap rather than a ray. */
fn poreSpread(i: i32) -> f32 {
	if (i == 4) { return 1.5; }
	return 1.0;
}

fn poreSize(i: i32) -> f32 {
	if (i == 0) { return 0.31; }
	if (i == 1) { return 0.24; }
	if (i == 2) { return 0.27; }
	if (i == 3) { return 0.24; }
	return 0.19;
}

/** How far the cap's surface stands proud at this point, and how near the
 * centre of a window it is.
 *
 * A window is a low dome on the cap, geometry the trace finds like anything
 * else. Low, so it is a disc on the cap and not a boss with a side, and a
 * gentle dome rather than a steep one: a steep shoulder turned the normal
 * hard at the edge and the outline band caught it as a bright ring round
 * every window. Only the drawn windows are built; the back one only throws.
 *
 * Returns the height to raise the surface by, and the nearest window's
 * centre closeness in the second channel, which the shading paints the dot
 * and its lit ring from. */
fn nodules(c: vec3f, r: vec3f, detail: f32) -> vec2f {
	var height = 0.0;
	var centre = 0.0;
	for (var i = 0; i < 5; i = i + 1) {
		if (i == 3) { continue; }
		let keep = select(smoothstep(0.0, 0.5, detail), 1.0, i == 0);
		if (keep < 0.02) { continue; }
		let grow = mix(1.6, 1.0, detail);
		let dir = poreDir(i);
		let seat = dir / max(length(dir / r), 0.0001);
		let s = poreSize(i) * 1.45 * grow;
		let k = clamp(1.0 - dot(c - seat, c - seat) / (s * s), 0.0, 1.0);
		height = max(height, poreSize(i) * 0.4 * grow * keep * detail * k);
		centre = max(centre, k * keep);
	}
	return vec2f(height, centre);
}

/** Body to the cap's own frame: seated on the stalk at the cap's grown
 * height, then tilted. The cap's field, its windows, its beams, and its lamps
 * all ask this one function where the cap is, so none of them can disagree
 * about it. */
fn capFrame(bp: vec3f, g: f32, detail: f32) -> vec3f {
	let c = bp - vec3f(0.0, CAP_Y * mix(0.74, 1.0, g), 0.0);
	let ct = cos(TILT * detail);
	let st = sin(TILT * detail);
	return vec3f(c.x * ct - c.y * st, c.x * st + c.y * ct, c.z);
}

fn capUnframe(c: vec3f, g: f32, detail: f32) -> vec3f {
	let ct = cos(TILT * detail);
	let st = sin(TILT * detail);
	return vec3f(c.x * ct + c.y * st, -c.x * st + c.y * ct, c.z) +
		vec3f(0.0, CAP_Y * mix(0.74, 1.0, g), 0.0);
}

/** The cap's radii at a point in its frame, as it is right now: grown,
 * squashed by the spring, and wobbled around its axis.
 *
 * The cap is not a solid of revolution. Two slow waves around its axis make
 * one shoulder fuller than the other and the brim dip where it wants to,
 * which is the whole difference between a drawn mushroom and a lathed one.
 * Soft, not lumpy: a blob has one or two swells, a potato has five. The dome
 * is also taller on one side than the other, a cushion rather than a dome,
 * faded out at the pole where every angle meets and a wave would crease the
 * crown. It starts at half width and grows, but from nothing: before the
 * cap's beat, a half-width cap with no height was a disc hanging in the air. */
fn capRadii(c: vec3f, g: f32, squash: f32, detail: f32) -> vec3f {
	let wide = 1.0 + squash * 0.75;
	let tall = 1.0 - squash * 0.9;
	let a = atan2(c.z, c.x);
	let wob = 1.0 + 0.08 * sin(a + 0.9) + 0.04 * sin(a * 2.0 - 0.5) +
		0.015 * sin(a * 3.0 + 1.7);
	let across = mix(0.55, 1.0, g) * smoothstep(0.0, 0.08, g);
	let grown = vec3f(across * wob * wide, g * tall, across * wob * wide);
	let away = smoothstep(0.0, 0.55, length(c.xz) / CAP_R.x);
	return CAP_R * grown * vec3f(1.0 + (1.0 - detail) * 0.28,
		1.0 + (0.08 * sin(a * 2.0 + 1.0) + 0.05 * sin(a - 0.6)) * away,
		1.0 + (1.0 - detail) * 0.28);
}

/** Where window i sits in the cap's frame, on the cap as it is right now. */
fn poreSeat(i: i32, g: f32, squash: f32, detail: f32) -> vec3f {
	let dir = poreDir(i);
	let r = capRadii(dir, g, squash, detail);
	return dir / max(length(dir / r), 0.0001);
}

/** The same window in the world. The scene pushes it along the eye's line
 * to put the beam in front of the dome. */
fn poreWorld(i: i32, g: f32, squash: f32, bob: f32, detail: f32) -> vec3f {
	let seat = poreSeat(i, g, squash, detail);
	return fromBody(capUnframe(seat, g, detail), bob, detail);
}

/** Where each beam goes, which is not where its window faces. The windows
 * face the eye, so the cap reads as lit; a beam that left the same way would
 * come straight at the eye and foreshorten into a haze. The drawn mark's rays
 * live in the picture, up and out to the sides, and so do these. Each has
 * an angle of its own: the small window's beam leaves low and level, under
 * the left beam, or the two lie along each other and read as one. */
fn beamDir(i: i32) -> vec3f {
	if (i == 0) { return normalize(vec3f(-0.3, 0.9, 0.05)); }
	if (i == 1) { return normalize(vec3f(-0.92, 0.36, 0.05)); }
	if (i == 3) { return normalize(vec3f(0.42, 0.86, 0.05)); }
	if (i == 4) { return normalize(vec3f(0.95, 0.2, 0.05)); }
	return normalize(vec3f(0.88, 0.42, 0.05));
}

/** That beam's axis in the world: turned with the cap's tilt and the body's
 * lean, with none of the translations. */
fn poreAxis(i: i32, detail: f32) -> vec3f {
	let origin = fromBody(capUnframe(vec3f(0.0), 0.0, detail), 0.0, detail);
	return normalize(fromBody(capUnframe(beamDir(i), 0.0, detail), 0.0, detail) - origin);
}

/** The stalk: a body of revolution, so its whole profile is one rounded box
 * in the radius-height plane. It bends, with a curve that is zero at the
 * ground so it never slides the foot; it has a belly rather than a waist; it
 * comes up as a thin shoot and fills out as it rises, and before it has risen
 * at all there is nothing, not a disc of full width lying on the ground. */
fn stemField(p0: vec3f, grow: f32, detail: f32) -> f32 {
	var p = p0 - vec3f(STEM_X, 0.0, 0.0);
	p.x = p.x - (p.y - 0.05) * LEAN;
	let top = STEM_TOP * max(grow, 0.001);
	p.x = p.x + (sin(p.y * 3.4 - 0.5) - sin(-0.5)) * 0.08 + p.y * 0.02;
	// A shoot comes up narrow and fills out as it rises, so the width lags the
	// height rather than arriving ahead of it. Reaching full width first gave
	// a lozenge lying on the floor that then extruded upward, which is a
	// different thing from something growing.
	let sprout = smoothstep(0.0, 0.12, grow) * mix(0.22, 1.0, smoothstep(0.02, 0.9, grow));
	var r = (0.55 + 0.12 * smoothstep(0.5, 0.0, p.y) + 0.06 * smoothstep(0.15, 0.55, p.y) * smoothstep(1.15, 0.55, p.y)) *
		mix(0.56, 1.0, detail) * sprout;
	// The base is a cylinder's: its bottom rim is an ellipse seen from a
	// little above, so the profile dips at the axis and rises to the sides.
	// The floor is met after the body, so the dip can sit below it.
	let q = vec2f(length(p.xz), p.y + STEM_DIP * max(1.0 - (length(p.xz) / max(r, 0.001)) * (length(p.xz) / max(r, 0.001)), 0.0));
	// A flat foot with softened corners, not a pill: the rounding is small.
	// It scales with the stalk's own height until the stalk is tall enough to
	// carry it. A fixed rounding is the whole shape while the stalk is short,
	// so the first frames were a ball on the floor rather than a shoot, and at
	// zero height the stalk was a bead that had never grown at all. Full
	// height reaches the same 0.13 as before, so nothing settled moves.
	let round = 0.13 * min(1.0, top / 0.42);
	let d = abs(q - vec2f(0.0, top * 0.5)) - vec2f(r, top * 0.5) + vec2f(round);
	return min(max(d.x, d.y), 0.0) + length(max(d, vec2f(0.0))) - round;
}

/** The cap: an ellipsoid with a bowl carved out of its underside, so it is a
 * shell with a real inside for the light to sit in. No gills: the drawing
 * has none, and anatomy is the fastest way to stop reading as a mark. */
fn capField(p: vec3f, grow: f32, squash: f32, detail: f32) -> f32 {
	let g = max(grow, 0.001);
	let c = capFrame(p, g, detail);
	let a = atan2(c.z, c.x);
	let r = capRadii(c, g, squash, detail);

	// A cap is a hat, not a pebble: it widens toward its lower edge and the
	// brim hangs down past the underside. Widening the dome as it descends is
	// what turns a dome into a brim.
	var q = c;
	let flare = 1.0 + 0.1 * smoothstep(0.8, -0.3, c.y / r.y) -
		0.06 * smoothstep(-0.2, -0.6, c.y / r.y);
	q = vec3f(q.x / flare, q.y, q.z / flare);
	var d = sdEllipsoid(q, r);
	// A dimple on the far shoulder. A cap that has been pressed somewhere is
	// a thing that grew; a perfect one is a thing that was turned.
	let dent = c - vec3f(0.5, 0.8, 0.5);
	d = d + 0.07 * exp(-dot(dent, dent) * 3.0) * g;

	// The brim's bulge: a soft swelling that runs round the rim, so the edge is
	// a rolled lip rather than a thickness. Small on purpose. Any more and the
	// cap wears a tyre; this is the roundness you notice only if it is missing.
	let rimAt = length(c.xz) / max(r.x, 0.0001);
	let bulge = exp(-pow((rimAt - 0.9) * 3.2, 2.0)) *
		exp(-pow((c.y / max(r.y, 0.0001) + 0.24) * 2.2, 2.0));
	d = d - 0.12 * bulge * g;

	// The underside: lower and flatter under the middle, so the brim's bottom
	// edge sits over the stalk's shoulders and the join hides behind it, and
	// hanging unevenly round the edge so it ends the way a drawn brim ends,
	// with a scallop and not a line.
	let wave = 0.06 * sin(a * 3.0 + 0.4) + 0.03 * sin(a * 5.0 - 1.1);
	// The fillets carry a world distance too, and an ungrown cap is smaller
	// than they are, so they round it out into a blob instead of trimming it.
	// They arrive with the cap and reach their full size well before it does.
	let fillet = smoothstep(0.0, 0.12, g);
	d = smax(d, -(c.y + r.y * 0.3 - 0.1 * length(c.xz) / r.x + wave * smoothstep(0.5, 1.0, rimAt)), 0.26 * fillet);

	// A shallow bowl in that underside, so there is an inside for the light
	// to sit in. It stops well short of the rim, so the brim keeps a lip with
	// thickness rather than tapering to a blade that the trace cannot find an
	// honest distance to.
	let bowl = sdEllipsoid(c + vec3f(0.0, r.y * 0.86, 0.0), r * vec3f(0.84, 0.62, 0.84));
	d = smax(d, -bowl, 0.14 * fillet);
	if (d < 0.35 && c.y > -r.y * 0.2) {
		d = d - nodules(c, r, detail).x * g;
	}
	return d;
}

/** World to body: the settle, then the lean. Every call that asks the
 * mushroom a question goes through here, so nothing can get the lean applied
 * twice or not at all.
 *
 * The settle is a stretch from the foot, not a hop: the base stays on the
 * ground and the lift grows up the stalk, so the cap rides the spring and
 * the foot never leaves the floor. The lean is a shear, not a rotation, for
 * the same reason: a rotation tilted the whole foot with it. */
fn toBody(p: vec3f, bob: f32, detail: f32) -> vec3f {
	let q = p - vec3f(0.0, bob * smoothstep(0.0, STEM_TOP, p.y), 0.0);
	return vec3f(q.x - q.y * SWAY * detail, q.y, q.z);
}

/** Body to world: the inverse, for a point the body knows and the world has
 * to see, such as where a beam begins. */
fn fromBody(q: vec3f, bob: f32, detail: f32) -> vec3f {
	return vec3f(q.x + q.y * SWAY * detail, q.y, q.z) +
		vec3f(0.0, bob * smoothstep(0.0, STEM_TOP, q.y), 0.0);
}

/** The whole body, and its id: one is the mushroom. The floor is not in the
 * field. A floor the march could hit stood in front of the foot for every
 * ray that grazed it, and the foot's bottom line was drawn on a sliver of
 * floor instead of on the foot. The floor is met analytically, after the
 * body, in the scene. */
fn mapScene(p0: vec3f, stem: f32, cap: f32, squash: f32, bob: f32, detail: f32) -> vec2f {
	let p = toBody(p0, bob, detail);
	// A small blend: the cap sits on the stalk, it does not melt into it.
	//
	// Each half is kept a hair above zero size so the trace never divides by a
	// zero radius, which means neither is ever actually empty, and the outline
	// is a band of fixed width on the screen: it paints a speck as readily as
	// a mushroom. Ungrown, that speck is an amber dot sitting on the floor. So
	// each half is lifted out of the field until it has started, on its own
	// count rather than the pair's, because a stalk that has not grown must
	// stay out of sight while the cap above it has. The range is far shorter
	// than the beat that follows it, and the blend's own radius comes in the
	// same way rather than rounding two specks into a bead. All three are back
	// to their settled values well before anything is large enough to see, so
	// the growth that follows is the one that was designed.
	let stemLift = (1.0 - smoothstep(0.0, 0.03, stem)) * 8.0;
	let capLift = (1.0 - smoothstep(0.0, 0.03, cap)) * 8.0;
	let blend = 0.1 * smoothstep(0.0, 0.03, min(stem, cap));
	let body = smin(stemField(p, stem, detail) + stemLift, capField(p, cap, squash, detail) + capLift, blend);
	return vec2f(body, 1.0);
}

/** Four samples on a tetrahedron rather than six on the axes: the same
 * gradient to the precision the shading uses, at two thirds the cost. */
fn normalAt(p: vec3f, stem: f32, cap: f32, sq: f32, bob: f32, det: f32) -> vec3f {
	let h = 0.0018;
	let k0 = vec3f(1.0, -1.0, -1.0);
	let k1 = vec3f(-1.0, -1.0, 1.0);
	let k2 = vec3f(-1.0, 1.0, -1.0);
	let k3 = vec3f(1.0, 1.0, 1.0);
	return normalize(
		k0 * mapScene(p + k0 * h, stem, cap, sq, bob, det).x +
		k1 * mapScene(p + k1 * h, stem, cap, sq, bob, det).x +
		k2 * mapScene(p + k2 * h, stem, cap, sq, bob, det).x +
		k3 * mapScene(p + k3 * h, stem, cap, sq, bob, det).x);
}

/** How much flesh is behind this point, marched inward from the surface. A
 * glowing cap is translucent, and light inside it comes through in
 * proportion to how little of it there is to come through: thin places come
 * out bright, thick places stay dark. Four samples is enough because the
 * answer only has to be monotonic; it feeds an exponential. */
fn thickness(p: vec3f, n: vec3f, stem: f32, cap: f32, sq: f32, bob: f32, det: f32) -> f32 {
	var t = 0.0;
	for (var i = 1; i <= 4; i = i + 1) {
		let q = p - n * (0.09 * f32(i));
		t = t + max(-mapScene(q, stem, cap, sq, bob, det).x, 0.0);
	}
	return t;
}
`;
