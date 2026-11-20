// zig build mycelium-test passes the browser bundle as argv[0] and runs from
// the repository root. Count GPU work and prove activity stops at its boundary.
// SwiftShader timings are not measurements of a phone.
import { type Browser, chromium } from "playwright";
import { deepStrictEqual as assertEquals, ok as assert } from "node:assert/strict";
import type {} from "./mycelium_page.ts";

const bundle = await Deno.readFile(Deno.args[0]);
const tokens = await Deno.readFile("ui/tokens.css");
const server = Deno.serve({ hostname: "127.0.0.1", port: 0, onListen() {} }, (request) => {
	const path = new URL(request.url).pathname;
	if (path === "/fixture.js") return new Response(bundle, { headers: { "content-type": "text/javascript" } });
	if (path === "/tokens.css") return new Response(tokens, { headers: { "content-type": "text/css" } });
	if (path !== "/") return new Response(null, { status: 404 });
	return new Response(
		'<meta name="viewport" content="width=device-width, initial-scale=1">' +
			'<link rel="stylesheet" href="/tokens.css"><body><script type="module" src="/fixture.js"></script></body>',
		{ headers: { "content-type": "text/html" } },
	);
});
let browser: Awaited<ReturnType<typeof chromium.launch>> | undefined;
try {
	browser = await chromium.launch({
		channel: "chromium",
		headless: true,
		args: [
			"--no-sandbox",
			"--enable-unsafe-webgpu",
			"--enable-unsafe-swiftshader",
			"--use-webgpu-adapter=swiftshader",
		],
	});
	await drift(browser);
	for (const mobile of [true, false]) {
		const page = await browser.newPage({
			viewport: mobile ? { width: 390, height: 844 } : { width: 1280, height: 800 },
			deviceScaleFactor: mobile ? 3 : 1,
			isMobile: mobile,
			hasTouch: mobile,
		});
		const errors: string[] = [];
		page.on("pageerror", (error) => errors.push(error.message));
		try {
			const epoch = new Date("2026-01-01T00:00:00Z");
			await page.clock.install({ time: epoch });
			await page.clock.pauseAt(epoch);
			await page.goto(`http://127.0.0.1:${server.addr.port}/`);
			const mounted = await page.evaluate(() => myceliumFixture.start());
			assertEquals(mounted, !mobile);
			if (mobile) {
				await page.mouse.click(10, 10);
				await page.setViewportSize({ width: 844, height: 390 });
				await page.evaluate(() => document.documentElement.setAttribute("data-theme", "dark"));
				await page.clock.fastForward(10_000);
				const cost = await page.evaluate(() => myceliumFixture.read());
				assert(Object.values(cost).every((value) => value === 0), JSON.stringify(cost));
				console.log("mycelium mobile:", JSON.stringify(cost));
				continue;
			}
			await page.clock.fastForward(850);
			const grown = await page.evaluate(() => myceliumFixture.read());
			assertEquals(grown.canvases, 3);
			assertEquals(
				await page.evaluate(() => myceliumFixture.rises()),
				{ far: null, focal: 0, near: 0, light: 0, boxes: 3 },
				"a page that does not drift keeps the far plane on the focal canvas and moves nothing",
			);
			assert(grown.buffers > 0 && grown.pipelines > 0 && grown.submissions > 0);
			await page.clock.fastForward(100);
			assertEquals(
				(await page.evaluate(() => myceliumFixture.read())).planes,
				grown.planes,
				"cooling must not redraw geometry",
			);
			// The light's frames wait for the device: a run of display frames
			// with no time for the device to finish between them draws one.
			await page.evaluate(() => myceliumFixture.settled());
			const ready = (await page.evaluate(() => myceliumFixture.read())).submissions;
			await page.clock.runFor(64);
			assertEquals(
				(await page.evaluate(() => myceliumFixture.read())).submissions,
				ready + 1,
				"a frame waits for the device to finish the last",
			);
			await page.evaluate(() => myceliumFixture.settled());
			await page.evaluate(() => document.documentElement.setAttribute("data-theme", "dark"));
			await page.clock.fastForward(100);
			assert(
				(await page.evaluate(() => myceliumFixture.read())).planes > grown.planes,
				"theme changes must repaint during cooling",
			);

			await page.evaluate(() => myceliumFixture.hide(true));
			const hidden = await page.evaluate(() => myceliumFixture.read());
			assertEquals(hidden.timers, 0);
			assertEquals(hidden.frames, 0);
			await page.clock.fastForward(10_000);
			assertEquals(await page.evaluate(() => myceliumFixture.read()), hidden);
			await page.evaluate(() => myceliumFixture.hide(false));
			const visible = await page.evaluate(() => myceliumFixture.read());
			assertEquals(visible.timers, 2, "one ambient timer and one breath timer after resume");
			await page.evaluate(() => myceliumFixture.hide(false));
			assertEquals(
				(await page.evaluate(() => myceliumFixture.read())).timers,
				2,
				"resume cannot duplicate timers",
			);

			await page.evaluate(() => myceliumFixture.expectMotionChange());
			await page.emulateMedia({ reducedMotion: "reduce" });
			await page.evaluate(() => myceliumFixture.motionChanged());
			const reduced = await page.evaluate(() => myceliumFixture.read());
			assertEquals(reduced.timers, 0);
			assertEquals(reduced.frames, 0);
			await page.clock.fastForward(10_000);
			assertEquals(await page.evaluate(() => myceliumFixture.read()), reduced);
			await page.evaluate(() => myceliumFixture.expectMotionChange());
			await page.emulateMedia({ reducedMotion: "no-preference" });
			await page.evaluate(() => myceliumFixture.motionChanged());
			assertEquals((await page.evaluate(() => myceliumFixture.read())).timers, 2);
			const beforeLoss = await page.evaluate(() => myceliumFixture.read());
			await page.evaluate(() => myceliumFixture.loseDevice());
			const recovered = await page.evaluate(() => myceliumFixture.read());
			assert(recovered.adapters > beforeLoss.adapters && recovered.buffers > beforeLoss.buffers);
			assertEquals(recovered.timers, 2, "device recovery starts one ambient and one breath timer");
			assertEquals(await page.evaluate(() => myceliumFixture.gpuErrors()), []);
			await page.evaluate(() => myceliumFixture.dim());
			assertEquals((await page.evaluate(() => myceliumFixture.read())).timers, 0);
			await page.evaluate(() => myceliumFixture.regrow());
			assertEquals((await page.evaluate(() => myceliumFixture.read())).frames, 1);
			await page.evaluate(() => myceliumFixture.stop());
			const stopped = await page.evaluate(() => myceliumFixture.read());
			assertEquals(stopped.canvases, 0);
			assertEquals(stopped.timers, 0);
			assertEquals(stopped.frames, 0);
			assertEquals(stopped.unconfigured, 3);
			await page.evaluate(() => {
				myceliumFixture.hide(true);
				myceliumFixture.hide(false);
				myceliumFixture.regrow();
			});
			await page.clock.fastForward(10_000);
			assertEquals(await page.evaluate(() => myceliumFixture.read()), stopped);
			console.log("mycelium desktop: growth, theme, suspension, device recovery and teardown passed");
		} finally {
			await page.close();
			assertEquals(errors, []);
		}
	}
} finally {
	await browser?.close();
	await server.shutdown();
}

/** The site's drift: each plane rises by its own share of the scroll, moved
 * by the compositor with nothing redrawn, holds still under reduced motion,
 * and hears no scroll once stopped. */
async function drift(browser: Browser) {
	const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
	const errors: string[] = [];
	page.on("pageerror", (error) => errors.push(error.message));
	try {
		const epoch = new Date("2026-01-01T00:00:00Z");
		await page.clock.install({ time: epoch });
		await page.clock.pauseAt(epoch);
		await page.goto(`http://127.0.0.1:${server.addr.port}/?drift`);
		assertEquals(await page.evaluate(() => myceliumFixture.start()), true);
		await page.clock.fastForward(950);
		const rises = () => page.evaluate(() => myceliumFixture.rises());
		const top = { far: 0, focal: 0, near: 0, light: 0, boxes: 4 };
		const grown = await page.evaluate(() => myceliumFixture.read());
		assertEquals(grown.canvases, 4);
		assertEquals(await rises(), top);
		await page.evaluate(() => myceliumFixture.scroll(document.documentElement.scrollHeight));
		await page.clock.runFor(32);
		const bottom = { far: -28, focal: -64, near: -150, light: -64, boxes: 4 };
		assertEquals(await rises(), bottom);
		assertEquals(
			(await page.evaluate(() => myceliumFixture.read())).planes,
			grown.planes,
			"scrolling redraws nothing",
		);

		await page.evaluate(() => myceliumFixture.expectMotionChange());
		await page.emulateMedia({ reducedMotion: "reduce" });
		await page.evaluate(() => myceliumFixture.motionChanged());
		assertEquals(await rises(), top, "reduced motion holds the ground still");
		await page.evaluate(() => myceliumFixture.expectMotionChange());
		await page.emulateMedia({ reducedMotion: "no-preference" });
		await page.evaluate(() => myceliumFixture.motionChanged());
		assertEquals(await rises(), bottom);

		await page.evaluate(() => myceliumFixture.stop());
		const stopped = await page.evaluate(() => myceliumFixture.read());
		assertEquals(stopped.unconfigured, 4);
		assertEquals((await rises()).boxes, 0);
		await page.evaluate(() => myceliumFixture.scroll(0));
		await page.clock.runFor(32);
		assertEquals(await page.evaluate(() => myceliumFixture.read()), stopped, "a stopped ground hears no scroll");
		console.log("mycelium drift: rise, reduced motion and teardown passed");
	} finally {
		await page.close();
		assertEquals(errors, []);
	}
}
