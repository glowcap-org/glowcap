// Which of the focal plane's threads a frame of light can reach. Light falls
// on few of them: those near the mouse, those born just behind the growing
// front, and those in each wave's band. A frame names them as a few ranges,
// each in an order where its threads sit together, and a compute pass gathers
// those ranges into one list with every thread on it once. The light is then
// drawn over that list, with the same light for each thread as over the
// whole plane, so a thread left off it is one the light would not have
// touched.
//
// Three orders hold the ranges:
//
// - growth order, the network's own, where the threads born in a span of
//   steps sit together
// - cell order, the threads sorted into square cells by the point that ends
//   them, so a row of cells around the mouse is one range
// - each wave's order, the threads it reaches sorted by how far along the
//   threads it reaches them, so its band is one range

/// <reference lib="dom" />

import { FRONT, WAVE_BAND } from "./light.ts";
import { firstAtLeast, firstBorn, type Network } from "./network.ts";
import { REACH, WAVE_SLOTS } from "./shader.ts";
import type { LightFrame } from "./renderer.ts";

/** The side of a cell, in CSS pixels. */
const CELL = 64;
/** The most ranges one frame gathers. A frame that needs more gathers the
 * whole plane instead. */
const MAX_RANGES = 16;
const GATHER_BYTES = 16 + MAX_RANGES * 16;
const WORKGROUP = 64;
/** How far past each end a wave's band is gathered, in pixels of thread, so
 * rounding between here and the shader never leaves a thread out. */
const BAND_SLACK = 1;
/** A wave's sort keys: distance steps per pixel, and room for every thread
 * index below them. Both stay far inside a double's exact integers. */
const STEPS = 16;
const THREADS = 2 ** 24;

const GATHER = /* wgsl */ `
struct Args { vertices: u32, instances: atomic<u32>, firstVertex: u32, firstInstance: u32 }
// Each range: 1 when it reads thread indices out of \`order\` and 0 when it
// counts them, where it starts, and how many it holds.
struct Gather { frame: u32, total: u32, ranges: u32, unused: u32, at: array<vec4u, ${MAX_RANGES}> }

@group(0) @binding(0) var<storage, read> order: array<u32>;
@group(0) @binding(1) var<storage, read_write> stamp: array<atomic<u32>>;
@group(0) @binding(2) var<storage, read_write> list: array<u32>;
@group(0) @binding(3) var<storage, read_write> args: Args;
@group(0) @binding(4) var<uniform> gather: Gather;

// One invocation per entry across every range. A thread in two ranges is
// listed by whichever reaches it first: the stamp says it is on this frame's
// list already.
@compute @workgroup_size(${WORKGROUP})
fn main(@builtin(global_invocation_id) id: vec3u) {
	var k = id.x;
	if (k >= gather.total) { return; }
	for (var r = 0u; r < gather.ranges; r++) {
		let range = gather.at[r];
		if (k < range.z) {
			let i = select(range.y + k, order[range.y + k], range.x != 0u);
			if (atomicExchange(&stamp[i], gather.frame) != gather.frame) {
				list[atomicAdd(&args.instances, 1u)] = i;
			}
			return;
		}
		k -= range.z;
	}
}
`;

/** The pipeline every `LitThreads` gathers with, made once per device. */
export function gatherPipeline(device: GPUDevice): GPUComputePipeline {
	return device.createComputePipeline({
		layout: "auto",
		compute: { module: device.createShaderModule({ code: GATHER }), entryPoint: "main" },
	});
}

/** The threads of one focal plane that each frame's light can reach. */
export class LitThreads {
	readonly #device: GPUDevice;
	readonly #pipeline: GPUComputePipeline;
	readonly #net: Network;
	/** Cell order first, then one span of `net.count` for each wave slot. */
	readonly #order: GPUBuffer;
	readonly #stamp: GPUBuffer;
	readonly #uniform: GPUBuffer;
	readonly #group: GPUBindGroup;
	/** The gathered thread indices, which the light draws over. */
	readonly list: GPUBuffer;
	/** The light's indirect draw: six vertices for each gathered thread. */
	readonly args: GPUBuffer;
	// The cells: their grid, and where each one's threads start in cell order.
	readonly #left: number;
	readonly #top: number;
	readonly #cols: number;
	readonly #rows: number;
	readonly #cellStart: Uint32Array;
	/** How far from the mouse a cell's end points can be and still have a
	 * thread under its light: the light's reach and the longest thread. */
	readonly #pad: number;
	/** Each wave slot's distances, sorted, matching its span of `#order`. */
	readonly #waves: Float32Array[] = [];
	#frame = 0;

	constructor(device: GPUDevice, pipeline: GPUComputePipeline, net: Network) {
		this.#device = device;
		this.#pipeline = pipeline;
		this.#net = net;
		const n = Math.max(1, net.count);
		// Only threads take the mouse's light, never the fuzz, so only they go
		// into cells.
		let left = Infinity;
		let top = Infinity;
		let right = -Infinity;
		let bottom = -Infinity;
		let longest = 0;
		for (let i = 0; i < net.count; i++) {
			const p = net.parent[i];
			if (p < 0 || net.hair[i] !== 0) continue;
			left = Math.min(left, net.x[i]);
			top = Math.min(top, net.y[i]);
			right = Math.max(right, net.x[i]);
			bottom = Math.max(bottom, net.y[i]);
			longest = Math.max(longest, Math.hypot(net.x[i] - net.x[p], net.y[i] - net.y[p]));
		}
		if (left > right) {
			left =
				top =
				right =
				bottom =
					0;
		}
		this.#left = left;
		this.#top = top;
		this.#cols = Math.floor((right - left) / CELL) + 1;
		this.#rows = Math.floor((bottom - top) / CELL) + 1;
		this.#pad = REACH + 2 + longest + 1;
		const cellOf = (i: number) =>
			Math.floor((net.y[i] - top) / CELL) * this.#cols + Math.floor((net.x[i] - left) / CELL);
		const start = new Uint32Array(this.#cols * this.#rows + 1);
		for (let i = 0; i < net.count; i++) {
			if (net.parent[i] >= 0 && net.hair[i] === 0) start[cellOf(i) + 1]++;
		}
		for (let c = 1; c < start.length; c++) start[c] += start[c - 1];
		const byCell = new Uint32Array(n);
		const next = start.slice(0, -1);
		for (let i = 0; i < net.count; i++) {
			if (net.parent[i] >= 0 && net.hair[i] === 0) byCell[next[cellOf(i)]++] = i;
		}
		this.#cellStart = start;
		for (let slot = 0; slot < WAVE_SLOTS; slot++) this.#waves.push(new Float32Array(0));

		const storage = (bytes: number, usage = 0) =>
			device.createBuffer({ size: bytes, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST | usage });
		this.#order = storage((1 + WAVE_SLOTS) * n * 4);
		device.queue.writeBuffer(this.#order, 0, byCell);
		// Zero, which no frame is, so nothing starts listed.
		this.#stamp = storage(n * 4);
		this.list = storage(n * 4);
		this.args = storage(16, GPUBufferUsage.INDIRECT);
		this.#uniform = device.createBuffer({
			size: GATHER_BYTES,
			usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
		});
		this.#group = device.createBindGroup({
			layout: pipeline.getBindGroupLayout(0),
			entries: [
				{ binding: 0, resource: { buffer: this.#order } },
				{ binding: 1, resource: { buffer: this.#stamp } },
				{ binding: 2, resource: { buffer: this.list } },
				{ binding: 3, resource: { buffer: this.args } },
				{ binding: 4, resource: { buffer: this.#uniform } },
			],
		});
	}

	/** Sort the threads a wave reaches (light.ts `waveAlong`) by how far
	 * along it reaches them, into `slot`. */
	setWave(slot: number, along: Float32Array): void {
		let reached = 0;
		for (let i = 0; i < along.length; i++) if (along[i] >= 0) reached++;
		// Each key is the distance in steps of 1/STEPS pixel, then the thread,
		// so the typed array's own numeric sort orders them with no callback.
		// A distance read back is at most one step short, well inside the
		// band's slack.
		const keys = new Float64Array(reached);
		reached = 0;
		for (let i = 0; i < along.length; i++) {
			if (along[i] >= 0) keys[reached++] = Math.floor(along[i] * STEPS) * THREADS + i;
		}
		keys.sort();
		const threads = new Uint32Array(reached);
		const far = new Float32Array(reached);
		for (let k = 0; k < reached; k++) {
			const step = Math.floor(keys[k] / THREADS);
			threads[k] = keys[k] - step * THREADS;
			far[k] = step / STEPS;
		}
		this.#waves[slot] = far;
		this.#device.queue.writeBuffer(this.#order, (1 + slot) * Math.max(1, this.#net.count) * 4, threads);
	}

	/** Gather the threads `frame` can light into `list`, ready for the draw
	 * that `args` describes. */
	gather(encoder: GPUCommandEncoder, frame: LightFrame): void {
		const net = this.#net;
		const n = Math.max(1, net.count);
		const ranges: number[] = [];
		const add = (fromOrder: boolean, start: number, end: number) => {
			if (end > start) ranges.push(fromOrder ? 1 : 0, start, end - start, 0);
		};
		if (frame.hover > 0) {
			const { x, y } = frame.mouse;
			const col = (v: number) => Math.floor((v - this.#left) / CELL);
			const row = (v: number) => Math.floor((v - this.#top) / CELL);
			const c0 = Math.max(0, col(x - this.#pad));
			const c1 = Math.min(this.#cols - 1, col(x + this.#pad));
			const r0 = Math.max(0, row(y - this.#pad));
			const r1 = Math.min(this.#rows - 1, row(y + this.#pad));
			if (c0 <= c1) {
				for (let r = r0; r <= r1; r++) {
					add(true, this.#cellStart[r * this.#cols + c0], this.#cellStart[r * this.#cols + c1 + 1]);
				}
			}
		}
		if (frame.front > 0) add(false, firstBorn(net, frame.upTo - FRONT), firstBorn(net, frame.upTo + 1));
		for (const wave of frame.waves) {
			if (wave.strength <= 0) continue;
			const far = this.#waves[wave.slot];
			const base = (1 + wave.slot) * n;
			const lo = firstAtLeast(far, far.length, wave.edge - WAVE_BAND - BAND_SLACK);
			const hi = firstAtLeast(far, far.length, wave.edge + BAND_SLACK);
			add(true, base + lo, base + hi);
		}
		// More ranges than the pass holds: gather the whole plane. It holds
		// every thread the light can reach, so the frame costs more but looks
		// the same.
		if (ranges.length / 4 > MAX_RANGES) ranges.splice(0, ranges.length, 0, 0, net.count, 0);
		let total = 0;
		for (let r = 2; r < ranges.length; r += 4) total += ranges[r];

		const queue = this.#device.queue;
		queue.writeBuffer(this.args, 0, new Uint32Array([6, 0, 0, 0]));
		if (total === 0) return;
		const words = new Uint32Array(GATHER_BYTES / 4);
		words.set([++this.#frame, total, ranges.length / 4], 0);
		words.set(ranges, 4);
		queue.writeBuffer(this.#uniform, 0, words);
		const pass = encoder.beginComputePass();
		pass.setPipeline(this.#pipeline);
		pass.setBindGroup(0, this.#group);
		pass.dispatchWorkgroups(Math.ceil(total / WORKGROUP));
		pass.end();
	}

	destroy(): void {
		this.#order.destroy();
		this.#stamp.destroy();
		this.list.destroy();
		this.args.destroy();
		this.#uniform.destroy();
	}
}
