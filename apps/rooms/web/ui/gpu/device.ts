// The page's one WebGPU device, shared by every mark on it and by the
// mycelium under it, and how a drawing stays on it. Each drawing makes
// resources of its own, so what one costs is released with it and the device
// holds nothing but itself.

/// <reference lib="dom" />

/** How many times a drawing moves to a new device after losing one. Past
 * that the machine cannot keep a device, not one that lost a device once,
 * and the drawing gives up. */
const RELIGHTS = 2;

let shared: Promise<GPUDevice | null> | null = null;

/** The page's device. A lost device forgets itself here, so the next asker
 * gets a fresh one rather than the corpse. Null is a browser that cannot make
 * one: no adapter, or an adapter with no device to give. */
function pageDevice(): Promise<GPUDevice | null> {
	if (shared !== null) return shared;
	// The standard library types `navigator.gpu` as always present, but real
	// browsers do not, so the null check below is the browser's answer.
	const gpu = navigator.gpu;
	if (gpu == null) return Promise.resolve(null);
	const asked = (async () => {
		let adapter: GPUAdapter | null = null;
		try {
			adapter = await gpu.requestAdapter();
		} catch {
			// tolerant: a browser that throws on the question has answered it.
			return null;
		}
		if (adapter == null) return null;
		let got: GPUDevice;
		try {
			got = await adapter.requestDevice();
		} catch {
			// tolerant: an adapter lost between the two calls is no device.
			return null;
		}
		void got.lost.then(() => {
			if (shared === asked) shared = null;
		});
		return got;
	})();
	shared = asked;
	return asked;
}

/** Something drawn on the page's device. */
export interface Drawing {
	/** Make what the drawing needs on `device` and configure its canvases for
	 * `format`. False when the device refuses it, with nothing left made. */
	mount(device: GPUDevice, format: GPUTextureFormat): boolean;
	/** The device died: drop everything made on it. */
	lost(): void;
	/** Mounted again on a new device after a loss: draw again whole. */
	relit(): void;
}

/** Put `drawing` on the page's device. A device can die under it, by a
 * driver reset or a tab moved between GPUs, and the drawing then moves to
 * the next one. Resolves to the call that lets it go, or to null, with
 * nothing mounted, when this browser cannot draw it. */
export async function keepOnPageDevice(drawing: Drawing): Promise<(() => void) | null> {
	let released = false;
	let relights = 0;
	const put = async (): Promise<boolean> => {
		const device = await pageDevice();
		if (released || device === null) return false;
		if (!drawing.mount(device, navigator.gpu.getPreferredCanvasFormat())) return false;
		void device.lost.then(async () => {
			if (released) return;
			drawing.lost();
			if (++relights > RELIGHTS) return;
			if (await put()) drawing.relit();
		});
		return true;
	};
	if (!(await put())) return null;
	return () => {
		released = true;
	};
}
