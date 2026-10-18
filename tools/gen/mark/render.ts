/// <reference lib="dom" />
// The page half of the capture: the shader mark's settled, unlit frame, drawn
// by the page itself and left on `globalThis` as raw RGBA for the tracer.
//
// The render runs here rather than inside a `page.evaluate` call because
// Chromium drops the WebGPU instance when the evaluated call returns, and the
// readback then fails mid-submit. The page owns the whole job, and the driver
// in capture.ts only collects what it left behind. Nothing here reaches a
// swapchain: the frames are drawn into an offscreen texture and copied back,
// which is also the only thing that paints at all under SwiftShader.

import { beats, readColours, Renderer, VIEW } from "../../../apps/rooms/web/ui/mark/renderer.ts";

/** One frame, base64 so it survives the trip out of the page. */
export type Shot = { name: string; w: number; h: number; rgba: string };

/** The mark's frame in the shader's own box units. */
export type View = { x: number; y: number; w: number; h: number };

// What the page leaves behind for the driver in capture.ts. These are the whole
// contract between the two halves.
declare global {
	var markLog: string[];
	var markShots: Shot[] | null;
	var markView: View | null;
}

globalThis.markLog = [];
globalThis.markShots = null;
globalThis.markView = null;

const log = (line: string) => globalThis.markLog.push(line);

// Held at module scope so nothing is collected between submit and readback.
let heldDevice: GPUDevice | null = null;
let heldRenderer: Renderer | null = null;

function toBase64(bytes: Uint8Array): string {
	let out = "";
	const chunk = 0x8000;
	for (let i = 0; i < bytes.length; i += chunk) {
		out += String.fromCharCode(...bytes.subarray(i, i + chunk));
	}
	return btoa(out);
}

async function run(): Promise<void> {
	const params = new URLSearchParams(location.search);
	const size = Number(params.get("size") ?? 512);
	const specs = (params.get("frames") ?? "unlit").split(",");

	const adapter = await navigator.gpu.requestAdapter();
	if (adapter == null) {
		log("no adapter");
		globalThis.markShots = [];
		return;
	}
	heldDevice = await adapter.requestDevice();
	const device = heldDevice;
	device.addEventListener("uncapturederror", (event) => {
		log("uncaptured: " + (event as GPUUncapturedErrorEvent).error.message);
	});
	void device.lost.then((info) => log("device lost: " + info.reason + " " + info.message));

	// The mark reads its colors off the page, so the page has to stand in the
	// theme being measured.
	if (params.get("theme") === "light") document.documentElement.dataset.theme = "light";
	const colours = readColours(document.getElementById("host") as HTMLElement);
	log("colours " + JSON.stringify(colours));
	if (colours === null) {
		globalThis.markShots = [];
		return;
	}

	// rgba8unorm rather than the canvas preferred format: this never reaches a
	// swapchain, and a fixed channel order makes the readback unambiguous.
	const format: GPUTextureFormat = "rgba8unorm";
	heldRenderer = new Renderer(device, format);
	const renderer = heldRenderer;

	const w = Math.round((size * VIEW.w) / 24);
	const h = Math.round((size * VIEW.h) / 24);
	const bytesPerRow = Math.ceil((w * 4) / 256) * 256;
	const target = device.createTexture({
		size: { width: w, height: h },
		format,
		usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
	});
	const readback = device.createBuffer({
		size: bytesPerRow * h,
		usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
	});

	const shots: Shot[] = [];
	for (const name of specs) {
		try {
			// The settled pose, at rest. Body beats and light beats are
			// independent, so asking for the rested body and a chosen state of
			// the light at once is legitimate.
			const beat = beats(0.75, 0, true);
			// The beams and the flare are the air around the mushroom, and no
			// still reading of the mark carries them.
			beat.rays = 0;
			beat.flare = 0;
			// "lit" keeps the lamps at the strength they settle to. Every other
			// frame is the unlit drawing, which is the pose the still artwork
			// has to match.
			if (name !== "lit") beat.glow = 0;
			// The cap with no stalk under it. Its lower edge is the brim,
			// including the stretch the stalk normally hides, which is the one
			// line a drawing needs to say the cap stands in front.
			if (name === "cap") beat.stem = 0;
			renderer.draw(target.createView(), w, h, 0, colours, beat, 1);
			const encoder = device.createCommandEncoder();
			encoder.copyTextureToBuffer({ texture: target }, { buffer: readback, bytesPerRow }, {
				width: w,
				height: h,
			});
			device.queue.submit([encoder.finish()]);
			await readback.mapAsync(GPUMapMode.READ);
			const src = new Uint8Array(readback.getMappedRange().slice(0));
			readback.unmap();
			// Drop the row padding, so the tracer reads a plain w by h by 4
			// buffer.
			const tight = new Uint8Array(w * h * 4);
			for (let y = 0; y < h; y++) {
				tight.set(src.subarray(y * bytesPerRow, y * bytesPerRow + w * 4), y * w * 4);
			}
			shots.push({ name, w, h, rgba: toBase64(tight) });
			log(name + " ok " + w + "x" + h);
		} catch (error) {
			log(name + " threw: " + (error as Error).message);
		}
	}
	globalThis.markView = VIEW;
	globalThis.markShots = shots;
}

run().catch((error) => {
	log("run threw: " + (error as Error).message);
	globalThis.markShots = [];
});
