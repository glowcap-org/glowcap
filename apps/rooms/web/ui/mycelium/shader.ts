// The mycelium's shader. Every thread is one instance: a quad around the
// segment from a point's parent to the point, shaded by its distance from the
// segment. A sharp thread is a round-capped stroke, and the pixel keeps its
// brightest stroke rather than adding them, so the joints along a thread do
// not bead where its segments overlap. Blur and light add instead, so their
// segments end square and tile a thread without overlap.
//
// Three passes share it. `plane` draws one plane of threads up to a growth
// step. `light` draws the focal plane's threads lit by the mouse, then adds
// the growing front and every wave in flight. `run` adds the points of light
// running along single threads. renderer.ts owns the buffers each reads.

import { FRONT, HAIR, HAIR_GLOW, HAIR_LIT, HEAD, LEVELS, TRAIL, WAVE_BAND, WAVE_RISE, WAVE_START } from "./light.ts";

/** How many waves, and how many runs, can be alight at once. */
export const WAVE_SLOTS = 4;
export const RUN_SLOTS = 4;
/** The most threads one run can follow. A run covers 900 pixels of thread
 * and a thread grows about three pixels a step. */
export const RUN_THREADS = 512;
/** How far from the mouse threads light, in CSS pixels. */
export const REACH = 160;

/** A number as a WGSL float literal. */
const f = (n: number) => (Number.isInteger(n) ? `${n}.0` : `${n}`);

export const SHADER = /* wgsl */ `
struct Point { pos: vec2f, width: f32, born: f32, parent: i32, hair: u32 }

struct Plane {
	color: vec4f,
	view: vec2f,
	origin: vec2f,
	shrink: f32,
	scale: f32,
	alpha: f32,
	blur: f32,
	upTo: f32,
}

struct Light {
	color: vec4f,
	view: vec2f,
	mouse: vec2f,
	scale: f32,
	hover: f32,
	upTo: f32,
	front: f32,
	count: u32,
	// Each wave: its edge, its reach, and its strength, 0 when the slot is free.
	waves: array<vec4f, ${WAVE_SLOTS}>,
	// Each run: its head, and 1 while it is still running.
	runs: array<vec4f, ${RUN_SLOTS}>,
}

struct RunThread { a: vec2f, b: vec2f, walked: f32 }

@group(0) @binding(0) var<storage, read> points: array<Point>;
@group(0) @binding(1) var<uniform> plane: Plane;
@group(0) @binding(2) var<uniform> light: Light;
@group(0) @binding(3) var<storage, read> along: array<f32>;
@group(0) @binding(4) var<storage, read> runThreads: array<RunThread>;
// The threads this frame's light can reach (lit_threads.ts gathers them).
@group(0) @binding(5) var<storage, read> lit: array<u32>;

struct Stroke {
	@builtin(position) clip: vec4f,
	// Where this fragment is, and the segment's ends, in device pixels.
	@location(0) at: vec2f,
	@location(1) @interpolate(flat) a: vec2f,
	@location(2) @interpolate(flat) b: vec2f,
	// Up to three strokes laid along the segment: each one's strength, and
	// its width in device pixels. The first is the mouse's light, cut to a
	// disc around it, in a pass that has one.
	@location(3) @interpolate(flat) strength: vec3f,
	@location(4) @interpolate(flat) width: vec3f,
	@location(5) @interpolate(flat) sigma: f32,
}

/** A blur's own spread is widened by a pixel's box, whose deviation this is,
 * so a slight blur still has an edge a pixel soft. */
const BOX = 0.28867513;
const OFF = vec4f(2.0, 2.0, 2.0, 1.0);

fn level(strength: f32) -> f32 {
	return (clamp(floor(strength * ${f(LEVELS)}), 0.0, ${f(LEVELS - 1)}) + 1.0) / ${f(LEVELS)};
}

fn toSegment(p: vec2f, a: vec2f, b: vec2f) -> f32 {
	let ab = b - a;
	let t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
	return length(p - a - ab * t);
}

fn erf(x: f32) -> f32 {
	let x2 = x * x;
	let r = sqrt(1.0 - exp(-x2 * (1.2732395 + 0.147 * x2) / (1.0 + 0.147 * x2)));
	return select(-r, r, x >= 0.0);
}

/** How much of a pixel at distance d from the segment a stroke covers. A
 * sharp stroke takes the share of a one-pixel box it overlaps, as a browser
 * draws a line, so a stroke under a pixel wide peaks at its width. A blurred
 * one spreads the same light as a gaussian of \`sigma\` pixels. */
fn cover(d: f32, width: f32, sigma: f32) -> f32 {
	let half = width * 0.5;
	if (sigma <= 0.0) {
		return clamp(min(d + half, 0.5) - max(d - half, -0.5), 0.0, 1.0);
	}
	let k = 0.70710678 / sigma;
	return 0.5 * (erf((half - d) * k) + erf((half + d) * k));
}

/** How much of the pixel a segment \`width\` wide covers when it ends square
 * at both ends: its cover across, times its cover along its own length.
 * Segments drawn this way tile a thread without overlap, so they can add. */
fn squareCover(s: Stroke, width: f32) -> f32 {
	let ab = s.b - s.a;
	let len = length(ab);
	let u = select(vec2f(1.0, 0.0), ab / len, len > 1e-4);
	let p = s.at - s.a;
	let across = dot(p, vec2f(-u.y, u.x));
	return cover(across, width, s.sigma) * cover(dot(p, u) - len * 0.5, len, s.sigma);
}

/** One corner of the quad around a segment, reaching \`extent\` past it. */
fn corner(a: vec2f, b: vec2f, extent: f32, v: u32) -> vec2f {
	var corners = array<vec2f, 6>(
		vec2f(0.0, -1.0), vec2f(1.0, -1.0), vec2f(0.0, 1.0),
		vec2f(0.0, 1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0),
	);
	let c = corners[v];
	let d = b - a;
	let len = length(d);
	let u = select(vec2f(1.0, 0.0), d / len, len > 1e-4);
	let n = vec2f(-u.y, u.x);
	let end = select(a - u * extent, b + u * extent, c.x > 0.5);
	return end + n * (extent * c.y);
}

fn stroke(a: vec2f, b: vec2f, strength: vec3f, width: vec3f, sigma: f32, view: vec2f, v: u32) -> Stroke {
	var o: Stroke;
	let widest = max(max(width.x, width.y), width.z);
	let p = corner(a, b, widest * 0.5 + 1.0 + 3.0 * sigma, v);
	o.clip = vec4f(p.x / view.x * 2.0 - 1.0, 1.0 - p.y / view.y * 2.0, 0.0, 1.0);
	o.at = p;
	o.a = a;
	o.b = b;
	o.strength = strength;
	o.width = width;
	o.sigma = sigma;
	return o;
}

fn culled() -> Stroke {
	var o: Stroke;
	o.clip = OFF;
	return o;
}

/** A thread's own alpha: the finer, the fainter. */
fn weight(width: f32) -> f32 {
	return min(1.0, 0.35 + width * 0.5);
}

@vertex
fn planeVertex(@builtin(vertex_index) v: u32, @builtin(instance_index) i: u32) -> Stroke {
	let pt = points[i];
	if (pt.parent < 0 || pt.born > plane.upTo) { return culled(); }
	let k = plane.scale;
	let a = (points[pt.parent].pos * plane.shrink + plane.origin) * k;
	let b = (pt.pos * plane.shrink + plane.origin) * k;
	let thread = select(pt.width, ${f(HAIR)}, pt.hair != 0u);
	let sigma = select(0.0, sqrt(plane.blur * plane.blur + BOX * BOX), plane.blur > 0.0);
	let strength = vec3f(0.0, plane.alpha * weight(thread), 0.0);
	return stroke(a, b, strength, vec3f(0.0, thread * plane.shrink * k, 0.0), sigma, plane.view * k, v);
}

@fragment
fn planeFragment(s: Stroke) -> @location(0) vec4f {
	let c = cover(toSegment(s.at, s.a, s.b), s.width.y, 0.0) * s.strength.y * plane.color.a;
	return vec4f(plane.color.rgb * c, c);
}

/** A blurred plane's thread. Blurring is linear, so square-ended segments
 * blurred one by one add up to the blur of the whole plane. */
@fragment
fn blurredPlaneFragment(s: Stroke) -> @location(0) vec4f {
	let c = squareCover(s, s.width.y) * s.strength.y * plane.color.a;
	return vec4f(plane.color.rgb * c, c);
}

@vertex
fn lightVertex(@builtin(vertex_index) v: u32, @builtin(instance_index) entry: u32) -> Stroke {
	let i = lit[entry];
	let pt = points[i];
	if (pt.parent < 0) { return culled(); }
	let a = points[pt.parent].pos;
	let b = pt.pos;
	let hair = pt.hair != 0u;
	// Only real threads take the light under the mouse. Lit, the fuzz would
	// fill the disc it is cut to and show its shape.
	var hover = 0.0;
	if (light.hover > 0.0 && !hair && toSegment(light.mouse, a, b) < ${f(REACH)} + 2.0) {
		hover = light.hover * weight(pt.width);
	}
	var front = 0.0;
	let age = light.upTo - pt.born;
	if (light.front > 0.0 && age >= 0.0 && age <= ${f(FRONT)}) {
		front = 0.5 * light.front * level(1.0 - age / ${f(FRONT)});
	}
	var wave = 0.0;
	for (var w = 0u; w < ${WAVE_SLOTS}u; w++) {
		let at = light.waves[w];
		if (at.z <= 0.0) { continue; }
		let d = along[w * light.count + i];
		if (d < 0.0 || d < at.x - ${f(WAVE_BAND)} || d >= at.x) { continue; }
		// Dark where it starts, so the light leaves the touch along the threads
		// and does not pool around it.
		let leaving = min(1.0, d / ${f(WAVE_START)});
		let u = (at.x - d) / ${f(WAVE_BAND)};
		let band = (1.0 - u) * min(1.0, u / ${f(WAVE_RISE)});
		let strength = leaving * leaving * sqrt(1.0 - d / at.y) * band;
		wave += at.z * level(strength);
	}
	// The fuzz glows finer and fainter than the threads it stands on.
	if (hair) { wave *= ${f(HAIR_GLOW)}; }
	if (hover + front + wave <= 0.0) { return culled(); }
	let k = light.scale;
	let width = vec3f(pt.width + 0.5, 1.1, select(1.4, ${f(HAIR_LIT)}, hair)) * k;
	return stroke(a * k, b * k, vec3f(hover, front, wave), width, 0.0, light.view * k, v);
}

@vertex
fn runVertex(@builtin(vertex_index) v: u32, @builtin(instance_index) i: u32) -> Stroke {
	let t = runThreads[i];
	// Each slot holds RUN_THREADS threads, and only a running slot's are drawn.
	let run = light.runs[i / ${RUN_THREADS}u];
	let behind = run.x - t.walked;
	if (behind < 0.0 || behind > ${f(TRAIL)}) { return culled(); }
	// The head is the last stretch of the trail, drawn again wider and fading
	// back from its front, so the light is in the thread rather than a bead
	// laid on it.
	let trail = 0.85 * level(1.0 - behind / ${f(TRAIL)});
	let tip = select(0.0, 0.6 * level(1.0 - behind / ${f(HEAD)}), run.y > 0.0 && behind < ${f(HEAD)});
	let k = light.scale;
	return stroke(t.a * k, t.b * k, vec3f(0.0, trail, tip), vec3f(0.0, 1.2, 2.2) * k, 0.0, light.view * k, v);
}

/** The mouse's light, cut to a soft disc around it. */
fn disc(r: f32) -> f32 {
	if (r < 0.45) { return mix(0.95, 0.5, r / 0.45); }
	return max(0.0, mix(0.5, 0.0, (r - 0.45) / 0.55));
}

/** Light adds, as it does in the world, so only crossing threads brighten. */
@fragment
fn lightFragment(s: Stroke) -> @location(0) vec4f {
	let c = s.strength.y * squareCover(s, s.width.y) + s.strength.z * squareCover(s, s.width.z);
	let lit = min(c, 1.0) * light.color.a;
	return vec4f(light.color.rgb * lit, lit);
}

/** The mouse's light is the lit threads seen through a soft disc, so it is
 * drawn first, a painted stroke like the threads, and the rest adds to it. */
@fragment
fn hoverFragment(s: Stroke) -> @location(0) vec4f {
	let r = distance(s.at / light.scale, light.mouse) / ${f(REACH)};
	let c = s.strength.x * cover(toSegment(s.at, s.a, s.b), s.width.x, 0.0) * disc(r) * light.color.a;
	return vec4f(light.color.rgb * c, c);
}
`;
