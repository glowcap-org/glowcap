// The mycelium on the GPU. Each plane's points go up once, when the network
// grows, and every frame after that is a few numbers: how far growth has
// reached, where the mouse is, and where each wave and run of light has got
// to. shader.ts lights the threads from them, lit_threads.ts narrows each
// frame's light to the threads it can reach, and live.ts decides when a
// frame is drawn.

/// <reference lib="dom" />

import { gatherPipeline, LitThreads } from "./lit_threads.ts";
import { firstBorn, type Network } from "./network.ts";
import { RUN_SLOTS, RUN_THREADS, SHADER, WAVE_SLOTS } from "./shader.ts";

/** A straight (not premultiplied) color, each channel from 0 to 1. */
export type Rgba = readonly [number, number, number, number];

/** A canvas the mycelium draws on: its context, its size in CSS pixels, and
 * how far it reaches past the window's edges. */
export interface Sheet {
	context: GPUCanvasContext;
	w: number;
	h: number;
	bleed: number;
}

/** How a plane is drawn: on which sheet, shrunk by how much from the size it
 * grew at, how faint, and how blurred, in device pixels. */
export interface PlaneLook {
	sheet: number;
	shrink: number;
	alpha: number;
	blur: number;
}

/** One frame of light. `hover` and `front` are strengths, 0 when off. Each
 * wave and run names the slot its layout was written to. */
export interface LightFrame {
	mouse: { x: number; y: number };
	hover: number;
	upTo: number;
	front: number;
	waves: readonly { slot: number; edge: number; reach: number; strength: number }[];
	runs: readonly { slot: number; head: number; running: boolean }[];
}

/** Words in one point and one run thread, as the shader lays them out. A
 * run thread holds five, and a sixth pads it to its eight-byte alignment. */
const POINT_WORDS = 6;
const RUN_WORDS = 6;
const PLANE_BYTES = 64;
const LIGHT_BYTES = 192;

interface PlaneBuffers {
	net: Network;
	points: GPUBuffer;
	uniform: GPUBuffer;
	group: GPUBindGroup;
}

export class GroundRenderer {
	readonly #device: GPUDevice;
	readonly #plane: GPURenderPipeline;
	readonly #blurredPlane: GPURenderPipeline;
	readonly #planeLayout: GPUBindGroupLayout;
	readonly #hover: GPURenderPipeline;
	readonly #light: GPURenderPipeline;
	readonly #run: GPURenderPipeline;
	readonly #lightUniform: GPUBuffer;
	readonly #runThreads: GPUBuffer;
	/** How many threads each run slot holds. */
	readonly #runLengths = new Array<number>(RUN_SLOTS).fill(0);
	readonly #gather: GPUComputePipeline;
	#lit: LitThreads | null = null;
	#planes: PlaneBuffers[] = [];
	#along: GPUBuffer | null = null;
	#lightGroup: GPUBindGroup | null = null;
	readonly #runGroup: GPUBindGroup;
	#focus = 0;

	constructor(device: GPUDevice, format: GPUTextureFormat) {
		this.#device = device;
		const module = device.createShaderModule({ code: SHADER });
		// The brightest stroke wins at each pixel. Strokes of one color then
		// union the way one stroked path does, with no bead where segments meet.
		const brightest: GPUBlendComponent = { operation: "max", srcFactor: "one", dstFactor: "one" };
		// A blurred plane's halos overlap, and light crossing light adds.
		const adding: GPUBlendComponent = { operation: "add", srcFactor: "one", dstFactor: "one" };
		const pipeline = (
			vertex: string,
			fragment: string,
			blend = brightest,
			layout: GPUPipelineLayout | "auto" = "auto",
		) => device.createRenderPipeline({
			layout,
			vertex: { module, entryPoint: vertex },
			fragment: {
				module,
				entryPoint: fragment,
				targets: [{ format, blend: { color: blend, alpha: blend } }],
			},
			primitive: { topology: "triangle-list" },
		});
		// Both plane pipelines read one bind group per plane, so they share a
		// layout.
		this.#planeLayout = device.createBindGroupLayout({
			entries: [
				{ binding: 0, visibility: GPUShaderStage.VERTEX, buffer: { type: "read-only-storage" } },
				{
					binding: 1,
					visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
					buffer: { type: "uniform" },
				},
			],
		});
		const planes = device.createPipelineLayout({ bindGroupLayouts: [this.#planeLayout] });
		this.#plane = pipeline("planeVertex", "planeFragment", brightest, planes);
		this.#blurredPlane = pipeline("planeVertex", "blurredPlaneFragment", adding, planes);
		// The hover and the light it underlies read one bind group, so they share
		// a layout too.
		const lit = device.createPipelineLayout({
			bindGroupLayouts: [device.createBindGroupLayout({
				entries: [
					{ binding: 0, visibility: GPUShaderStage.VERTEX, buffer: { type: "read-only-storage" } },
					{
						binding: 2,
						visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
						buffer: { type: "uniform" },
					},
					{ binding: 3, visibility: GPUShaderStage.VERTEX, buffer: { type: "read-only-storage" } },
					{ binding: 5, visibility: GPUShaderStage.VERTEX, buffer: { type: "read-only-storage" } },
				],
			})],
		});
		this.#gather = gatherPipeline(device);
		this.#hover = pipeline("lightVertex", "hoverFragment", brightest, lit);
		this.#light = pipeline("lightVertex", "lightFragment", adding, lit);
		this.#run = pipeline("runVertex", "lightFragment", adding);
		this.#lightUniform = device.createBuffer({
			size: LIGHT_BYTES,
			usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
		});
		this.#runThreads = device.createBuffer({
			size: RUN_SLOTS * RUN_THREADS * RUN_WORDS * 4,
			usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
		});
		this.#runGroup = device.createBindGroup({
			layout: this.#run.getBindGroupLayout(0),
			entries: [
				{ binding: 2, resource: { buffer: this.#lightUniform } },
				{ binding: 4, resource: { buffer: this.#runThreads } },
			],
		});
	}

	/** Put a newly grown network on the GPU, every plane of it, with the
	 * light running through plane `focus`. The previous one is released. */
	load(planes: readonly Network[], focus: number): void {
		this.#release();
		const device = this.#device;
		this.#focus = focus;
		this.#planes = planes.map((net) => {
			const words = new ArrayBuffer(Math.max(1, net.count) * POINT_WORDS * 4);
			const f = new Float32Array(words);
			const n = new Int32Array(words);
			for (let i = 0; i < net.count; i++) {
				const at = i * POINT_WORDS;
				f[at] = net.x[i];
				f[at + 1] = net.y[i];
				f[at + 2] = net.width[i];
				f[at + 3] = net.born[i];
				n[at + 4] = net.parent[i];
				n[at + 5] = net.hair[i];
			}
			const points = device.createBuffer({
				size: words.byteLength,
				usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
			});
			device.queue.writeBuffer(points, 0, words);
			const uniform = device.createBuffer({
				size: PLANE_BYTES,
				usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
			});
			const group = device.createBindGroup({
				layout: this.#planeLayout,
				entries: [
					{ binding: 0, resource: { buffer: points } },
					{ binding: 1, resource: { buffer: uniform } },
				],
			});
			return { net, points, uniform, group };
		});
		const lit = this.#planes[focus];
		this.#lit = new LitThreads(device, this.#gather, lit.net);
		// Every wave slot holds one distance per point. A free slot is never
		// read, so the buffer starts as it comes.
		this.#along = device.createBuffer({
			size: WAVE_SLOTS * Math.max(1, lit.net.count) * 4,
			usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
		});
		this.#lightGroup = device.createBindGroup({
			layout: this.#light.getBindGroupLayout(0),
			entries: [
				{ binding: 0, resource: { buffer: lit.points } },
				{ binding: 2, resource: { buffer: this.#lightUniform } },
				{ binding: 3, resource: { buffer: this.#along } },
				{ binding: 5, resource: { buffer: this.#lit.list } },
			],
		});
	}

	/** Write a wave's layout (light.ts `waveAlong`) to `slot`. */
	setWave(slot: number, along: Float32Array): void {
		if (this.#along === null || this.#lit === null) return;
		this.#device.queue.writeBuffer(this.#along, slot * this.#planes[this.#focus].net.count * 4, along);
		this.#lit.setWave(slot, along);
	}

	/** Write a run's threads (light.ts `runAlong`) to `slot`.
	 * False, with nothing written, for a run longer than a slot holds. */
	setRun(slot: number, threads: Float32Array): boolean {
		const count = threads.length / 5;
		if (count > RUN_THREADS) return false;
		const f = new Float32Array(count * RUN_WORDS);
		for (let k = 0; k < count; k++) f.set(threads.subarray(k * 5, k * 5 + 5), k * RUN_WORDS);
		this.#device.queue.writeBuffer(this.#runThreads, slot * RUN_THREADS * RUN_WORDS * 4, f);
		this.#runLengths[slot] = count;
		return true;
	}

	/** Draw every plane, each up to growth step `upTo[k]`, on its sheet. */
	paint(sheets: readonly Sheet[], looks: readonly PlaneLook[], upTo: readonly number[], color: Rgba, scale: number) {
		const queue = this.#device.queue;
		const encoder = this.#device.createCommandEncoder();
		sheets.forEach((sheet, s) => {
			const pass = begin(encoder, sheet);
			looks.forEach((look, k) => {
				if (look.sheet !== s) return;
				pass.setPipeline(look.blur > 0 ? this.#blurredPlane : this.#plane);
				const plane = this.#planes[k];
				const u = new Float32Array(PLANE_BYTES / 4);
				u.set(color, 0);
				u.set(
					[sheet.w, sheet.h, sheet.bleed, sheet.bleed, look.shrink, scale, look.alpha, look.blur, upTo[k]],
					4,
				);
				queue.writeBuffer(plane.uniform, 0, u);
				pass.setBindGroup(0, plane.group);
				pass.draw(6, firstBorn(plane.net, upTo[k] + 1));
			});
			pass.end();
		});
		queue.submit([encoder.finish()]);
	}

	/** Draw one frame of light on `sheet`. */
	light(sheet: Sheet, frame: LightFrame, color: Rgba, scale: number): void {
		if (this.#lightGroup === null || this.#lit === null) return;
		const words = new ArrayBuffer(LIGHT_BYTES);
		const f = new Float32Array(words);
		f.set(color, 0);
		f.set([sheet.w, sheet.h, frame.mouse.x, frame.mouse.y, scale, frame.hover, frame.upTo, frame.front], 4);
		new Uint32Array(words)[12] = this.#planes[this.#focus].net.count;
		for (const w of frame.waves) f.set([w.edge, w.reach, w.strength], 16 + w.slot * 4);
		for (const r of frame.runs) f.set([r.head, r.running ? 1 : 0], 16 + WAVE_SLOTS * 4 + r.slot * 4);
		this.#device.queue.writeBuffer(this.#lightUniform, 0, words);
		const encoder = this.#device.createCommandEncoder();
		this.#lit.gather(encoder, frame);
		const pass = begin(encoder, sheet);
		pass.setBindGroup(0, this.#lightGroup);
		if (frame.hover > 0) {
			pass.setPipeline(this.#hover);
			pass.drawIndirect(this.#lit.args, 0);
		}
		pass.setPipeline(this.#light);
		pass.drawIndirect(this.#lit.args, 0);
		if (frame.runs.length > 0) {
			pass.setPipeline(this.#run);
			pass.setBindGroup(0, this.#runGroup);
			for (const run of frame.runs) pass.draw(6, this.#runLengths[run.slot], 0, run.slot * RUN_THREADS);
		}
		pass.end();
		this.#device.queue.submit([encoder.finish()]);
	}

	/** Release every buffer. The device is the page's and stays. */
	destroy(): void {
		this.#release();
		this.#lightUniform.destroy();
		this.#runThreads.destroy();
	}

	#release() {
		for (const plane of this.#planes) {
			plane.points.destroy();
			plane.uniform.destroy();
		}
		this.#planes = [];
		this.#along?.destroy();
		this.#along = null;
		this.#lit?.destroy();
		this.#lit = null;
		this.#lightGroup = null;
	}
}

/** A pass over a sheet's next texture, cleared to nothing. */
function begin(encoder: GPUCommandEncoder, sheet: Sheet): GPURenderPassEncoder {
	return encoder.beginRenderPass({
		colorAttachments: [{
			view: sheet.context.getCurrentTexture().createView(),
			clearValue: { r: 0, g: 0, b: 0, a: 0 },
			loadOp: "clear",
			storeOp: "store",
		}],
	});
}
