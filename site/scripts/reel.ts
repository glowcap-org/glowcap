/// <reference lib="dom" />
/**
 * Reels: recordings of an app in use, for the site's explainer video.
 *
 * Chromium's screencast sends a frame each time the page draws, so a reel
 * holds one picture per change and the time it appeared. `render-video.ts`
 * places those frames in the scene's timeline at one speed, so the video
 * comes out the same however fast the recording ran. A wait with nothing
 * moving plays short: no still stretch holds longer than `LONGEST_HOLD_MS`.
 *
 * The page draws no pointer. A reel records where the mouse went and when it
 * pressed, and the scene draws the pointer from that at the video's own frame
 * rate, so it moves smoothly however slowly the page draws.
 *
 * A film says how its waits play. `hold` keeps a wait whole, for a moment the
 * viewer should read, and `offCamera` plays its work as nothing, for a step
 * the viewer should not see, so the video cuts past it.
 *
 * A film names its moments with marks, such as the press that opens a
 * direct line. A mark also names its subject, the box of what the viewer
 * should look at then, and the scene's camera frames it.
 *
 * A reel is a directory under `--reels` (default
 * `zig-out/site-video/reels/<theme>`):
 * `reel.json` lists each frame's file and time in milliseconds, the marks and
 * their boxes, the pointer's track, and the reel's length, and the JPEG
 * frames sit beside it.
 */
import type { Browser, BrowserContext, BrowserContextOptions, Locator, Page } from "playwright";

/** What `reel.json` holds. */
export type ReelIndex = {
	width: number;
	height: number;
	/** Milliseconds, including the hold on the last frame. */
	length: number;
	frames: { at: number; file: string }[];
	/** Each mark's time in milliseconds, by name. */
	marks: Record<string, number>;
	/** Where each mark looks, by name, as fractions of the frame, and the
	 * part of the frame the camera keeps to there, when the film names one. */
	focus: Record<string, Box & { within?: Box }>;
	/** What the video shows of the frame between its marks, as fractions of
	 * the frame: all of it, unless the film crops the app's chrome away. */
	rest: Box;
	/** The pointer: each move starts at `at` and reaches (`x`, `y`), in CSS
	 * pixels of `viewport`, `ms` later, and each press's time. */
	pointer: {
		viewport: { width: number; height: number };
		moves: { at: number; ms: number; x: number; y: number }[];
		presses: number[];
	};
};

/** A box on the frame: its left, top, width, and height, as fractions of the
 * frame's width and height. */
export type Box = { x: number; y: number; w: number; h: number };

/** What a mark looks at: an element, or a box in CSS pixels. */
export type Look = Locator | { x: number; y: number; width: number; height: number };

/** The directory `--reels=<dir>` names, or null when the run was given none. */
export const filmDirArg = (): string | null =>
	Deno.args.find((arg) => arg.startsWith("--reels="))?.slice("--reels=".length) ?? null;

/** The site's two faces. The video is filmed and rendered once in each. */
export type Theme = "dark" | "light";

/** The face a run films or renders in: `--theme=light`, or dark. */
export function themeArg(): Theme {
	const theme = Deno.args.find((arg) => arg.startsWith("--theme="))?.slice("--theme=".length) ?? "dark";
	if (theme !== "dark" && theme !== "light") throw new Error(`--theme takes dark or light, not ${theme}`);
	return theme;
}

/** Where reels go: `--reels=<dir>`, or `zig-out/site-video/reels/<theme>`,
 * where `render-video.ts` reads them. */
export const reelsDirArg = (): string => filmDirArg() ?? `zig-out/site-video/reels/${themeArg()}`;

/** A new browser context whose every page opens in `theme`: the browser's
 * own preference, and the face Rooms and ocapnviz each remember and stamp
 * before they draw. */
export async function themedContext(
	browser: Browser,
	theme: Theme,
	options: BrowserContextOptions = {},
): Promise<BrowserContext> {
	const context = await browser.newContext({ ...options, colorScheme: theme });
	await context.addInitScript((face) => {
		localStorage.setItem("glowcap-theme", face);
		localStorage.setItem("ocapnviz:theme", face);
	}, theme);
	return context;
}

/** A recording `startReel` started. */
export type Reel = {
	mark(name: string, look?: Look, within?: Look): Promise<void>;
	hold(ms: number): Promise<void>;
	offCamera<T>(work: () => Promise<T>): Promise<T>;
	stop(): Promise<void>;
};

/** The reel of a run that films nothing: a capture taking only its pictures
 * plays its scene through it, and nothing waits or records. */
export const unfilmed: Reel = {
	mark: () => Promise.resolve(),
	hold: () => Promise.resolve(),
	offCamera: (work) => work(),
	stop: () => Promise.resolve(),
};

/** The launch flags a browser that films needs, at the device scale of the
 * context it films. Chromium's screencast draws at the browser's own scale,
 * not the one a context emulates, and without it a reel comes out at CSS
 * pixel size. The rest let Chromium draw on the machine's GPU through EGL:
 * on the CPU, ocapnviz draws about ten frames a second at this scale, and a
 * GPU draws it at forty. Where EGL has no GPU behind it, Chromium draws on
 * the CPU as before. */
export const filmArgs = (scale: number): string[] => [
	`--force-device-scale-factor=${scale}`,
	"--ignore-gpu-blocklist",
	"--use-angle=gl-egl",
];

/** A stretch longer than this, with nothing on screen or of the pointer
 * moving, plays as this long. */
const LONGEST_HOLD_MS = 450;

/** What a film does with the pointer while a reel records its page, in
 * wall-clock seconds, the screencast's clock. */
type PointerLog = {
	moves: { start: number; end: number; x: number; y: number }[];
	presses: number[];
};

/** The pointer log of each page a reel is recording. */
const filming = new WeakMap<Page, PointerLog>();

/** The reel time, in milliseconds, of each wall-clock second from `start`:
 * a stretch inside `cuts` plays as nothing, one inside `whole` plays whole,
 * and every other stretch between frames plays at most `longestHold` long. */
function reelClock(
	start: number,
	frames: number[],
	whole: [number, number][],
	cuts: [number, number][],
	longestHold: number,
): (seconds: number) => number {
	const points = [...new Set([start, ...frames, ...whole.flat(), ...cuts.flat()])]
		.filter((t) => t >= start)
		.sort((a, b) => a - b);
	const within = (spans: [number, number][], a: number, b: number) =>
		spans.some(([from, to]) => from <= a && b <= to);
	const played = [0];
	for (let i = 1; i < points.length; i++) {
		const [a, b] = [points[i - 1], points[i]];
		const ms = (b - a) * 1000;
		played.push(played[i - 1] + (within(cuts, a, b) ? 0 : within(whole, a, b) ? ms : Math.min(ms, longestHold)));
	}
	return (seconds) => {
		const i = points.findLastIndex((t) => t <= seconds);
		if (i < 0) return 0;
		if (i === points.length - 1) return played[i] + Math.min((seconds - points[i]) * 1000, longestHold);
		const ms = (points[i + 1] - points[i]) * 1000;
		const scale = ms === 0 ? 0 : (played[i + 1] - played[i]) / ms;
		return played[i] + (seconds - points[i]) * 1000 * scale;
	};
}

/** Record `page` until `stop`, which writes the reel into `dir`, replacing any
 * reel there, with the pointer's moves and presses from `glide`, `glideClick`,
 * `press`, and `placePointer`. A still stretch plays as `LONGEST_HOLD_MS` at
 * most, unless `hold` waits it out. Reels filmed side by side to play together
 * pass `{ realTime: true }` instead, so each keeps every wait, and one wall
 * clock times them all. `mark` stamps a moment and, given a look, the box the
 * camera frames there, and given `within`, the part of the page that framing
 * keeps to. `offCamera` runs its
 * work unrecorded, and the reel cuts from the frame before it to the next
 * frame after. `rest` is the part of the page the video shows between marks,
 * the whole page when absent. */
export async function startReel(
	page: Page,
	dir: string,
	{ realTime = false, rest }: { realTime?: boolean; rest?: Look } = {},
): Promise<Reel> {
	// A film shows the page's own motion, which a capture context may have
	// turned off for its stills. Stop turns it back to what it was.
	const reducedMotion = await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches);
	await page.emulateMedia({ reducedMotion: "no-preference" });
	const viewport = page.viewportSize();
	if (viewport == null) throw new Error("a reel needs a page with a fixed viewport");
	const scale = await page.evaluate(() => devicePixelRatio);
	const width = Math.round(viewport.width * scale);
	const height = Math.round(viewport.height * scale);
	const cdp = await page.context().newCDPSession(page);
	const shots: { seconds: number; data: string }[] = [];
	const marked = new Map<string, number>();
	const focus: ReelIndex["focus"] = {};
	const wall = () => Date.now() / 1000;
	const started = wall();
	const log: PointerLog = { moves: [], presses: [] };
	const holds: [number, number][] = [];
	const cuts: [number, number][] = [];
	const at = pointers.get(page);
	if (at != null) log.moves.push({ start: started, end: started, ...at });
	filming.set(page, log);
	let failure: unknown = null;
	// A frame already on its way when the recording stops is not kept, and is
	// not acknowledged to a session that is going away.
	let recording = true;
	cdp.on("Page.screencastFrame", ({ data, metadata, sessionId }) => {
		if (!recording) return;
		const seconds = metadata.timestamp ?? wall();
		if (!cuts.some(([from, to]) => from <= seconds && seconds <= to)) shots.push({ seconds, data });
		cdp.send("Page.screencastFrameAck", { sessionId }).catch((err) => failure ??= err);
	});
	// Below quality 100, JPEG's 8 pixel blocks show in the apps' dark
	// gradients, and the video's encoder keeps them. PNG would cost the
	// screencast its frame rate.
	await cdp.send("Page.startScreencast", { format: "jpeg", quality: 100, maxWidth: width, maxHeight: height });
	const boxOf = async (what: string, look: Look): Promise<Box> => {
		const box = "x" in look ? look : await look.boundingBox();
		if (box == null) throw new Error(`the ${what} looks at nothing on screen`);
		return {
			x: box.x / viewport.width,
			y: box.y / viewport.height,
			w: box.width / viewport.width,
			h: box.height / viewport.height,
		};
	};
	const shown = rest == null ? { x: 0, y: 0, w: 1, h: 1 } : await boxOf("reel's rest", rest);
	return {
		async mark(name, look, within) {
			marked.set(name, wall());
			if (look != null) focus[name] = await boxOf(`${name} mark`, look);
			if (within != null) {
				if (look == null) throw new Error(`the reel's ${name} mark keeps within a part but looks at nothing`);
				focus[name] = { ...focus[name], within: await boxOf(`${name} mark's bounds`, within) };
			}
		},
		async hold(ms) {
			const from = wall();
			await page.waitForTimeout(ms);
			holds.push([from, wall()]);
		},
		async offCamera(work) {
			// Reels that play in step share one clock, and a cut in one would
			// put it ahead of the others.
			if (realTime) throw new Error(`the reel for ${dir} plays in step with others, so it cannot cut`);
			const cut: [number, number] = [wall(), Infinity];
			cuts.push(cut);
			try {
				return await work();
			} finally {
				cut[1] = wall();
			}
		},
		async stop() {
			// The last frame stays on screen a moment before the reel ends.
			await page.waitForTimeout(LONGEST_HOLD_MS);
			const stopped = wall();
			recording = false;
			filming.delete(page);
			await cdp.send("Page.stopScreencast");
			await cdp.detach();
			await page.emulateMedia({ reducedMotion: reducedMotion ? "reduce" : "no-preference" });
			if (failure != null) throw failure;
			if (shots.length === 0) throw new Error(`the reel for ${dir} recorded no frames`);
			await Deno.remove(dir, { recursive: true }).catch((err) => {
				if (!(err instanceof Deno.errors.NotFound)) throw err;
			});
			await Deno.mkdir(dir, { recursive: true });
			const first = shots[0].seconds;
			const clock = reelClock(
				first,
				[...shots.map((shot) => shot.seconds), stopped],
				[...log.moves.map(({ start, end }): [number, number] => [start, end]), ...holds],
				cuts,
				realTime ? Infinity : LONGEST_HOLD_MS,
			);
			const reelAt = (seconds: number) => Math.round(clock(seconds));
			const frames: ReelIndex["frames"] = [];
			for (const [i, shot] of shots.entries()) {
				const file = `${String(i).padStart(5, "0")}.jpg`;
				await Deno.writeFile(`${dir}/${file}`, Uint8Array.from(atob(shot.data), (c) => c.charCodeAt(0)));
				frames.push({ at: reelAt(shot.seconds), file });
			}
			const marks: ReelIndex["marks"] = Object.fromEntries([...marked].map(([name, s]) => [name, reelAt(s)]));
			const pointer: ReelIndex["pointer"] = {
				viewport,
				moves: log.moves.map(({ start, end, x, y }) => ({
					at: reelAt(start),
					ms: reelAt(end) - reelAt(start),
					x,
					y,
				})),
				presses: log.presses.map(reelAt),
			};
			const index: ReelIndex = {
				width,
				height,
				length: reelAt(stopped),
				frames,
				marks,
				focus,
				rest: shown,
				pointer,
			};
			await Deno.writeTextFile(`${dir}/reel.json`, JSON.stringify(index));
		},
	};
}

/** Type `text` into `field` key by key at a person's pace. A reel plays at
 * close to real time, so typing faster than this reads as fast-forward. */
export async function typeOnFilm(field: Locator, text: string): Promise<void> {
	await field.pressSequentially(text, { delay: 60 });
}

/** Where each page's mouse is, so the next glide starts from it. */
const pointers = new WeakMap<Page, { x: number; y: number }>();

/** Move the mouse to (x, y) the way a hand does, over `ms` of wall time, so
 * the reel's pointer travels at the speed the reel plays. The mouse takes a
 * few steps on the way, for what hovers. */
export async function glide(page: Page, x: number, y: number, ms = 650): Promise<void> {
	const from = pointers.get(page) ?? { x, y };
	const start = Date.now() / 1000;
	filming.get(page)?.moves.push({ start, end: start + ms / 1000, x, y });
	for (const step of [0.25, 0.5, 0.75, 1]) {
		await page.waitForTimeout(Math.max(0, (start + (ms / 1000) * step) * 1000 - Date.now()));
		await page.mouse.move(from.x + (x - from.x) * step, from.y + (y - from.y) * step);
	}
	pointers.set(page, { x, y });
}

/** Press the mouse where it is, and let it go unless `hold` keeps it down,
 * as a drag does. */
export async function press(page: Page, { hold = false }: { hold?: boolean } = {}): Promise<void> {
	filming.get(page)?.presses.push(Date.now() / 1000);
	await page.mouse.down();
	if (hold) return;
	await page.waitForTimeout(70);
	await page.mouse.up();
}

/** Glide to the middle of `target` and press it. */
export async function glideClick(page: Page, target: Locator | { x: number; y: number }): Promise<void> {
	if ("x" in target) {
		await glide(page, target.x, target.y);
		await page.waitForTimeout(220);
		await press(page);
		return;
	}
	// A trial click waits until the target is visible, enabled, and still, so
	// the pointer aims where it will stay. The page can move it during the
	// glide, so the pointer follows before it presses.
	await target.click({ trial: true });
	const aimed = await middleOf(target);
	await glide(page, aimed.x, aimed.y);
	await page.waitForTimeout(220);
	await target.click({ trial: true });
	const there = await middleOf(target);
	if (Math.hypot(there.x - aimed.x, there.y - aimed.y) > 2) await glide(page, there.x, there.y, 200);
	await press(page);
}

async function middleOf(target: Locator): Promise<{ x: number; y: number }> {
	const box = await target.boundingBox();
	if (box == null) throw new Error(`nothing on screen to press for ${target}`);
	return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
}

/** Put the pointer at (x, y) without a reel seeing it move. */
export async function placePointer(page: Page, x: number, y: number): Promise<void> {
	await page.mouse.move(x, y);
	pointers.set(page, { x, y });
	const now = Date.now() / 1000;
	filming.get(page)?.moves.push({ start: now, end: now, x, y });
}

const types: Record<string, string> = {
	".html": "text/html; charset=utf-8",
	".css": "text/css",
	".js": "text/javascript",
	".json": "application/json",
	".wasm": "application/wasm",
	".svg": "image/svg+xml",
	".woff2": "font/woff2",
	".webp": "image/webp",
	".jpg": "image/jpeg",
};

/** Serve the files under `root` on a loopback port: the scene page and its
 * reels for the renderer, and the ocapnviz bundle for its film. Each root gets
 * its own origin, because the bundle names its assets from the root of its
 * origin, and any of those origins may read it, because the scene reads the
 * reels' indexes. */
export const serveDirectory = (root: string): Deno.HttpServer<Deno.NetAddr> =>
	Deno.serve({ hostname: "127.0.0.1", port: 0, onListen: () => {} }, async (req) => {
		let path = decodeURIComponent(new URL(req.url).pathname);
		if (path.includes("..")) return new Response("not found", { status: 404 });
		if (path.endsWith("/")) path += "index.html";
		let bytes: Uint8Array<ArrayBuffer>;
		try {
			bytes = await Deno.readFile(`${root}${path}`);
		} catch (err) {
			// A page treats any error status as a failure.
			if (err instanceof Deno.errors.NotFound) return new Response("not found", { status: 404 });
			throw err;
		}
		const type = types[path.slice(path.lastIndexOf("."))];
		const headers: Record<string, string> = { "access-control-allow-origin": "*" };
		if (type) headers["content-type"] = type;
		return new Response(bytes, { headers });
	});

/** True for a loopback address, the only kind a film or render may load. */
export const isLoopback = (url: string): boolean => new URL(url).hostname === "127.0.0.1";
