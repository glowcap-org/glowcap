/**
 * headless.ts: the one place ocapnviz's browser scripts start Chromium and
 * bring the app to its Build stage.
 *
 * Chromium in the devcontainer has neither the kernel support its sandbox
 * helper expects nor a GPU, so `--no-sandbox` skips the sandbox and
 * `--disable-gpu` skips the device probe. Without them the launch fails or
 * stalls before the first page.
 */
import { type Browser, type BrowserContextOptions, chromium, type Page } from "playwright";

/** Start the container's headless Chromium. The caller owns `close()`. */
export function launchHeadless(): Promise<Browser> {
	return chromium.launch({
		headless: true,
		args: ["--no-sandbox", "--disable-gpu"],
	});
}

/** Open a page on `browser` with the app's saved state cleared, so a run
 *  starts from the app's first-run document. */
export async function openFreshPage(
	browser: Browser,
	contextOptions: BrowserContextOptions,
): Promise<Page> {
	const context = await browser.newContext(contextOptions);
	const page = await context.newPage();
	await page.addInitScript(() => {
		try {
			localStorage.removeItem("ocapnviz:app-state");
		} catch { /* first run has nothing to clear */ }
	});
	return page;
}

/** A page at the Build stage with the first peer the stage draws selected,
 *  which puts the peer panel in the Inspector. */
export interface BuildStage {
	browser: Browser;
	page: Page;
	/** Page errors seen so far; a probe appends its own findings. */
	failures: string[];
}

/**
 * Load `url` in a 1600x1000 window, switch to Build mode, and click the
 * first peer. Prints a failure and exits when the stage draws no peer, since
 * every probe built on this needs one.
 */
export async function openBuildStage(url: string): Promise<BuildStage> {
	const browser = await launchHeadless();
	const page = await openFreshPage(browser, {
		viewport: { width: 1600, height: 1000 },
	});
	const failures: string[] = [];
	page.on("pageerror", (e) => failures.push(`pageerror: ${e.message}`));
	await page.goto(url, { waitUntil: "networkidle" });
	await page.waitForSelector("canvas#ocv-pixi");
	await page.waitForTimeout(500);
	await page.getByRole("radio", { name: "Build" }).click();
	await page.waitForTimeout(300);

	const peers = await page.evaluate(() => {
		type Peer = { peer: { id: string }; position?: { x: number; y: number } };
		type VP = { toScreen: (x: number, y: number) => { x: number; y: number } };
		const g = globalThis as unknown as {
			__ocv?: { engine?: { queries?: { peers?: Iterable<Peer> } } };
			__ocvViewport?: VP;
		};
		const list = g.__ocv?.engine?.queries?.peers;
		const vp = g.__ocvViewport;
		if (!list || !vp) return [];
		const out: { id: string; sx: number; sy: number }[] = [];
		for (const p of list) {
			if (!p.position) continue;
			const s = vp.toScreen(p.position.x, p.position.y);
			out.push({ id: p.peer.id, sx: s.x, sy: s.y });
		}
		return out;
	});
	if (peers.length === 0) {
		console.log("FAIL — no peers on stage");
		await browser.close();
		Deno.exit(1);
	}
	await page.mouse.click(peers[0]!.sx, peers[0]!.sy);
	await page.waitForTimeout(300);
	return { browser, page, failures };
}
