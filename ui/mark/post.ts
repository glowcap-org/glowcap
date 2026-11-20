// The passes after the scene: the two blooms and the composite.

/** One direction of a Gaussian blur, with the bright pass folded into the
 * first one.
 *
 * Everything bright in the scene radiates. That is not a metaphor here, it is
 * a blur: what is above a threshold is spread out and added back on top, so
 * a glow comes off the thing instead of being drawn around it. A blur whose
 * taps step past texels is not a blur, it is a few faint copies of the
 * picture, and on a drawing that is mostly one thin bright line those copies
 * show as a ghost of the line beside it, or as stripes under it. So this is
 * a true Gaussian, run once across and once down, at half the scene's size
 * where the taps are cheap and the result is smooth. The pass runs twice
 * over: a tight blur for the hot core of a fluorescent source, then a wide
 * one over that for the halo. */
export const BLUR = `
@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var samp: sampler;

struct Blur {
	size: vec4f,
	knobs: vec4f,
};
@group(0) @binding(2) var<uniform> blur: Blur;

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
	var p = array<vec2f, 3>(vec2f(-1.0, -3.0), vec2f(-1.0, 1.0), vec2f(3.0, 1.0));
	return vec4f(p[i], 0.0, 1.0);
}

fn bright(c: vec4f, threshold: f32) -> vec4f {
	if (threshold < 0.0) { return c; }
	let l = max(max(c.r, c.g), c.b);
	return c * smoothstep(threshold, threshold + 0.45, l);
}

@fragment
fn fs(@builtin(position) coord: vec4f) -> @location(0) vec4f {
	let uv = coord.xy / blur.size.xy;
	let srcSize = vec2f(textureDimensions(src));
	let sigma = max(blur.knobs.x, 0.5);
	// Taps over three sigmas each side, which is the whole curve, spaced as
	// the renderer says: never wider than the finest detail the source
	// holds, or a thin bright line comes out as a stack of faint copies.
	let spacing = blur.knobs.z;
	let unit = blur.size.zw / srcSize;
	// Where taps are a texel apart, one sample between two of them reads
	// both at the weights the curve gives them, so it takes two taps. A
	// bright pass has to see each texel alone, so it takes one.
	let per = select(1.0, 2.0, spacing == 1.0 && blur.knobs.y < 0.0);
	let samples = i32(ceil(blur.knobs.w / per));
	var sum = bright(textureSample(src, samp, uv), blur.knobs.y);
	var weight = 1.0;
	for (var i = 1; i <= samples; i = i + 1) {
		let d = (f32(i) * per - per + 1.0) * spacing;
		let near = exp(-d * d / (2.0 * sigma * sigma));
		let far = exp(-(d + spacing) * (d + spacing) / (2.0 * sigma * sigma)) * (per - 1.0);
		let w = near + far;
		let off = unit * (d + spacing * far / w);
		sum = sum + (bright(textureSample(src, samp, uv + off), blur.knobs.y) +
			bright(textureSample(src, samp, uv - off), blur.knobs.y)) * w;
		weight = weight + 2.0 * w;
	}
	return sum / weight;
}
`;

/** The last pass: the scene, its two blooms, tone, and the hand-off to the
 * canvas. */
export const COMPOSITE = `
@group(0) @binding(0) var scene: texture_2d<f32>;
@group(0) @binding(1) var samp: sampler;

struct Post {
	size: vec4f,
	knobs: vec4f,
};
@group(0) @binding(2) var<uniform> post: Post;
@group(0) @binding(3) var core: texture_2d<f32>;
@group(0) @binding(4) var halo: texture_2d<f32>;

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
	var p = array<vec2f, 3>(vec2f(-1.0, -3.0), vec2f(-1.0, 1.0), vec2f(3.0, 1.0));
	return vec4f(p[i], 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) coord: vec4f) -> @location(0) vec4f {
	let uv = coord.xy / post.size.xy;
	let base = textureSample(scene, samp, uv);

	// A small target blooms less, or the light buries the line it is meant
	// to be coming off. Measured on the target's height so it follows size.
	let scale = mix(0.55, 1.0, smoothstep(180.0, 560.0, post.size.y));
	let glow = textureSample(core, samp, uv).rgb * post.knobs.x * scale +
		textureSample(halo, samp, uv).rgb * post.knobs.y * scale;
	// By day the glow is screened on: added to cream it goes white and clips
	// to a hard edge, where screened it rolls off and keeps its cyan. Less
	// of it lands on the body, so the mark keeps its colours under it.
	let dayGlow = (vec3f(1.0) - exp(-glow * 1.8)) * (1.0 - base.a * 0.3);
	let lit = mix(glow, dayGlow, post.size.z);
	var col = mix(base.rgb + glow, base.rgb + dayGlow * (vec3f(1.0) - base.rgb), post.size.z);
	var alpha = base.a;
	// Coverage is the glow's own brightness, no more: padded coverage is
	// invisible over a dark page and a grey fog over a light one.
	alpha = max(alpha, min(max(max(lit.r, lit.g), lit.b), 1.0));

	// Soft shoulder so a beam's core goes white-hot instead of clipping to a
	// flat plate, and stays inside the alpha it has. By day there is no
	// white-hot to shoulder: the same curve would only pull a white lamp
	// down to grey on cream, so it eases off with the page's brightness.
	col = col / (vec3f(1.0) + col * 0.32 * (1.0 - post.size.z));
	col = min(col, vec3f(alpha));
	// A soft glow spread thin over a page lands on a handful of the target's
	// 256 levels and shows as rings. Half a level of noise breaks them up.
	// It fades out as coverage does, so bare page stays bare.
	let n = (fract(52.9829189 * fract(dot(coord.xy, vec2f(0.06711056, 0.00583715)))) - 0.5) / 255.0 *
		min(alpha * 255.0, 1.0);
	alpha = clamp(alpha + n, 0.0, 1.0);
	col = clamp(col + vec3f(n), vec3f(0.0), vec3f(alpha));
	return vec4f(col, alpha);
}
`;
