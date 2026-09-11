// The browser half of the generator: one headless Chromium, used twice.
//
// It renders the shader mark's settled unlit frame under SwiftShader, once per
// theme, and it rasterises finished SVG markup for the square icon. Both jobs
// need a browser and neither needs a second one, so this module owns the
// launch and hands back the two verbs.
//
// Three details are load-bearing and each was paid for once already. Chromium
// needs the unsafe-WebGPU and SwiftShader flags to have a GPU adapter at all
// with no device present. The page has to reach its own modules over http,
// because a module graph loaded from `file://` is refused as cross-origin. And
// the render must happen in the page rather than in an evaluated call, so the
// entry module is bundled and served rather than injected.

import { type Browser, chromium } from "playwright";
import type { Shot, View } from "./render.ts";

export type { View };

/** One captured frame: straight RGBA, one byte a channel, no row padding. */
export type Frame = { name: string; w: number; h: number; px: Uint8Array };

const here = new URL(".", import.meta.url).pathname;
const root = new URL("../../../", import.meta.url).pathname;

const contentTypes: Record<string, string> = {
	".html": "text/html",
	".js": "text/javascript",
	".css": "text/css",
};

/** Bundle the page entry into one browser-ready module. The mark's renderer is
 * TypeScript that imports its shader in pieces, and a browser reads neither, so
 * the whole graph is bundled to a scratch file the server hands over as
 * `/bundle.js`. The bundle is never committed: it is derived from the same
 * sources this generator reads, on every run. */
async function bundleEntry(into: string): Promise<string> {
	const out = into + "/bundle.js";
	const run = new Deno.Command(Deno.execPath(), {
		args: ["bundle", "--platform", "browser", "--minify", "-o", out, here + "render.ts"],
		stdout: "piped",
		stderr: "piped",
	});
	const done = await run.output();
	if (!done.success) {
		throw new Error("bundling the mark render failed:\n" + new TextDecoder().decode(done.stderr));
	}
	return out;
}

export class Capture {
	private constructor(
		private readonly browser: Browser,
		private readonly server: Deno.HttpServer,
		private readonly scratch: string,
		private readonly port: number,
	) {}

	/** Launch the browser and start serving the page, its bundle, and the
	 * tokens the mark reads its colors from. */
	static async open(port: number): Promise<Capture> {
		const scratch = await Deno.makeTempDir({ prefix: "glowcap-gen-mark-" });
		const bundle = await bundleEntry(scratch);
		const server = Deno.serve({ port, hostname: "127.0.0.1", onListen: () => {} }, async (request) => {
			const path = new URL(request.url).pathname;
			const name = path === "/" ? "page.html" : path.slice(1);
			const from = name === "bundle.js" ? bundle : name === "tokens.css" ? root + "ui/tokens.css" : here + name;
			try {
				const body = await Deno.readFile(from);
				const type = contentTypes[name.slice(name.lastIndexOf("."))] ?? "application/octet-stream";
				return new Response(body, { headers: { "content-type": type } });
			} catch {
				// The page asks for exactly what this generator serves it, so
				// the only request that reaches here is one the browser added
				// on its own, and 404 is the whole answer it wants. A read
				// that fails for any other reason surfaces as the missing
				// frame the caller then reports with the page's own log.
				return new Response("not found", { status: 404 });
			}
		});
		const browser = await chromium.launch({
			channel: "chromium",
			headless: true,
			args: [
				"--no-sandbox",
				"--enable-unsafe-webgpu",
				"--enable-unsafe-swiftshader",
				"--use-webgpu-adapter=swiftshader",
			],
		});
		return new Capture(browser, server, scratch, port);
	}

	/** Draw the named frames in the named theme and read them back. `size` is
	 * the pixel width the mark's 24-unit box is drawn at; the frame itself
	 * comes out larger, because the shader's view keeps air around the
	 * mushroom for its light. */
	async frames(theme: "dark" | "light", names: string[], size: number): Promise<{ view: View; frames: Frame[] }> {
		const page = await this.browser.newPage({ viewport: { width: 800, height: 800 } });
		const noise: string[] = [];
		page.on("pageerror", (error) => noise.push(error.message));
		try {
			const query = `size=${size}&theme=${theme}&frames=${encodeURIComponent(names.join(","))}`;
			await page.goto(`http://127.0.0.1:${this.port}/?${query}`);
			await page.waitForFunction("globalThis.markShots !== null", null, { timeout: 600_000 });
			const shots: Shot[] = await page.evaluate(() => globalThis.markShots ?? []);
			const view = await page.evaluate(() => globalThis.markView);
			if (shots.length !== names.length || view == null) {
				const log: string[] = await page.evaluate(() => globalThis.markLog);
				throw new Error(
					`the ${theme} render produced ${shots.length} of ${names.length} frames:\n  ` +
						log.concat(noise).join("\n  "),
				);
			}
			return {
				view,
				frames: shots.map((shot) => ({
					name: shot.name,
					w: shot.w,
					h: shot.h,
					px: Uint8Array.from(atob(shot.rgba), (c) => c.charCodeAt(0)),
				})),
			};
		} finally {
			await page.close();
		}
	}

	/** Draw finished SVG markup into a square canvas and return the PNG the
	 * browser encodes. The square icon has to be a raster because the places
	 * that read it (a touch icon, the README, a social card) take no SVG. */
	async rasterise(markup: string, side: number): Promise<Uint8Array> {
		const page = await this.browser.newPage({ viewport: { width: 600, height: 600 } });
		try {
			await page.setContent("<!doctype html><body style='margin:0'>");
			const encoded: string = await page.evaluate(async ([svg, size]) => {
				const image = new Image();
				image.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg as string);
				await image.decode();
				const canvas = document.createElement("canvas");
				canvas.width = size as number;
				canvas.height = size as number;
				const ctx = canvas.getContext("2d")!;
				ctx.drawImage(image, 0, 0, size as number, size as number);
				return canvas.toDataURL("image/png").split(",")[1];
			}, [markup, side] as const);
			return Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0));
		} finally {
			await page.close();
		}
	}

	async close(): Promise<void> {
		await this.browser.close();
		await this.server.shutdown();
		await Deno.remove(this.scratch, { recursive: true });
	}
}
