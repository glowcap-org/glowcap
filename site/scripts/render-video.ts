/// <reference lib="dom" />
/**
 * Renders the home page's video from `site/video/explainer.html`.
 *
 * The scene page runs every movement as a Web Animation on one timeline, and
 * shows reels of Rooms and ocapnviz in use, filmed by `capture-rooms.ts`,
 * `capture-rooms-directories.ts`, `film-ocapnviz.ts`, and
 * `film-rooms-traced.ts` (see `reel.ts`). This script pauses the animations and
 * seeks them frame by frame in several copies of the page in Chromium, and
 * puts each reel's frame for that moment into its image. It captures only the
 * frames that differ from the one before and pipes every frame, in order,
 * into the VP9 encoder Playwright installs beside its browsers. The output is
 * the same whatever the machine's speed. It renders the site's face that
 * `--theme=dark|light` names (dark by default), from the reels filmed in that
 * face, and writes three files into `--out` (default `site/assets`):
 *
 * - `glowcap-explainer-<theme>.webm`, the video
 * - `glowcap-explainer-<theme>.webp`, its poster, the first frame
 * - `glowcap-explainer.vtt`, captions made from the page's `[data-cue]`
 *   elements, the same words in both faces
 *
 * `zig build site-video` films every reel in both faces and renders both.
 * `--reels=<dir>` reads them from somewhere other than
 * `zig-out/site-video/reels/<theme>`.
 *
 * `--stills=<seconds>[,<seconds>…]` writes PNG frames at those times instead,
 * for reviewing a scene without a full render.
 */
import captureAssets from "./capture-assets.json" with { type: "json" };
import { type Browser, chromium, type Page } from "playwright";
import { outDirArg, replaceFile } from "./capture.ts";
import { isLoopback, type ReelIndex, reelsDirArg, serveDirectory, themeArg } from "./reel.ts";

const NAME = "glowcap-explainer";
const theme = themeArg();
/** The picture's files carry the face they were drawn in. */
const FACE = `${NAME}-${theme}`;
const FPS = 30;
const VIEWPORT = { width: 1280, height: 720 };
/** 1280×720 laid out, 1920×1080 encoded. */
const SCALE = 1.5;
/** Copies of the scene page capturing frames side by side. Screenshots, not
 * the encoder, set the render's pace. */
const STAGES = 4;
const arg = (name: string): string | undefined =>
	Deno.args.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3);
const outDir = outDirArg();
const stills = arg("stills")?.split(",").map(Number);
if (stills?.some((at) => !(at >= 0))) throw new Error("--stills takes times in seconds, as in --stills=5,12.5");
const reelsDir = reelsDirArg();

for (const ext of ["webm", "webp", "vtt"]) {
	const name = ext === "vtt" ? NAME : FACE;
	if (!captureAssets.includes(`${name}.${ext}`)) {
		throw new Error(`Undeclared site capture: ${name}.${ext}`);
	}
}

// Everything the render starts, stopped in reverse order when it ends. Each
// stop runs even when an earlier one throws.
await using started = new AsyncDisposableStack();

// What the scene takes from the site's TypeScript, its mycelium and
// ocapnviz's peer colors, bundled for the page.
const bundleDir = await Deno.makeTempDir({ prefix: "glowcap-video-scene-" });
started.defer(() => Deno.remove(bundleDir, { recursive: true }));
const bundled = (await new Deno.Command(Deno.execPath(), {
	args: [
		"bundle",
		"--quiet",
		"--platform",
		"browser",
		"--config",
		"deno.json",
		"site/video/scene.ts",
		"--output",
		`${bundleDir}/scene.js`,
	],
	stderr: "inherit",
}).output()).success;
if (!bundled) throw new Error("site/video/scene.ts did not bundle");

const server = serveDirectory("site");
started.defer(() => server.shutdown());
const reels = serveDirectory(reelsDir);
started.defer(() => reels.shutdown());
const bundle = serveDirectory(bundleDir);
started.defer(() => bundle.shutdown());
const reelsUrl = `http://127.0.0.1:${reels.addr.port}`;
// The scene reads each reel's index for its camera, so it learns where they
// are, and loads its bundle.
const sceneUrl = `http://127.0.0.1:${server.addr.port}/video/explainer.html?` +
	new URLSearchParams({ reels: reelsUrl, bundle: `http://127.0.0.1:${bundle.addr.port}/scene.js`, theme });

/** The VP9 encoder Playwright installs beside its browsers. A shared cache
 * can hold several revisions, and older ones encode only VP8, so the newest
 * revision wins. */
async function playwrightFfmpeg(): Promise<string> {
	const home = Deno.env.get("HOME") ?? "";
	const root = Deno.env.get("PLAYWRIGHT_BROWSERS_PATH") ??
		(Deno.build.os === "darwin" ? `${home}/Library/Caches/ms-playwright` : `${home}/.cache/ms-playwright`);
	const binary = Deno.build.os === "darwin" ? "ffmpeg-mac" : "ffmpeg-linux";
	const revisions: { revision: number; path: string }[] = [];
	for await (const entry of Deno.readDir(root)) {
		const revision = Number(/^ffmpeg-(\d+)$/.exec(entry.name)?.[1]);
		if (!entry.isDirectory || !(revision > 0)) continue;
		const path = `${root}/${entry.name}/${binary}`;
		if (await Deno.stat(path).then(() => true, () => false)) revisions.push({ revision, path });
	}
	const newest = revisions.sort((a, b) => b.revision - a.revision)[0];
	if (newest == null) {
		throw new Error(`no Playwright ffmpeg under ${root}: install it with \`playwright install ffmpeg\``);
	}
	return newest.path;
}

const vttTime = (seconds: number): string => {
	const ms = Math.round(seconds * 1000);
	const pad = (n: number, width = 2) => String(n).padStart(width, "0");
	return `${pad(Math.floor(ms / 3_600_000))}:${pad(Math.floor(ms / 60_000) % 60)}:${
		pad(Math.floor(ms / 1000) % 60)
	}.${pad(ms % 1000, 3)}`;
};

/** A reel's place in the scene: the image that shows it, the scene time it
 * starts playing at and the reel time it starts from, in milliseconds, and
 * how many times real time it plays at. */
type Placed = { name: string; index: ReelIndex; at: number; from: number; speed: number };

/** A scene page, its reels, and what each reel's image last showed, by reel
 * name. */
type Stage = { page: Page; reels: Placed[]; files: Map<string, string> };

/** The widest gap between two reel frames that are still one motion. A
 * moment in such a gap shows the nearer frame. A wider gap follows a still,
 * which holds until the next frame's time. Mixing two frames of motion
 * instead shows a moving line of text twice, a step apart. */
const MOTION_GAP_MS = 50;

/** The fastest a reel may play. Faster, typing and pointer moves read as
 * fast-forward, so a reel that would need more is cut shorter in its film. */
const MAX_SPEED = 1.35;

/** How far, in seconds, a reel's playing time may fall from the time the
 * scene gives it. */
const HOLD_SLACK = 1;

/** Read the scene's reel images and each reel's index, and check that each
 * plays from its first mark to its end in the time the scene gives it, at
 * one speed throughout. */
async function placeReels(page: Page): Promise<Placed[]> {
	const images = await page.evaluate(() =>
		[...document.querySelectorAll<HTMLImageElement>("img[data-reel]")].map((img) => ({
			name: img.dataset.reel ?? "",
			at: Number(img.dataset.at),
			len: Number(img.dataset.len),
			from: img.dataset.from ?? "",
			speed: Number(img.dataset.speed),
		}))
	);
	if (new Set(images.map(({ name }) => name)).size < images.length) {
		throw new Error("the scene shows one reel in two images");
	}
	return await Promise.all(images.map(async ({ name, at, len, from, speed }) => {
		if (name === "" || !(at >= 0 && len > 0 && speed > 0)) {
			throw new Error(`a reel image lacks its data-reel, data-at, data-len, or data-speed: ${name}`);
		}
		if (speed > MAX_SPEED) throw new Error(`the ${name} reel plays at ${speed}x, past ${MAX_SPEED}x`);
		const index: ReelIndex = JSON.parse(await Deno.readTextFile(`${reelsDir}/${name}/reel.json`));
		// The screencast can stamp two frames out of order, and the frames
		// are looked up by time.
		index.frames.sort((a, b) => a.at - b.at);
		const start = from === "" ? 0 : index.marks[from];
		if (start == null) throw new Error(`the ${name} reel has no mark ${from}`);
		// A film's length moves a little from take to take with the network.
		// Each film ends on a hold, so the scene may cut up to a second of it,
		// or hold the last frame up to a second longer.
		const plays = (index.length - start) / speed / 1000;
		if (Math.abs(plays - len) > HOLD_SLACK) {
			throw new Error(
				`the ${name} reel plays for ${plays.toFixed(2)} s at ${speed}x, but the scene gives it ${len} s`,
			);
		}
		return { name, index, at: at * 1000, from: start, speed };
	}));
}

/** The frame `placed` shows at scene time `ms`, by its reel time then: the
 * nearer of two frames of one motion, or the last frame before, held before
 * the reel starts and after it ends. */
function reelFrame({ index, at, from, speed }: Placed, ms: number): string {
	const reelAt = from + Math.max(0, ms - at) * speed;
	const i = Math.max(0, index.frames.findLastIndex((frame) => frame.at <= reelAt));
	const shown = index.frames[i];
	const after = index.frames[i + 1];
	const nearer = after != null && after.at - shown.at <= MOTION_GAP_MS && after.at - reelAt < reelAt - shown.at;
	return nearer ? after.file : shown.file;
}

/** One copy of the scene page, paused and seekable. Each sits in its own
 * browser context, so Chromium gives each its own renderer process and the
 * copies capture frames in parallel. */
async function openStage(browser: Browser): Promise<Stage> {
	const context = await browser.newContext({ viewport: VIEWPORT, deviceScaleFactor: SCALE, colorScheme: theme });
	// No frame may depend on the network.
	await context.route((url) => !isLoopback(url.href), (route) => route.abort("blockedbyclient"));
	const page = await context.newPage();
	const errors: string[] = [];
	page.on("pageerror", (err) => errors.push(err.message));
	page.on("requestfailed", (req) => errors.push(`${req.url()} failed to load`));
	page.on("response", (res) => {
		if (res.status() >= 400) errors.push(`${res.url()} answered ${res.status()}`);
	});
	await page.goto(sceneUrl, { waitUntil: "load" });
	// The scene reads part of its text from the site, and says when it is
	// ready with data-duration, or why it is not with data-failed.
	await page.waitForFunction(
		() => {
			const { duration, failed } = document.documentElement.dataset;
			return duration != null || failed != null;
		},
		undefined,
		{ timeout: 30_000 },
	);
	const failed = await page.evaluate(() => document.documentElement.dataset.failed);
	if (failed != null) errors.push(failed);
	await page.evaluate(() => document.fonts.ready);
	if (errors.length > 0) throw new Error(`the scene page failed:\n${errors.join("\n")}`);
	return { page, reels: await placeReels(page), files: new Map() };
}

/** Moves every animation to `seconds`, and each reel image to its frame
 * there, and returns what the frame shows: each animated element's computed
 * value of each property its keyframes name, each reel's frame, and what the
 * scene's `drawFrame` drew. Two frames with the same signature draw the same pixels, so the renderer
 * captures a frame only when its signature changes. */
async function seek(stage: Stage, seconds: number): Promise<string> {
	const changes = stage.reels.flatMap((placed) => {
		const file = reelFrame(placed, seconds * 1000);
		if (stage.files.get(placed.name) === file) return [];
		stage.files.set(placed.name, file);
		return [{ name: placed.name, src: `${reelsUrl}/${placed.name}/${file}` }];
	});
	if (changes.length > 0) {
		await stage.page.evaluate(async (changes) => {
			await Promise.all(changes.map(async ({ name, src }) => {
				const img = document.querySelector(`img[data-reel="${name}"]`);
				if (!(img instanceof HTMLImageElement)) throw new Error(`no image for the ${name} reel`);
				img.src = src;
				await img.decode();
			}));
		}, changes);
	}
	const shown = await stage.page.evaluate((ms) => {
		const animations = document.getAnimations();
		for (const animation of animations) {
			animation.pause();
			animation.currentTime = ms;
		}
		const shown: string[] = [];
		for (const animation of animations) {
			const effect = animation.effect;
			if (!(effect instanceof KeyframeEffect) || effect.target == null) continue;
			const style = getComputedStyle(effect.target);
			for (const frame of effect.getKeyframes()) {
				for (const property of Object.keys(frame)) {
					if (["offset", "computedOffset", "easing", "composite"].includes(property)) continue;
					shown.push(style.getPropertyValue(property.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)));
				}
			}
		}
		// The scene draws what no animation holds, its mycelium, and says
		// what it drew.
		const draw = (globalThis as { drawFrame?: (ms: number) => string }).drawFrame;
		if (draw == null) throw new Error("the scene page defines no drawFrame");
		shown.push(draw(ms));
		return shown.join("|");
	}, seconds * 1000);
	return `${shown}|${[...stage.files.values()].join(",")}`;
}

const browser = await chromium.launch();
started.defer(() => browser.close());
const first = await openStage(browser);
const { page } = first;
const duration = Number(await page.evaluate(() => document.documentElement.dataset.duration));
if (!(duration > 0)) throw new Error("the scene page reported no duration");

await Deno.mkdir(outDir, { recursive: true });
if (stills) {
	for (const at of stills) {
		await seek(first, at);
		await page.screenshot({ path: `${outDir}/${FACE}-${at}s.png` });
	}
} else {
	const cues = await page.evaluate(() =>
		[...document.querySelectorAll<HTMLElement>("[data-cue]")].map((cue) => ({
			start: Number(cue.dataset.at),
			len: Number(cue.dataset.len),
			text: (cue.dataset.cue || cue.textContent || "").replace(/\s+/g, " ").trim(),
		}))
	);
	for (const { start, len, text } of cues) {
		if (!(start >= 0 && len > 0 && text !== "")) {
			throw new Error(`a caption cue lacks its time or text: ${text}`);
		}
	}
	const vtt = cues
		.sort((a, b) => a.start - b.start)
		.map(({ start, len, text }) => `${vttTime(start)} --> ${vttTime(start + len)}\n${text}`);
	await replaceFile(
		`${outDir}/${NAME}.vtt`,
		(temp) => Deno.writeTextFile(temp, `WEBVTT\n\n${vtt.join("\n\n")}\n`),
	);

	await seek(first, 0);
	await replaceFile(`${outDir}/${FACE}.webp`, async (temp) => {
		await page.screenshot({ path: temp, type: "webp", quality: 90 });
	});

	const stages = [first, ...await Promise.all(Array.from({ length: STAGES - 1 }, () => openStage(browser)))];
	const frames = Math.round(duration * FPS);
	let captured = 0;
	await replaceFile(`${outDir}/${FACE}.webm`, async (temp) => {
		const ffmpeg = new Deno.Command(await playwrightFfmpeg(), {
			// Playwright's ffmpeg build reads stdin as `pipe:0` and refuses `-`.
			// deno-fmt-ignore
			args: [
				"-hide_banner", "-loglevel", "error", "-y",
				"-f", "image2pipe", "-framerate", String(FPS), "-c:v", "mjpeg", "-i", "pipe:0",
				// JPEG frames are full-range BT.601. The video is converted to,
				// and tagged as, limited-range BT.709, so no browser guesses.
				"-vf", "scale=in_color_matrix=bt601:in_range=full:out_color_matrix=bt709:out_range=tv,format=yuv420p",
				"-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv",
				// The ground is dark and low in contrast. Above CRF 20, VP9 turns
				// its gradients into blotches and drops the faint hyphae.
				"-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "20",
				"-row-mt", "1", "-deadline", "good", "-cpu-used", "2",
				"-an", "-f", "webm", temp,
			],
			stdin: "piped",
			stderr: "inherit",
		}).spawn();
		const writer = ffmpeg.stdin.getWriter();
		try {
			// Each stage seeks one frame of a batch. A frame that shows what the
			// one before it showed reuses that capture, the rest are captured
			// side by side, and the batch goes to the encoder in frame order.
			let previous: { shown: string; shot: Uint8Array } = { shown: "", shot: new Uint8Array() };
			for (let first = 0; first < frames; first += stages.length) {
				const batch = stages.slice(0, Math.min(stages.length, frames - first));
				const shown = await Promise.all(batch.map((stage, k) => seek(stage, (first + k) / FPS)));
				const fresh = await Promise.all(
					batch.map((stage, k) =>
						shown[k] === (k === 0 ? previous.shown : shown[k - 1])
							? null
							// At full quality, so the encoder is the only step that
							// rounds a dark gradient into bands. Playwright's
							// ffmpeg reads JPEG and not PNG.
							: stage.page.screenshot({ type: "jpeg", quality: 100 })
					),
				);
				captured += fresh.filter((shot) => shot != null).length;
				for (let k = 0; k < batch.length; k++) {
					previous = { shown: shown[k], shot: fresh[k] ?? previous.shot };
					await writer.write(previous.shot);
				}
			}
		} catch (err) {
			// A write breaks the pipe when the encoder has already exited, and
			// its exit code and stderr say why. Any other failure is the
			// render's own, and the encoder is stopped.
			if (err instanceof Deno.errors.BrokenPipe) {
				const { code } = await ffmpeg.status;
				throw new Error(`the encoder exited with ${code} during the render`, { cause: err });
			}
			try {
				ffmpeg.kill();
			} catch {
				// tolerant: the encoder has already exited, and the goal is only that it is gone.
			}
			await ffmpeg.status;
			throw err;
		}
		await writer.close();
		const { code } = await ffmpeg.status;
		if (code !== 0) throw new Error(`the encoder exited with ${code}`);
	});
	console.log(
		`rendered ${FACE}: ${duration} s, ${cues.length} captions, ${captured} of ${frames} frames captured, into ${outDir}`,
	);
}
