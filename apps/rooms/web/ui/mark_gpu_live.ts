// The shader mark, live in a page: one device for every mark on it, a loop
// for each, and the three ways a mark plays.
//
// The opening screen's mark loops the whole cycle: grow, strike, stand, fade,
// and again. An arriving mark runs that cycle once and is a lockup afterwards,
// which is how a page introduces the mark without then talking over itself. A
// lockup's mark stands lit and breathing, and replays the strike when the
// pointer reaches it. A control's mark stands with its light off, strikes when
// the pointer arrives, stays lit while it is there, and goes out again when it
// leaves. All four are one renderer under one set of beats; what differs is
// which frame of the cycle a moment maps onto.
//
// There is no other mark. A browser that cannot make a device gets an empty
// box where the mark would be, and the control around it keeps its name and
// its action.

import { BEAT, beats, CYCLE, readColours, Renderer, VIEW } from "./mark_gpu.ts";

/** How a mark plays: the opening screen's loop, one arrival that settles into
 * a lockup, standing lit, or standing unlit until the pointer reaches its
 * control. */
export type MarkPlay = "loop" | "arrive" | "stand" | "unlit";

export type MarkLive = {
	/** Resolves once the mark has assembled and its light has settled at least
	 * once, in mark time; at once when there is no play to wait through. */
	assembled: Promise<void>;
	stop: () => void;
};

/** How much larger the mushroom stands than the box it is given. The box is
 * the flat mark's silhouette box, and the mushroom fills it the way the
 * drawing did, brim to brim; but the drawing stood taller in it than a
 * cushioned cap on a chubby stalk does, and beside type at the sizes the
 * mark is set at, that reads small. Grown here, once, about the box's
 * centre, so every home grows together and the box still lays out where
 * the mark stands. */
const GROW = 1.2;

/** The frame a lit mark holds: settled, before the fade. */
const REST = 0.75;
/** The frame an unlit mark holds: standing, the light off, the frame before
 * the tube strikes. The body is the same as at `REST`, so the two frames
 * differ only in the light. */
const DARK = 0.29;
/** The strike runs from `DARK` to here, at the cycle's own speed: the
 * blinks, the catch, and the settle to the level the mark stands lit at.
 * The light arrives at `REST`'s numbers, so the end is seamless. */
const STRIKE_TO = 0.62;
/** How long a lit mark's light takes to go out before a strike, in
 * seconds. */
const STRIKE_OUT = 0.12;
/** How long a control's light takes to go out when the pointer leaves, in
 * seconds: slower than the flinch before a strike, the way a tube dies. */
const FADE = 0.35;
/** A standing mark's frame rate: the drift in its light is slow, and a
 * lockup in the chrome should not keep a device awake at sixty a second. The
 * strike runs at full rate. */
const STAND_INTERVAL_MS = 1000 / 24;

type Gpu = {
	gpu?: { requestAdapter: (o?: unknown) => Promise<unknown | null>; getPreferredCanvasFormat: () => string };
};

let shared: Promise<GPUDevice | null> | null = null;

/** One device for the page. Every mark draws on it with a renderer of its
 * own, so what a mark's textures cost is released with the mark and the
 * device holds nothing but itself. A lost device forgets itself here, so the
 * next asker gets a fresh one rather than the corpse. Null is a browser that
 * cannot make one: no adapter, or an adapter with no device to give. */
function device(): Promise<GPUDevice | null> {
	if (shared !== null) return shared;
	const nav = navigator as unknown as Gpu;
	if (nav.gpu == null) return Promise.resolve(null);
	const asked = (async () => {
		let adapter: GPUAdapter | null = null;
		try {
			adapter = await (nav.gpu!.requestAdapter() as Promise<GPUAdapter | null>);
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

/** Put a live mark inside `host`, which is the mushroom's own box: the canvas
 * hangs around it by `VIEW` so the light has room. Resolves to null when this
 * browser cannot draw one. */
export async function start(host: HTMLElement, play: MarkPlay): Promise<MarkLive | null> {
	const nav = navigator as unknown as Gpu;
	if (nav.gpu == null) return null;

	const canvas = document.createElement("canvas");
	canvas.setAttribute("aria-hidden", "true");
	// The canvas is the plume box, `VIEW`, hung around the host by its share
	// of the 24-unit box, scaled about that box's centre.
	canvas.style.position = "absolute";
	canvas.style.left = `${((12 + (VIEW.x - 12) * GROW) / 24) * 100}%`;
	canvas.style.top = `${((12 + (VIEW.y - 12) * GROW) / 24) * 100}%`;
	canvas.style.width = `${((VIEW.w * GROW) / 24) * 100}%`;
	canvas.style.height = `${((VIEW.h * GROW) / 24) * 100}%`;
	canvas.style.pointerEvents = "none";
	canvas.style.display = "block";

	const ctx = canvas.getContext("webgpu") as GPUCanvasContext | null;
	if (ctx == null) return null;
	const format = nav.gpu.getPreferredCanvasFormat() as GPUTextureFormat;

	let running = true;
	let renderer: Renderer | null = null;
	let width = 0;
	let height = 0;
	let oversample = 1;

	// A device can die under a mark: a driver reset, a tab moved between GPUs.
	// The mark then puts itself back on the next device, and gives up when the
	// browser has none to give or when devices keep dying under it, which is
	// a machine that cannot draw this, not one that lost a device once.
	const RELIGHTS = 2;
	let relights = 0;
	const mount = async (): Promise<boolean> => {
		const got = await device();
		if (!running || got === null) return false;
		try {
			renderer = new Renderer(got, format);
		} catch {
			// tolerant: a device that refuses the pipelines draws no mark.
			return false;
		}
		// Premultiplied, because the drawing is mostly soft edges and light
		// with partial coverage: composited any other way, every one of them
		// takes a dark fringe from the transparent black underneath.
		ctx.configure({ device: got, format, alphaMode: "premultiplied" });
		width = 0;
		height = 0;
		void got.lost.then(() => {
			if (!running) return;
			renderer?.destroy();
			renderer = null;
			if (++relights > RELIGHTS) return;
			void mount().then((again) => {
				if (again) wake();
			});
		});
		return true;
	};
	if (!(await mount())) return null;
	host.appendChild(canvas);

	let colours = readColours(host);
	const still = matchMedia("(prefers-reduced-motion: reduce)");
	const pointer = matchMedia("(hover: hover)");

	const size = () => {
		const box = canvas.getBoundingClientRect();
		// Twice the device's own ratio, and let the browser scale it back down.
		// Every edge in this drawing is analytic, so it is exact at whatever
		// resolution it is asked for, and the browser's downscale is then a
		// free box filter over four samples a pixel: the cheapest
		// anti-aliasing a raymarcher can have, and what takes the
		// stair-stepping off the outline and the beams at small sizes.
		const real = globalThis.devicePixelRatio || 1;
		// Bounded: the supersample is for the small mark, where it is cheap
		// and where the edges need it. A large canvas gets fewer samples per
		// pixel, because its cost is pixels and its edges are already long.
		const dpr = Math.min(real * 2, 4, 1200 / Math.max(box.width, box.height, 1));
		const w = Math.max(1, Math.min(2048, Math.round(box.width * dpr)));
		const h = Math.max(1, Math.min(2048, Math.round(box.height * dpr)));
		if (w === width && h === height) return;
		width = w;
		height = h;
		// The shader measures what is worth drawing in real pixels, so it is
		// told how many of its own make one.
		oversample = dpr / real;
		canvas.width = w;
		canvas.height = h;
	};

	const begin = performance.now();
	const now = () => (performance.now() - begin) / 1000;

	/** Whether this mark rests with its light off. A control's does, where a
	 * pointer can arrive to light it; where none can, on a touch screen or
	 * for a reader who asked for stillness, a dark mark would stay dark for
	 * good, so it stands lit like a lockup's. */
	const unlit = () => play === "unlit" && pointer.matches && !still.matches;

	/** Where a standing mark is in its play, and when that began in mark
	 * seconds. At rest it holds one frame, lit or dark. On approach a lit
	 * mark lets its light go out and then strikes; a dark one strikes at
	 * once. After the strike a lockup's mark is back at rest, and a control's
	 * stays lit until the pointer leaves, when its light fades out. */
	let phase: "rest" | "out" | "strike" | "lit" | "fade" = "rest";
	let since = 0;
	let hovered = false;

	/** Whether an arriving mark is still arriving.
	 *
	 * It stops at `REST`, not at the end of the cycle. The cycle's last
	 * stretch is the fade, so running it whole and then standing put the
	 * light out and struck it again in the same breath, which reads as a
	 * blink at the end of the arrival. `REST` is the frame a standing mark
	 * holds, so ending there is the handover: the last arriving frame and the
	 * first standing one are the same frame. */
	const arriving = (seconds: number) => play === "arrive" && seconds < REST * CYCLE;

	/** Which frame of the cycle this moment is, and how much of the light is
	 * up. The loop maps time onto the cycle whole; an arrival maps onto its
	 * first three quarters; a standing mark reads it off its phase, advancing
	 * the phase as each one ends. */
	const frameAt = (seconds: number): { frame: number; dim: number } => {
		if (play === "loop") return { frame: (seconds % CYCLE) / CYCLE, dim: 1 };
		if (arriving(seconds)) return { frame: seconds / CYCLE, dim: 1 };
		const t = seconds - since;
		switch (phase) {
			case "rest":
				return { frame: unlit() ? DARK : REST, dim: 1 };
			case "out":
				if (t < STRIKE_OUT) return { frame: REST, dim: 1 - t / STRIKE_OUT };
				phase = "strike";
				since = seconds;
				return { frame: DARK, dim: 1 };
			case "strike": {
				const frame = DARK + t / CYCLE;
				if (frame < STRIKE_TO) return { frame, dim: 1 };
				if (unlit()) {
					phase = hovered ? "lit" : "fade";
					since = seconds;
				} else {
					phase = "rest";
				}
				return { frame: REST, dim: 1 };
			}
			case "lit":
				return { frame: REST, dim: 1 };
			case "fade":
				if (t < FADE) return { frame: REST, dim: 1 - t / FADE };
				phase = "rest";
				return { frame: DARK, dim: 1 };
		}
	};

	const draw = (seconds: number) => {
		if (renderer === null) return;
		size();
		const { frame, dim } = frameAt(seconds);
		const b = beats(frame, seconds, still.matches);
		b.glow *= dim;
		b.rays *= dim;
		renderer.draw(ctx.getCurrentTexture().createView(), width, height, seconds, colours, b, oversample);
	};

	let raf = 0;
	let drawn = -Infinity;
	const tick = (now: number) => {
		if (!running) return;
		raf = requestAnimationFrame(tick);
		const seconds = (now - begin) / 1000;
		// An arriving mark is not settled however its phase reads: it is
		// running the cycle, and the cycle wants every frame.
		const settled = !arriving(seconds) && (phase === "rest" || phase === "lit");
		if (play !== "loop" && settled && now - drawn < STAND_INTERVAL_MS) return;
		drawn = now;
		draw((now - begin) / 1000);
	};

	// A page nobody is looking at draws nothing, and a reader who asked for
	// stillness gets the mark standing lit rather than a loop or an arrival.
	const wake = () => {
		if (!running) return;
		cancelAnimationFrame(raf);
		if (document.hidden) return;
		if (still.matches) {
			phase = "rest";
			// An arrival that will not be played still has to land on the
			// frame it would have landed on.
			draw(play === "loop" ? BEAT.settled * CYCLE : play === "arrive" ? REST * CYCLE : 0);
			return;
		}
		raf = requestAnimationFrame(tick);
	};

	// The pointer reaching the control the mark sits in, and leaving it.
	// Pointer surfaces only, and one play at a time: an approach mid-strike
	// waits for the light to settle rather than restarting it, and a control
	// left mid-strike finishes striking before its light goes out.
	const control = host.parentElement;
	const enter = () => {
		hovered = true;
		if (!running || still.matches || !pointer.matches) return;
		// An arrival finishes before it answers anyone: a strike laid over the
		// cap still opening reads as two plays fighting.
		if (arriving(now())) return;
		if (phase !== "rest" && phase !== "fade") return;
		since = now();
		phase = unlit() ? "strike" : "out";
	};
	const leave = () => {
		hovered = false;
		if (phase !== "lit") return;
		since = now();
		phase = "fade";
	};
	if (play !== "loop") {
		control?.addEventListener("pointerenter", enter);
		control?.addEventListener("pointerleave", leave);
	}

	// Assembled is a fact about mark time, not about frames drawn: by that
	// many seconds after the loop began, the cycle has passed the settle
	// whether or not a hidden tab drew it. A reader who asked for stillness
	// has the settled mark from the first frame.
	const assembled = new Promise<void>((resolve) => {
		if (play !== "loop" || still.matches) return resolve();
		setTimeout(resolve, BEAT.settled * CYCLE * 1000);
	});

	const theme = new MutationObserver(() => {
		colours = readColours(host);
		if (still.matches) wake();
	});
	theme.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
	document.addEventListener("visibilitychange", wake);
	still.addEventListener("change", wake);
	globalThis.addEventListener("resize", wake);
	wake();

	return {
		assembled,
		stop() {
			running = false;
			cancelAnimationFrame(raf);
			theme.disconnect();
			document.removeEventListener("visibilitychange", wake);
			still.removeEventListener("change", wake);
			globalThis.removeEventListener("resize", wake);
			control?.removeEventListener("pointerenter", enter);
			control?.removeEventListener("pointerleave", leave);
			canvas.remove();
			// The textures are this mark's and go with it; the device is the
			// page's and stays for the next mark.
			renderer?.destroy();
			renderer = null;
		},
	};
}
