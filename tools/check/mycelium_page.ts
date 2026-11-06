// Browser fixture for the real background. Count work at browser boundaries,
// independent of whether Chromium uses a hardware GPU or SwiftShader.
import { type Mycelium, startMycelium } from "../../ui/mycelium/live.ts";

const cost = { adapters: 0, buffers: 0, bytes: 0, pipelines: 0, submissions: 0, planes: 0, unconfigured: 0 };
const timers = new Set<unknown>();
const frames = new Set<number>();
globalThis.setTimeout = new Proxy(globalThis.setTimeout, {
	apply(target, receiver, args) {
		const id = Reflect.apply(target, receiver, [() => {
			timers.delete(id);
			Reflect.apply(args[0], receiver, args.slice(2));
		}, args[1]]);
		timers.add(id);
		return id;
	},
});
globalThis.clearTimeout = new Proxy(globalThis.clearTimeout, {
	apply(target, receiver, args) {
		timers.delete(args[0]);
		return Reflect.apply(target, receiver, args);
	},
});
const request = globalThis.requestAnimationFrame;
const cancel = globalThis.cancelAnimationFrame;
globalThis.requestAnimationFrame = (callback) => {
	const id = request((now) => {
		frames.delete(id);
		callback(now);
	});
	frames.add(id);
	return id;
};
globalThis.cancelAnimationFrame = (id) => {
	frames.delete(id);
	cancel(id);
};
const adapter = navigator.gpu.requestAdapter.bind(navigator.gpu);
navigator.gpu.requestAdapter = (...args) => {
	cost.adapters++;
	return adapter(...args);
};
const buffer = GPUDevice.prototype.createBuffer;
GPUDevice.prototype.createBuffer = function (descriptor) {
	cost.buffers++;
	cost.bytes += descriptor.size;
	return buffer.call(this, descriptor);
};
const render = GPUDevice.prototype.createRenderPipeline;
GPUDevice.prototype.createRenderPipeline = function (descriptor) {
	cost.pipelines++;
	return render.call(this, descriptor);
};
const compute = GPUDevice.prototype.createComputePipeline;
GPUDevice.prototype.createComputePipeline = function (descriptor) {
	cost.pipelines++;
	return compute.call(this, descriptor);
};
const submit = GPUQueue.prototype.submit;
GPUQueue.prototype.submit = function (commands) {
	cost.submissions++;
	return submit.call(this, commands);
};
// SwiftShader cannot reliably present WebGPU swapchains in headless
// Chromium. Use real GPU render targets, as the mark generator does. The
// scene still configures canvases and runs its unchanged shaders and buffers.
const surfaces = new Map<GPUCanvasContext, {
	device: GPUDevice;
	format: GPUTextureFormat;
	texture?: GPUTexture;
}>();
let device: GPUDevice | undefined;
let recovered: (() => void) | undefined;
const gpuErrors: string[] = [];
const configure = GPUCanvasContext.prototype.configure;
GPUCanvasContext.prototype.configure = function (configuration) {
	if (device !== configuration.device) {
		device = configuration.device;
		device.addEventListener("uncapturederror", (event) => gpuErrors.push(event.error.message));
		recovered?.();
		recovered = undefined;
	}
	surfaces.get(this)?.texture?.destroy();
	surfaces.set(this, { device: configuration.device, format: configuration.format });
	return configure.call(this, configuration);
};
GPUCanvasContext.prototype.getCurrentTexture = function () {
	if (this.canvas instanceof HTMLCanvasElement && this.canvas.className !== "mycelium-light") cost.planes++;
	const surface = surfaces.get(this);
	if (!surface) throw new Error("drawing on an unconfigured canvas");
	if (surface.texture?.width !== this.canvas.width || surface.texture?.height !== this.canvas.height) {
		surface.texture?.destroy();
		surface.texture = surface.device.createTexture({
			size: [this.canvas.width, this.canvas.height],
			format: surface.format,
			usage: GPUTextureUsage.RENDER_ATTACHMENT,
		});
	}
	return surface.texture;
};
const unconfigure = GPUCanvasContext.prototype.unconfigure;
GPUCanvasContext.prototype.unconfigure = function () {
	cost.unconfigured++;
	surfaces.get(this)?.texture?.destroy();
	surfaces.delete(this);
	return unconfigure.call(this);
};

let ground: Mycelium | null = null;
let motionChange = Promise.resolve();
const fixture = {
	loseDevice() {
		if (!device) throw new Error("no device to lose");
		const next = new Promise<void>((resolve) => recovered = resolve);
		device.destroy();
		return next;
	},
	async gpuErrors() {
		await device?.queue.onSubmittedWorkDone();
		return gpuErrors;
	},
	expectMotionChange() {
		motionChange = new Promise<void>((resolve) => {
			matchMedia("(prefers-reduced-motion: reduce)").addEventListener("change", () => resolve(), { once: true });
		});
	},
	motionChanged() {
		return motionChange;
	},
	start() {
		return started;
	},
	read() {
		const canvases = [...document.querySelectorAll("canvas")];
		return {
			...cost,
			canvases: canvases.length,
			pixels: canvases.reduce((n, canvas) => n + canvas.width * canvas.height, 0),
			timers: timers.size,
			frames: frames.size,
		};
	},
	hide(hidden: boolean) {
		// Deliver visibility changes without relying on headless window focus
		// or Chromium throttling to conceal a leaked timer.
		Object.defineProperty(document, "hidden", { configurable: true, value: hidden });
		document.dispatchEvent(new Event("visibilitychange"));
	},
	dim() {
		ground?.dim();
	},
	regrow() {
		ground?.regrow();
	},
	stop() {
		ground?.stop();
	},
};
declare global {
	var myceliumFixture: typeof fixture;
}
globalThis.myceliumFixture = fixture;

// Start the background with page load, as both consumers do.
const started = startMycelium({ arriving: true }).then((value) => {
	ground = value;
	return value !== null;
});
