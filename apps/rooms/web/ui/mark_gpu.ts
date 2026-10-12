// The shader mark's renderer, and the beats that drive it.
//
// The mark rooms draws is this one, everywhere it appears: the opening
// screen, the session page, and the control that opens the rooms list. What
// is here is the part that turns a moment into a picture: the colours read
// off the page, the beats of the cycle, and the renderer that draws them into
// a target. Putting a mark into a page, with its device and its loop, is
// mark_gpu_live.ts.

import { BLUR, COMPOSITE, SHADER } from "./mark_gpu_shader.ts";

/** The mark's box, plus the air the light needs around it, in the units of
 * the 24-unit box the silhouette fills. The flat drawing in ui/tokens.css was
 * traced out of this frame and states its own share of it in `.mark-piece`,
 * so the two marks stand in the same place. This one keeps more air around
 * the mushroom, because light that disperses through a volume needs room to
 * run out in, where a drawn ray only needs room to end. The canvas
 * hangs around its element by these numbers, and the shader places the
 * mushroom inside the canvas by the same ones, so the element stays the size
 * of the mushroom whatever the light does. */
export const VIEW = { x: -20, y: -30, w: 64, h: 62 };

/** One cycle of the opening screen's play, in seconds: grow, strike, stand,
 * fade. */
export const CYCLE = 2;

/** The cycle's beats, as fractions of it. The stem is drawn up out of the
 * foot, the cap springs open from the brim while the stem is still rising,
 * the light strikes like a tube and is caught, settles to the level it runs
 * at, and the mark stands lit until the fade. */
export const BEAT = {
	stemFrom: 0.05,
	stemTo: 0.16,
	capFrom: 0.1,
	capTo: 0.27,
	caught: 0.375,
	held: 0.4,
	settled: 0.58,
	standing: 0.9,
};

/** Ten vec4s. The shader's uniform block is the same ten in the same
 * order, and neither side may grow without the other. */
const UNIFORM_FLOATS = 40;

export type Colours = {
	light: [number, number, number];
	rim: [number, number, number];
	fill: [number, number, number];
	flare: [number, number, number];
	accent: [number, number, number];
	/** The dark page: the night the mark is drawn in, whatever the theme. */
	night: [number, number, number];
	/** The page behind the mark. Its brightness decides whether the
	 * air is drawn as light over a dark page or as teal ink over a light one. */
	paper: [number, number, number];
};

/** Custom properties hold tokens, not colours: `color-mix()` in one of them is
 * still `color-mix()` when it is read back. So the value is resolved the only
 * way a page can resolve it, by asking for the computed `color` of something
 * painted with it. */
export function readColours(host: HTMLElement): Colours {
	const probe = document.createElement("span");
	probe.style.position = "absolute";
	probe.style.opacity = "0";
	probe.style.pointerEvents = "none";
	host.appendChild(probe);
	const read = (token: string): [number, number, number] => {
		probe.style.color = "";
		probe.style.color = `var(${token})`;
		const resolved = getComputedStyle(probe).color;
		const parts = resolved.match(/[\d.]+/g);
		if (parts == null || parts.length < 3) return [1, 1, 1];
		// A mix resolves to `color(srgb r g b)` with the channels already in
		// zero to one, while a plain colour resolves to `rgb(r g b)` in bytes.
		// Reading the second as the first is the difference between the drawing
		// and a black hole, so the form is what decides the divisor.
		const scale = resolved.startsWith("color(") ? 1 : 255;
		return [
			Number(parts[0]) / scale,
			Number(parts[1]) / scale,
			Number(parts[2]) / scale,
		];
	};
	// The mushroom is a thing seen at night: its flesh and rims are the dark
	// theme's in both themes. `light-dark()` resolves against the element
	// that uses the token, so a probe that declares itself dark reads the
	// night palette while the page around it stays whatever it is. The light
	// is the page's own: teal by night, and by day white lamps with teal ink
	// for the air, because light added over cream can only come out grey.
	probe.style.colorScheme = "dark";
	const colours: Colours = {
		light: [1, 1, 1],
		rim: read("--accent-deep"),
		fill: read("--mark-fill"),
		flare: [1, 1, 1],
		accent: read("--accent"),
		night: read("--paper"),
		paper: [0, 0, 0],
	};
	probe.style.colorScheme = "";
	colours.light = read("--mark-light");
	colours.flare = read("--teal-ink");
	colours.paper = read("--paper");
	probe.remove();
	return colours;
}

/** Smoothstep, because the beats below are shaped rather than linear. */
function ease(a: number, b: number, x: number): number {
	if (b <= a) return x < a ? 0 : 1;
	const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
	return t * t * (3 - 2 * t);
}

/** A rise that overshoots and settles, so what arrives has mass.
 *
 * A smoothstep arrives and stops, which reads as a shape being revealed. A cap
 * that opens has weight in it: it goes past where it is going, comes back, and
 * only then is still. This is a damped oscillator, so the overshoot and the
 * settle are the same fact rather than two curves stitched together, and the
 * decay is stiff enough that it lands within its own beat.
 */
function spring(from: number, to: number, x: number): number {
	if (x <= from) return 0;
	const t = (x - from) / Math.max(to - from, 0.0001);
	if (t > 4) return 1;
	return 1 - Math.exp(-4.2 * t) * Math.cos(1.7 * Math.PI * t);
}

/** A knock: nothing, then a wobble that rings down to nothing again.
 *
 * This is not the same shape as `spring`, and using that one here was a real
 * mistake: a rise-and-settle starts fully un-arrived, so applied as a jolt it
 * began by stretching the cap into a bullet before it ever wobbled. An impulse
 * starts at rest, and an already-standing mushroom being shoved by its own
 * light starts at rest.
 */
function kick(at: number, span: number, x: number): number {
	if (x <= at) return 0;
	const t = (x - at) / span;
	if (t > 4) return 0;
	return Math.exp(-3.0 * t) * Math.sin(2.4 * Math.PI * t);
}

/** The blinks are held and snapped rather than faded, the way a tube strikes,
 * so this is a lookup rather than a curve. Percentages are of the cycle and
 * they are the ones in boot.css. */
function emission(f: number): number {
	if (f < 0.315) return 0;
	if (f < 0.33) return 1;
	if (f < 0.345) return 0.08;
	if (f < 0.36) return 0.95;
	if (f < BEAT.caught) return 0.15;
	if (f < BEAT.held) return 1;
	if (f < BEAT.settled) return 1 - 0.4 * ease(BEAT.held, BEAT.settled, f);
	if (f < BEAT.standing) return 0.6;
	return 0.6 * (1 - ease(BEAT.standing, 1, f));
}

/** The rims take the light's colour one frame ahead of it: a tube's glass goes
 * before its room does. */
function flare(f: number): number {
	if (f < 0.2925) return 0;
	if (f < 0.3075) return 1;
	if (f < 0.3225) return 0;
	if (f < 0.3375) return 1;
	if (f < 0.3525) return 0;
	if (f < BEAT.held) return 1;
	// Back to amber fast. Teal and amber sit across from each other, so the
	// straight line between them runs through a dead khaki, and a slow return
	// parks the whole cap in it, since the flare colours the whole cap.
	return 1 - ease(BEAT.held, 0.435, f);
}

/** The beams last: nothing is outside the cap until the strike has let go. */
function reach(f: number): number {
	if (f < 0.41) return 0;
	return ease(0.41, 0.52, f) *
		Math.max(emission(f), 0.6 * (1 - ease(BEAT.standing, 1, f)));
}

/** Everything the shader is told about one frame, beyond the colours. Kept
 * as its own step so a harness can ask for a frozen frame and get exactly the
 * numbers the live loop would have sent. */
export type Beats = {
	stem: number;
	cap: number;
	glow: number;
	rays: number;
	flare: number;
	breath: number;
	squash: number;
	bob: number;
};

export function beats(frame: number, seconds: number, still: boolean): Beats {
	const stemNow = spring(BEAT.stemFrom, BEAT.stemTo, frame);
	const capNow = spring(BEAT.capFrom, BEAT.capTo, frame);
	// The overshoot itself, handed on as squash: a cap that throws itself open
	// is wider and flatter at the top of its travel and narrower and taller on
	// the way back. Reading it off the spring keeps the two in step.
	let squash = capNow - 1;
	// The whole mushroom settles on its own foot a beat later, which is the
	// weight arriving rather than the shape.
	let bob = (spring(BEAT.capFrom + 0.04, BEAT.capTo + 0.04, frame) - 1) * 0.11;
	// The strike is an event the body feels: it flinches and rings down.
	const jolt = kick(0.315, 0.16, frame);
	squash += jolt * 0.17;
	bob -= jolt * 0.07;
	// A fluorescent tube is never quite steady. A small fast wobble on the
	// emission, held for a few frames at a time, is what says "tube" to an eye
	// without ever being seen as a flicker.
	let glow = emission(frame);
	if (!still) {
		const tick = Math.floor(seconds * 26);
		const buzz = ((Math.sin(tick * 12.9898) * 43758.5453) % 1 + 1) % 1;
		glow *= 0.93 + 0.07 * buzz;
		bob += Math.sin(seconds * 1.9) * 0.022;
		squash += Math.sin(seconds * 1.9 + 0.7) * 0.016;
	}
	return {
		stem: stemNow,
		cap: capNow,
		glow,
		rays: reach(frame),
		flare: flare(frame),
		breath: still ? 0 : 1,
		squash,
		bob,
	};
}

/** The bloom's knobs: the two blurs' widths as fractions of the target's
 * height, the brightness a pixel must reach to radiate, and how much each
 * blur adds back. Fractions, so a glow is the same size relative to the mark
 * at every size the mark is drawn: at forty-eight pixels a fixed texel radius
 * was a halo three pixels wide, which is not a halo. */
// The threshold sits above one: the scene pass is HDR, and only
// the light goes past one. The body never blooms, so the mark stays a crisp
// glyph with light coming off it rather than a warm smudge.
const BLOOM = { core: 0.012, halo: 0.05, threshold: 1.05, coreStrength: 0.7, haloStrength: 0.8 };

/** Draws the mark into any target: a float scene pass, four half-size blur
 * passes that make the two blooms, and a composite. The canvas loop in
 * `start` is one user. The size proofs are another, and both get the same
 * pixels because there is one of these. */
export class Renderer {
	readonly #device: GPUDevice;
	readonly #scenePipe: GPURenderPipeline;
	readonly #blurPipe: GPURenderPipeline;
	readonly #postPipe: GPURenderPipeline;
	readonly #uniforms: GPUBuffer;
	readonly #blurs: GPUBuffer[];
	readonly #post: GPUBuffer;
	readonly #sceneBind: GPUBindGroup;
	readonly #sampler: GPUSampler;
	readonly #values = new Float32Array(UNIFORM_FLOATS);
	#scene: GPUTexture | null = null;
	/** Half-size ping-pong targets: the core bloom ends in the second, the
	 * halo in the third, and the first is scratch between directions. */
	#half: GPUTexture[] = [];
	#blurBinds: GPUBindGroup[] = [];
	#postBind: GPUBindGroup | null = null;
	#width = 0;
	#height = 0;

	constructor(device: GPUDevice, format: GPUTextureFormat) {
		this.#device = device;
		const scene = device.createShaderModule({ code: SHADER });
		this.#scenePipe = device.createRenderPipeline({
			layout: "auto",
			vertex: { module: scene, entryPoint: "vs" },
			fragment: { module: scene, entryPoint: "fs", targets: [{ format: "rgba16float" }] },
			primitive: { topology: "triangle-list" },
		});
		const blur = device.createShaderModule({ code: BLUR });
		this.#blurPipe = device.createRenderPipeline({
			layout: "auto",
			vertex: { module: blur, entryPoint: "vs" },
			fragment: { module: blur, entryPoint: "fs", targets: [{ format: "rgba16float" }] },
			primitive: { topology: "triangle-list" },
		});
		const post = device.createShaderModule({ code: COMPOSITE });
		this.#postPipe = device.createRenderPipeline({
			layout: "auto",
			vertex: { module: post, entryPoint: "vs" },
			fragment: {
				module: post,
				entryPoint: "fs",
				targets: [{
					format,
					blend: {
						color: { srcFactor: "one", dstFactor: "one-minus-src-alpha" },
						alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha" },
					},
				}],
			},
			primitive: { topology: "triangle-list" },
		});
		this.#uniforms = device.createBuffer({
			size: UNIFORM_FLOATS * 4,
			usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
		});
		this.#post = device.createBuffer({
			size: 8 * 4,
			usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
		});
		this.#blurs = [0, 1, 2, 3].map(() =>
			device.createBuffer({
				size: 8 * 4,
				usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
			})
		);
		this.#sceneBind = device.createBindGroup({
			layout: this.#scenePipe.getBindGroupLayout(0),
			entries: [{ binding: 0, resource: { buffer: this.#uniforms } }],
		});
		this.#sampler = device.createSampler({ magFilter: "linear", minFilter: "linear" });
	}

	/** The scene target follows the output size. Recreated only on change,
	 * because a texture a frame is a leak the collector never keeps up with. */
	#fit(width: number, height: number): void {
		if (width === this.#width && height === this.#height && this.#scene != null) return;
		this.#scene?.destroy();
		for (const t of this.#half) t.destroy();
		this.#width = width;
		this.#height = height;
		const make = (w: number, h: number) =>
			this.#device.createTexture({
				size: [w, h],
				format: "rgba16float",
				usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING,
			});
		this.#scene = make(width, height);
		const hw = Math.max(1, Math.ceil(width / 2));
		const hh = Math.max(1, Math.ceil(height / 2));
		this.#half = [make(hw, hh), make(hw, hh), make(hw, hh)];
		// Across the scene into scratch, down into the core; across the core
		// into scratch, down into the halo.
		const sources = [this.#scene, this.#half[0], this.#half[1], this.#half[0]];
		this.#blurBinds = sources.map((src, i) =>
			this.#device.createBindGroup({
				layout: this.#blurPipe.getBindGroupLayout(0),
				entries: [
					{ binding: 0, resource: src.createView() },
					{ binding: 1, resource: this.#sampler },
					{ binding: 2, resource: { buffer: this.#blurs[i] } },
				],
			})
		);
		const coreSigma = BLOOM.core * hh;
		// The halo blurs what is already blurred, and widths add in quadrature.
		const haloSigma = Math.sqrt(Math.max((BLOOM.halo * hh) ** 2 - coreSigma ** 2, 0.25));
		// Each width is in its source's texels, and the first pass reads the
		// full-size scene.
		const passes = [
			[1, 0, coreSigma * 2, BLOOM.threshold],
			[0, 1, coreSigma, -1],
			[1, 0, haloSigma, -1],
			[0, 1, haloSigma, -1],
		];
		passes.forEach(([dx, dy, sigma, threshold], i) => {
			this.#device.queue.writeBuffer(
				this.#blurs[i],
				0,
				new Float32Array([hw, hh, dx, dy, sigma, threshold, 0, 0]),
			);
		});
		this.#postBind = this.#device.createBindGroup({
			layout: this.#postPipe.getBindGroupLayout(0),
			entries: [
				{ binding: 0, resource: this.#scene.createView() },
				{ binding: 1, resource: this.#sampler },
				{ binding: 2, resource: { buffer: this.#post } },
				{ binding: 3, resource: this.#half[1].createView() },
				{ binding: 4, resource: this.#half[2].createView() },
			],
		});
	}

	draw(
		target: GPUTextureView,
		width: number,
		height: number,
		seconds: number,
		colours: Colours,
		b: Beats,
		oversample = 1,
	): void {
		this.#fit(width, height);
		const aspect = width / Math.max(height, 1);
		const boxAspect = VIEW.w / VIEW.h;
		let vw = VIEW.w;
		let vh = VIEW.h;
		if (aspect > boxAspect) vw = VIEW.h * aspect;
		else vh = VIEW.w / aspect;
		const v = this.#values;
		v.set([width, height, seconds, oversample], 0);
		v.set([VIEW.x + (VIEW.w - vw) / 2, VIEW.y + (VIEW.h - vh) / 2, vw, vh], 4);
		v.set([...colours.light, 1], 8);
		v.set([...colours.rim, 1], 12);
		v.set([...colours.fill, 1], 16);
		v.set([...colours.flare, 1], 20);
		v.set([b.stem, b.cap, b.glow, b.rays], 24);
		v.set([b.flare, b.breath, b.squash, b.bob], 28);
		v.set([...colours.accent, 1], 32);
		// The night palette, and how bright the page it sits on is: light on
		// a dark page and ink on a light one are drawn differently, and both
		// passes need to know which they are on.
		const [pr, pg, pb] = colours.paper;
		const paperLum = 0.2126 * pr + 0.7152 * pg + 0.0722 * pb;
		v.set([...colours.night, paperLum], 36);
		this.#device.queue.writeBuffer(this.#uniforms, 0, v);
		const lightPage = ease(0.3, 0.8, paperLum);
		this.#device.queue.writeBuffer(
			this.#post,
			0,
			new Float32Array([width, height, lightPage, 0, BLOOM.coreStrength, BLOOM.haloStrength, 0, 0]),
		);

		const encoder = this.#device.createCommandEncoder();
		const clear = { r: 0, g: 0, b: 0, a: 0 };
		const scenePass = encoder.beginRenderPass({
			colorAttachments: [{
				view: this.#scene!.createView(),
				clearValue: clear,
				loadOp: "clear",
				storeOp: "store",
			}],
		});
		scenePass.setPipeline(this.#scenePipe);
		scenePass.setBindGroup(0, this.#sceneBind);
		scenePass.draw(3);
		scenePass.end();
		const targets = [this.#half[0], this.#half[1], this.#half[0], this.#half[2]];
		targets.forEach((tex, i) => {
			const pass = encoder.beginRenderPass({
				colorAttachments: [{ view: tex.createView(), clearValue: clear, loadOp: "clear", storeOp: "store" }],
			});
			pass.setPipeline(this.#blurPipe);
			pass.setBindGroup(0, this.#blurBinds[i]);
			pass.draw(3);
			pass.end();
		});
		const postPass = encoder.beginRenderPass({
			colorAttachments: [{ view: target, clearValue: clear, loadOp: "clear", storeOp: "store" }],
		});
		postPass.setPipeline(this.#postPipe);
		postPass.setBindGroup(0, this.#postBind!);
		postPass.draw(3);
		postPass.end();
		this.#device.queue.submit([encoder.finish()]);
	}

	destroy(): void {
		this.#scene?.destroy();
		for (const t of this.#half) t.destroy();
		this.#uniforms.destroy();
		this.#post.destroy();
		for (const b of this.#blurs) b.destroy();
	}
}
