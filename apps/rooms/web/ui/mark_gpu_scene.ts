// The scene pass: one frame of the mark, traced and lit, per pixel.
//
// The entry point reads the frame, aims the ray, traces the body, and then
// hands the pixel to the stages in the order the picture is built: the floor
// or the body, the outline, the air, the dust, and the edge of the canvas.
// Every stage takes the same `Frame`, so what a frame is gets decided once.

/** The entry point and its stages. Concatenated after the field and the
 * light, which it calls into. */
export const SCENE = `
struct Uniforms {
	resolution: vec4f,
	view: vec4f,
	light: vec4f,
	rim: vec4f,
	fill: vec4f,
	flare: vec4f,
	beats: vec4f,
	more: vec4f,
	accent: vec4f,
	night: vec4f,
};

@group(0) @binding(0) var<uniform> u: Uniforms;

/** What this frame is, beyond the pixel: the beats, how much of the
 * drawing is worth building at this size, and the two colours the light
 * comes in. Read once, in the entry point, and handed to every stage. */
struct Frame {
	stem: f32,
	cap: f32,
	gCap: f32,
	squash: f32,
	bob: f32,
	detail: f32,
	glow: f32,
	rays: f32,
	flareMix: f32,
	lightPage: f32,
	t: f32,
	lamp: vec3f,
	ink: vec3f,
	flash: vec3f,
	edge: vec3f,
	strokeW: f32,
};

/** Where the light leaves from this frame: the five windows' beams and the
 * spill under the brim, in the world. */
struct Lamps {
	at: array<vec3f, 5>,
	dir: array<vec3f, 5>,
	spill: vec3f,
};

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
	var p = array<vec2f, 3>(vec2f(-1.0, -3.0), vec2f(-1.0, 1.0), vec2f(3.0, 1.0));
	return vec4f(p[i], 0.0, 1.0);
}

/** The rays are drawn in front of the mushroom, the way a drawing lays them
 * over the cap. Each beam's origin is its window pushed out along the eye's
 * own line to it, so it still projects exactly onto its dot. Pushed straight
 * toward the camera it would drift off the dot under perspective. The back
 * window goes the other way, behind the dome, so the dome hides the base of
 * its beam. The spill leaves from under the brim's front edge, in front of
 * the stalk, so it is seen falling over it. */
fn placeLamps(ro: vec3f, ww: vec3f, fr: Frame) -> Lamps {
	var lamps: Lamps;
	for (var k = 0; k < 5; k = k + 1) {
		let w = poreWorld(k, fr.gCap, fr.squash, fr.bob, fr.detail);
		let depth = dot(w - ro, ww);
		let push = select(-1.4, 0.5, k == 3);
		lamps.at[k] = ro + (w - ro) * ((depth + push) / max(depth, 0.01));
		lamps.dir[k] = poreAxis(k, fr.detail);
	}
	lamps.spill = fromBody(vec3f(0.0, CAP_Y * mix(0.74, 1.0, fr.gCap) - 0.3 * fr.gCap, 1.0), fr.bob, fr.detail);
	return lamps;
}

/** The floor has no colour of its own: it exists to catch light. What it
 * catches is the spill from under the brim, brightest beneath the chamber,
 * falling off with distance and with the angle the light arrives at, and
 * ending softly where the light has run out rather than at an edge.
 *
 * The pool is centred on the stalk's axis, where the base rim is, and
 * stretched toward the eye so it projects to the same ellipse as that rim.
 * The camera sees the floor at 6.7 degrees, where a circle projects at
 * 0.117 of its width. The rim is drawn at 0.206 (its true projection plus
 * STEM_DIP), and 0.117 / 0.57 is 0.205. The two numbers move together, or
 * the viewer is in two places at once. */
fn floorLight(p: vec3f, fr: Frame) -> vec3f {
	let m = fromBody(vec3f(STEM_X, MOUTH.y, 0.0), fr.bob, fr.detail);
	let toward = m - p;
	let side = length(toward.xz * vec2f(1.0, 0.57));
	let fall = 1.0 / (1.0 + 1.4 * side * side);
	let facing = normalize(toward).y;
	let soft = smoothstep(2.3, 0.5, side);
	let strength = (fall * facing * 1.1 + 0.15) * (1.0 + 0.5 * fr.lightPage) * soft * fr.glow * fr.gCap *
		(1.0 + fr.flareMix * 1.2);
	// The same day rule as the air: pale where thin, deep where dense.
	let poolInk = mix(fr.ink, mix(vec3f(0.6, 0.92, 0.94), fr.ink, clamp(strength, 0.0, 1.0)), fr.lightPage);
	return poolInk * strength;
}

/** The mushroom at a surface point: two flat tones and a line, with the
 * light on it.
 *
 * The drawing is flat. Everything a renderer is proud of, a
 * gradient over the dome and a sheen and ridges, is texture at two hundred
 * pixels and mud at forty-eight. So the object is a dark flesh, a flat
 * highlight, the windows, and the outline, and the device spends itself on
 * light that moves, reaches, and lands on things. */
fn shadeBody(p: vec3f, n: vec3f, rd: vec3f, fr: Frame) -> vec3f {
	let bp = toBody(p, fr.bob, fr.detail);
	let capNear = capField(bp, fr.cap, fr.squash, fr.detail);
	// Cap or stalk is which field owns the point, never a height: the
	// stalk's top reaches inside the cap, and a height cut painted a collar
	// of cap tone round it.
	let onStem = smoothstep(0.03, -0.03, stemField(bp, fr.stem, fr.detail) - capNear);
	let isCap = 1.0 - onStem;

	// Darker than the token, because the token was a fill for a flat drawing
	// with no light in it, and here the light is what has to win: the flesh
	// is the dark the lantern is seen against. By day the flesh lifts, or the
	// night's near-black flesh on a cream page reads as a hole.
	// By day the cap lifts further than the stalk, and the shine band below
	// lifts further still: on a cap only a little lighter than its band the
	// shading could not be seen, and the highlight has to stay the lighter
	// of the two in both themes, or the light would come from the other
	// side by day.
	var body = mix(u.fill.rgb * mix(0.55, 1.0, fr.lightPage),
		mix(u.fill.rgb, u.accent.rgb, 0.12) * mix(0.62, 1.4, fr.lightPage), isCap);
	// At a dozen pixels there is no room for a fill and a line to be two
	// things, so the body becomes the line: a solid amber glyph with the
	// light on it. The dark flesh comes back as soon as there are pixels to
	// draw it in.
	body = mix(mix(u.fill.rgb * 1.4, mix(u.fill.rgb, u.accent.rgb, 0.3), isCap), body, fr.detail);

	// The windows, on the cap as it is this frame.
	let cc = capFrame(bp, fr.gCap, fr.detail);
	let rr = capRadii(cc, fr.gCap, fr.squash, fr.detail);
	let nodAt = nodules(cc, rr, fr.detail).y;
	let dots = smoothstep(0.30, 0.37, nodAt);
	let bleed = pow(nodAt, 1.5);
	// The flesh next to a lamp is lit by it. That soft ring on the cap around
	// each window is most of what makes a dot read as a light rather than a
	// sticker of one.
	var around = 0.0;
	for (var i = 0; i < 5; i = i + 1) {
		if (i == 3) { continue; }
		let v = cc - poreSeat(i, fr.gCap, fr.squash, fr.detail);
		let s = poreSize(i) * 2.6;
		around = around + exp(-dot(v, v) / (s * s));
	}
	body = body + fr.lamp * around * 0.3 * fr.glow;

	// A cartoon shine: one flat crescent on the cap's upper shoulder, the
	// highlight every drawn dome has, lit from far enough in front that it
	// sits on the dome and not against the silhouette. The same light on the
	// stalk makes one flat band down its lit side, measured round the
	// stalk's own axis at this height rather than from the normal, because
	// the bend and the lean turn the normal in steps that read as a zigzag
	// while the angle round the axis bends with the stalk. The band ends in
	// arcs that follow the stalk's rims as the eye sees them: a cylinder's
	// ends are ellipses, and a stripe stopped on a straight line flattens it.
	let toLight = normalize(vec3f(-0.36, 0.62, 0.7));
	let shine = smoothstep(0.7, 0.76, dot(n, toLight)) * isCap;
	let axisX = STEM_X + (bp.y - 0.05) * LEAN - ((sin(bp.y * 3.4 - 0.5) - sin(-0.5)) * 0.08 + bp.y * 0.02);
	let roundStem = normalize(vec2f(bp.x - axisX, bp.z));
	let stripeX = (bp.x - STEM_X) / 0.67;
	let stripeArc = 1.0 - clamp(stripeX * stripeX, 0.0, 1.0);
	let stripeFoot = smoothstep(0.1 - 0.16 * stripeArc, 0.3 - 0.16 * stripeArc, bp.y);
	let stripeTop = 1.0 - smoothstep(0.86 - 0.14 * stripeArc, 0.98 - 0.14 * stripeArc, bp.y);
	let shineStem = smoothstep(0.74, 0.82, dot(roundStem, normalize(toLight.xz))) * (1.0 - isCap) *
		stripeFoot * stripeTop;
	body = mix(body, mix(u.fill.rgb, u.accent.rgb, 0.4) * mix(0.72, 1.3, fr.lightPage), max(shine, shineStem));
	body = body + fr.lamp * bleed * 2.4 * fr.glow * mix(0.35, 1.0, fr.detail);

	// Transmission, as one flat band: where the flesh is thin the chamber
	// shows through, so the brightness follows the geometry instead of
	// sitting on it. The stalk is lit from the chamber above it, and that
	// light falls off toward the foot: a gradient there is not shading, it
	// is the lamp's reach.
	let thick = thickness(p, n, fr.stem, fr.cap, fr.squash, fr.bob, fr.detail);
	let through = exp(-thick * 5.5);
	let stalkLit = (1.0 - isCap) * smoothstep(0.05, 1.25, p.y);
	body = body + fr.lamp * (smoothstep(0.5, 0.6, through) * 0.18 * isCap + stalkLit * 0.26) * fr.glow;
	// Before the light, a window is a dark hole in the cap: the lamp is off,
	// and what shows is the chamber behind it, a deep amber rather than a
	// black. Lit, by night it is driven past white so it blooms; by day it
	// is held near the lamp's own colour, or the teal clips to white.
	body = mix(body, u.accent.rgb * 0.14, dots * (1.0 - fr.glow));
	body = mix(body, fr.lamp * mix(2.0, 1.15, fr.lightPage), dots * fr.glow);

	// The brim's own glow under it: the one piece of shading the mark keeps,
	// because it is light rather than surface.
	let under = smoothstep(-0.05, -0.5, n.y) * isCap;
	body = body + fr.lamp * under * 2.4 * fr.glow;

	// The strike tints the whole cap. A line is one pixel wide here and
	// cannot hold the loudest beat in the animation.
	body = mix(body, fr.flash * 1.15, fr.flareMix * 0.3);

	// The inner half of the outline. Inside the silhouette the band is
	// angular: on a rounded body the normal turns away from the eye over
	// roughly the square root of the distance from the edge, so the band
	// that is strokeW deep starts where the normal has turned that far. It
	// is the silhouette's band, not a window's: a bump turns the normal too,
	// and an outline round every dot is a wart.
	let turnAt = clamp(sqrt(fr.strokeW * 0.9), 0.2, 0.5);
	let turn = (1.0 - smoothstep(turnAt * 0.88, turnAt, dot(n, -rd))) *
		(1.0 - smoothstep(0.0, 0.06, nodAt));
	// The outline catches the light too: near a window the amber line goes
	// teal, the rim of a lantern seen against its lamp. There is no line
	// where the stalk enters the cap: the brim hangs in front of the stalk
	// and its own outline is the seam.
	let litEdge = mix(fr.edge, fr.lamp * 1.3, clamp(around * 0.9, 0.0, 1.0) * fr.glow);
	// The foot's bottom edge is the one place the silhouette has no surface
	// turning away toward it, so the inner half of the line is drawn by
	// height instead, measured from the dipped rim so it follows the
	// ellipse: the last half-stroke of the stalk above the rim is line.
	let footX = (bp.x - STEM_X) / 0.67;
	let rim = -STEM_DIP * max(1.0 - footX * footX, 0.0);
	let footLine = (1.0 - isCap) * (1.0 - smoothstep(fr.strokeW * 0.3, fr.strokeW * 0.45, bp.y - rim));
	return mix(body, litEdge, clamp(max(turn, footLine), 0.0, 1.0));
}

/** The lit air along one ray, from where it enters the light's sphere to
 * where it meets the mushroom or the mushroom's depth.
 *
 * Most rays cross only the faint edge of a beam, or nothing. Sixteen coarse
 * looks along the ray, without the mist, say how much any lamp reaches it.
 * A ray in the bright of a beam gets the fine march, and a faint one a
 * coarser march that no eye can tell apart at that brightness. Nothing is
 * ever skipped: the faintest tail still fades out on its own. The fine march
 * steps a good deal finer than a beam is wide, or a beam is a row of samples
 * that happened to land in it, which is a streak. */
fn marchAir(ro: vec3f, rd: vec3f, near: f32, far: f32, farBack: f32, coord: vec2f, lamps: Lamps, fr: Frame) -> f32 {
	var peak = 0.0;
	let cdt = (far - near) / 16.0;
	for (var i = 0; i < 16; i = i + 1) {
		let q = ro + rd * (near + cdt * (f32(i) + 0.5));
		for (var k = 0; k < 5; k = k + 1) { peak = max(peak, coneAt(q, lamps.at[k], lamps.dir[k], k, 1.0, rd)); }
		peak = max(peak, spillAt(q, lamps.spill, 1.0) * fr.gCap);
	}
	let steps = select(24, 48, peak > 0.004);
	let dt = (far - near) / f32(steps);
	let jitter = hash(coord) * dt;
	var vol = 0.0;
	for (var i = 0; i < steps; i = i + 1) {
		let q = ro + rd * (near + jitter + dt * f32(i));
		// The mist is one field, sampled once here and shared by every lamp:
		// it is the air that moves, not each beam's own weather. Two octaves,
		// slow billows and finer wisps drifting up through the beams, with
		// enough contrast that the air is visibly a thing the light passes
		// through, and a mean of one so the beams keep their brightness.
		let drift = vec3f(fr.t * 0.06, -fr.t * 0.3, 0.0);
		let mist = 0.55 + 0.9 * noise3(q * 0.9 + drift) +
			0.4 * (noise3(q * 2.3 + drift * 1.6 + vec3f(5.0)) - 0.5);
		var here = 0.0;
		for (var k = 0; k < 5; k = k + 1) { here = here + coneAt(q, lamps.at[k], lamps.dir[k], k, mist, rd); }
		here = here + spillAt(q, lamps.spill, mist) * fr.gCap;
		vol = vol + here * dt;
	}
	// The back window's beam rises from behind the dome, so nearly all of it
	// lies behind the depth the march above stops at. It gets its own march
	// from that depth to the mushroom or the sphere's far wall: where the body
	// is, the body hides it, and above the dome it stands clear with the
	// dome's own silhouette as its lower edge, the way a light behind a thing
	// is seen. Only the rays it can reach pay for it.
	if (farBack > far + 0.01) {
		var peakBack = 0.0;
		let cdb = (farBack - far) / 8.0;
		for (var i = 0; i < 8; i = i + 1) {
			let q = ro + rd * (far + cdb * (f32(i) + 0.5));
			peakBack = max(peakBack, coneAt(q, lamps.at[3], lamps.dir[3], 3, 1.0, rd));
		}
		if (peakBack > 0.0001) {
			let stepsBack = select(12, 24, peakBack > 0.004);
			let dtb = (farBack - far) / f32(stepsBack);
			let jitterBack = hash(coord + vec2f(7.0, 3.0)) * dtb;
			for (var i = 0; i < stepsBack; i = i + 1) {
				let q = ro + rd * (far + jitterBack + dtb * f32(i));
				let drift = vec3f(fr.t * 0.06, -fr.t * 0.3, 0.0);
				let mist = 0.55 + 0.9 * noise3(q * 0.9 + drift) +
					0.4 * (noise3(q * 2.3 + drift * 1.6 + vec3f(5.0)) - 0.5);
				vol = vol + coneAt(q, lamps.at[3], lamps.dir[3], 3, mist, rd) * dtb;
			}
		}
	}
	// One lamp in the same mist: the chamber under the brim, which is where
	// the spill comes from.
	return vol + inscatter(ro, rd, near, far, fromBody(MOUTH, fr.bob, fr.detail)) * 0.05;
}

/** Dust drifting up through the light: each mote a crisp point with a small
 * halo, next to nothing in the dark and a spark where a beam or the spill
 * finds it. They live in front of the mushroom, where the light is, and a
 * mote that drifts behind the body is hidden by it. Sized to be seen at the
 * size the mark ships at: a pixel or two across at forty-eight, with a halo
 * a few wide. */
fn drift(ro: vec3f, rd: vec3f, hit: f32, lamps: Lamps, fr: Frame) -> f32 {
	var dust = 0.0;
	for (var i = 0; i < 32; i = i + 1) {
		let fi = f32(i);
		let seed = hash(vec2f(fi, 3.7));
		let side = hash(vec2f(fi, 5.3));
		let life = fract(fr.t * (0.035 + seed * 0.05) + seed);
		let ang = seed * 6.2831 + sin(fr.t * 0.3 + fi) * 0.5;
		let rad = 0.5 + 3.0 * side;
		let sp = vec3f(cos(ang) * rad, mix(-0.1, 3.4, life), 0.5 + rad * abs(sin(ang)) * 0.8);
		let v = sp - ro;
		let along = dot(v, rd);
		if (along < 0.05 || along > hit + 0.6) { continue; }
		let across = length(v - rd * along);
		// The halo is gone well inside a unit; past that the mote costs this
		// pixel nothing, and the lamps are not asked.
		if (across > 0.8) { continue; }
		var lit = 0.0;
		for (var k = 0; k < 5; k = k + 1) { lit = lit + coneAt(sp, lamps.at[k], lamps.dir[k], k, 1.0, rd); }
		lit = lit + spillAt(sp, lamps.spill, 1.0) * fr.gCap;
		let point = exp(-across * across * 90.0) + 0.35 * exp(-across * across * 12.0);
		dust = dust + point * sin(life * 3.14159) * (0.12 + lit * 5.0);
	}
	return dust;
}

@fragment
fn fs(@builtin(position) coord: vec4f) -> @location(0) vec4f {
	let res = u.resolution.xy;
	let t = u.resolution.z;
	let breath = u.more.y;

	// The mushroom is drawn as a thing seen at night in both themes; the
	// light is the page's own. By day the lamps are white and the air is
	// teal ink. Ink at partial coverage over cream loses its colour before
	// its darkness, so by day the ink is pushed past the token's own chroma,
	// with some white in it, to arrive at the token's teal once it is on the
	// page; and the lamps take some of that teal, so the windows and the
	// beams that leave them are one light and not white beside cyan.
	let lightPage = smoothstep(0.3, 0.8, u.night.a);
	let inkLum = dot(u.flare.rgb, vec3f(0.2126, 0.7152, 0.0722));
	let dayInk = mix(clamp(mix(vec3f(inkLum), u.flare.rgb, 1.9) * 1.15, vec3f(0.0), vec3f(1.0)), vec3f(1.0), 0.36);
	// By night the token's teal has its blue a touch above its green, and a
	// beam that bright clips toward cyan-white. The night light is turned a
	// step toward green at the same luminance, so it stays teal as it
	// brightens. By day the tint is exactly one.
	let nightTint = mix(vec3f(0.96, 1.06, 0.91), vec3f(1.0), lightPage);
	let ink = mix(u.flare.rgb * nightTint, dayInk, lightPage);
	let lamp = mix(u.light.rgb * nightTint, ink, 0.6 * lightPage);

	// The canvas is the flat mark's plume box: u.view is that box in the units
	// of the 24-unit silhouette box, so the same four numbers place the canvas
	// around its element and place the mushroom inside the canvas.
	let pl = coord.xy / res * u.view.zw + u.view.xy;
	var uv = (pl - vec2f(12.0)) / 24.0;
	uv.y = -uv.y;

	// How big a pixel is, in the world, at the distance the mushroom stands.
	// Everything that has to survive being small is measured against this: the
	// stroke's weight, and how much fine shape is worth building at all. The
	// target is oversampled, and a line that is one oversampled pixel wide is
	// a quarter of a real one, so the measure of what is worth drawing is the
	// real pixel, not the one this shader is being run on.
	let over = max(u.resolution.w, 1.0);
	let pxBox = res.y * 24.0 / u.view.w;
	let px = BOX / pxBox;
	let detail = smoothstep(16.0, 44.0, pxBox / over);

	// The rims of the flat mark are about two of its twenty-four units, and
	// they scale with the drawing. So does this stroke, down to the floor of
	// a line and a half of real pixels, below which a line is only a tone.
	// And it has weight, the way an inked line does: thin over the crown,
	// heavy along the brim, ordinary down the stalk's sides, heavy again at
	// the foot. Measured by height in the picture, so the outer band and the
	// inner band that share this width agree about where heavy is. The
	// heights are the crown, the brim's underside, and the foot in box units
	// when the mushroom stands.
	let crown = smoothstep(-0.05, 0.25, uv.y);
	let brim = exp(-pow((uv.y + 0.17) / 0.11, 2.0));
	let foot = smoothstep(-0.33, -0.4, uv.y);
	let weight = mix(0.85, 0.55, crown) + 0.4 * brim + 0.25 * foot;
	// The strike's teal is a flash, two frames of it: brighter and paler than
	// the air's teal, so the line reads as lit rather than dyed, and by day
	// it is not the deep ink the beams are drawn in.
	let flash = mix(ink, vec3f(1.0), 0.32) * 1.25;

	var fr: Frame;
	fr.stem = u.beats.x;
	fr.cap = u.beats.y;
	fr.gCap = max(fr.cap, 0.001);
	fr.squash = u.more.z;
	fr.bob = u.more.w;
	fr.detail = detail;
	fr.glow = u.beats.z;
	fr.rays = u.beats.w;
	fr.flareMix = u.more.x;
	fr.lightPage = lightPage;
	fr.t = t;
	fr.lamp = lamp;
	fr.ink = ink;
	fr.flash = flash;
	fr.edge = mix(mix(u.rim.rgb * 1.08, u.accent.rgb * 1.05, 1.0 - detail), flash, fr.flareMix);
	fr.strokeW = max(BOX * 0.07, 1.5 * px * over) * weight;

	// A little above the brim, looking slightly down, so the ground the light
	// lands on is in frame and the underside reads. The drift is the breath.
	let spin = sin(t * 0.21) * 0.14 * breath;
	let ta = vec3f(0.0, 1.62, 0.0);
	let ro = vec3f(sin(spin) * DIST, ta.y + 0.14 + 0.04 * sin(t * 0.5) * breath, cos(spin) * DIST);
	let ww = normalize(ta - ro);
	let uu = normalize(cross(vec3f(0.0, 1.0, 0.0), ww));
	let vv = cross(ww, uu);
	let rd = normalize(uv.x * uu + uv.y * vv + FOCAL * ww);

	// The body lives in a small sphere in the middle of a canvas that is
	// mostly air, so the trace runs only for rays that enter that sphere, and
	// only between entering and leaving it. Every other ray owes the body
	// nothing: no hit, and nothing near enough for an outline. A ray that
	// misses has travelled the whole way, so the air in front of it is still
	// marched in full.
	var dist = 18.0;
	var id = -1.0;
	var closest = 1e9;
	let bodyC = vec3f(0.0, 1.4, 0.0);
	let bo = ro - bodyC;
	let bb = dot(bo, rd);
	let bdisc = bb * bb - dot(bo, bo) + 2.5 * 2.5;
	if (bdisc > 0.0) {
		let broot = sqrt(bdisc);
		dist = max(-bb - broot, 0.02);
		let leave = -bb + broot;
		for (var i = 0; i < 128; i = i + 1) {
			let p = ro + rd * dist;
			let h = mapScene(p, fr.stem, fr.cap, fr.squash, fr.bob, fr.detail);
			// The field is the body alone, so the step's own distance is the
			// nearest approach: no second evaluation of the field per step.
			closest = min(closest, h.x);
			if (h.x < 0.0008 * dist) { id = h.y; break; }
			dist = dist + h.x * 0.32;
			if (dist > leave) { dist = 18.0; break; }
		}
		if (id < 0.0) { dist = 18.0; }
	}

	// The floor, where nothing of the body was hit first.
	if (id < 0.0 && rd.y < -0.0001) {
		let tg = -ro.y / rd.y;
		if (tg < 18.0) { id = 0.0; dist = tg; }
	}

	var col = vec3f(0.0);
	var alpha = 0.0;
	let hit = min(dist, 18.0);

	if (id >= 0.0) {
		let p = ro + rd * hit;
		if (id < 0.5) {
			let landed = floorLight(p, fr);
			col = col + landed;
			alpha = max(alpha, min(max(max(landed.r, landed.g), landed.b), 1.0));
		} else {
			let n = normalAt(p, fr.stem, fr.cap, fr.squash, fr.bob, fr.detail);
			col = shadeBody(p, n, rd, fr);
			alpha = 1.0;
		}
	}

	// The outer half of the outline: rays that missed the mushroom but came
	// within a hair of it. Together the two halves make one stroke straddling
	// the silhouette. A crisp edge: the transition is a fraction of the
	// stroke, not half of it, and the supersample does the anti-aliasing.
	let stroke = 1.0 - smoothstep(fr.strokeW * 0.44, fr.strokeW * 0.5, closest);
	if (stroke > 0.0 && id < 0.5) {
		col = mix(col, fr.edge, stroke);
		alpha = max(alpha, stroke);
	}

	// The light lives in a sphere that holds the whole canvas, so no beam
	// meets its wall: a beam ends where its light runs out, never at an edge
	// of the march. The air ends at the mushroom's own depth for every ray,
	// hit or not: the rays are drawn in front of the mushroom, and a ray
	// that missed the body by a pixel would otherwise gather a beam's skirt
	// behind that depth while its neighbour on the cap could not, a step in
	// the light along the silhouette wherever a beam crosses it.
	let lamps = placeLamps(ro, ww, fr);
	let bc = vec3f(0.0, 2.4, 0.0);
	let oc = ro - bc;
	let b = dot(oc, rd);
	let disc = b * b - dot(oc, oc) + 5.4 * 5.4;
	var vol = 0.0;
	if (disc > 0.0) {
		let root = sqrt(disc);
		let near = max(-b - root, 0.0);
		let farPlane = dot(bodyC - ro, ww) / max(dot(rd, ww), 0.01);
		let farBack = min(-b + root, hit);
		let far = min(farBack, farPlane);
		if (far > near) {
			vol = marchAir(ro, rd, near, far, farBack, coord.xy, lamps, fr);
		}
	}
	let dust = drift(ro, rd, hit, lamps, fr);

	// A ceiling on the lit air, so a ray down the middle of a beam sums to a
	// bright teal and never to white: the light has one colour. By day the
	// ink's colour follows its coverage, pale where the air is thin and the
	// token's teal where it is dense, because a thin wash of deep teal over
	// cream is grey by arithmetic; and ink over cream needs more coverage
	// than light over black to read as the same thing.
	let air = vol * 10.0 * (1.0 + 0.7 * lightPage);
	let airInk = mix(ink, mix(vec3f(0.78, 0.97, 0.98), ink, clamp(air * 0.5, 0.0, 1.0)), lightPage);
	col = col + airInk * (air / (1.0 + air * 0.08) + dust) * fr.rays * fr.glow;

	// The haze the mushroom stands in, by night only: on cream it was grey.
	let toEye = length((ro + rd * min(hit, 12.0)) - vec3f(0.0, 1.05, 0.0));
	col = col + ink * exp(-toEye * toEye * 0.15) * 0.05 * (1.0 - lightPage) * fr.glow * (1.0 + fr.flareMix * 2.8);

	// The vignette is the canvas's own edge, softened: the flat mark's plume
	// simply ends where its box does, and this one fades over the last few
	// units so a beam leaving the picture thins out rather than being cut.
	// What frames the mark inside that is its own light running out.
	let lo = pl - u.view.xy;
	let hi = u.view.xy + u.view.zw - pl;
	let vig = smoothstep(0.0, 10.0, lo.x) * smoothstep(0.0, 10.0, hi.x) *
		smoothstep(0.0, 12.0, lo.y) * smoothstep(0.0, 4.0, hi.y);
	col = col * vig;
	alpha = max(alpha, min(max(max(col.r, col.g), col.b), 1.0)) * vig;

	// A touch of the light's own colour bleeding into the brightest places. A
	// camera does the same, and it keeps a beam's core off flat fill.
	let hot = smoothstep(0.85, 1.8, max(max(col.r, col.g), col.b));
	col = mix(col, ink * 1.5, hot * 0.3);

	// This pass writes to a float target, so the colour is left unclamped:
	// the composite needs to know how bright a thing was to bloom it. The
	// colour here is emitted light, and coverage was read off its brightness.
	// Over the night page coverage hardly matters and the premultiplied form,
	// colour times coverage, is the look the light was tuned in. Over a light
	// page the coverage is the whole picture, and the same product squares
	// every thin beam into a dark wash that reads as grey on cream: there the
	// colour stands at full and coverage alone carries how much light there
	// is, rising a little slower than brightness so the faintest air is a
	// hint on the page and not a cyan wash across all of it.
	let a = clamp(alpha, 0.0, 1.0);
	let aDay = pow(a, 1.35);
	return vec4f(mix(col * a, min(col, vec3f(aDay)), lightPage), mix(a, aDay, lightPage));
}
`;
