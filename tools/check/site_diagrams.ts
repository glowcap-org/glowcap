/// <reference lib="dom" />
// site-render-check proves both renderers: the published page has declarative
// shadow roots without JavaScript, while Zine's raw preview themes its images
// in the browser. Both must inherit the page palette inside each drawing.
// It also proves the viewer: on a phone every diagram fits its column, and
// its enlarge button or a tap opens the drawing full screen at its own width;
// Escape and the back gesture close it. On a desktop neither control shows.
import type { Browser } from "playwright";

export async function checkDiagrams(browser: Browser, base: string, siteRoot: string): Promise<void> {
	const template = await Deno.readTextFile("site/layouts/templates/base.shtml");
	const preview = template.match(/<script id="preview-diagrams">[\s\S]*?<\/script>/)?.[0];
	if (preview == null) throw new Error("the raw site preview needs its diagram renderer");
	const built = await Deno.readTextFile(`${siteRoot}/concepts/index.html`);
	if (built.includes('id="preview-diagrams"')) throw new Error("the published page retains the preview renderer");
	for (const raw of [false, true]) {
		for (const theme of ["dark", "light"]) {
			const context = await browser.newContext({ javaScriptEnabled: raw, reducedMotion: "reduce" });
			try {
				const page = await context.newPage();
				const errors: string[] = [];
				let svgRequests = 0;
				page.on("pageerror", (error) => errors.push(String(error)));
				page.on("request", (request) => {
					if (request.url().endsWith(".svg")) svgRequests++;
				});
				const html = raw
					? `<html data-theme="${theme}"><head><link rel="stylesheet" href="/tokens.css"><link rel="stylesheet" href="/style.css"><link rel="stylesheet" href="/prose.css"></head><body><main class="prose"><figure><img src="/diagram-capability.svg"><figcaption>A reference</figcaption></figure></main>${preview}</body></html>`
					: built.replace('<html lang="en"', `<html data-theme="${theme}" lang="en"`);
				await page.route(
					base + "/concepts/",
					(route) => route.fulfill({ contentType: "text/html", body: html }),
				);
				await page.goto(base + "/concepts/", { waitUntil: "networkidle" });
				await page.locator(".diagram svg").first().waitFor({ state: "visible", timeout: 5000 });
				const problem = await page.evaluate((expectedTheme) => {
					if (document.documentElement.dataset.theme !== expectedTheme) {
						return "the requested theme is missing";
					}
					const diagrams = [...document.querySelectorAll(".diagram")];
					if (!diagrams.length) return "no diagrams render";
					for (const host of diagrams) {
						const svg = host.shadowRoot?.querySelector("svg");
						if (!svg || svg.getBoundingClientRect().height === 0) return "a diagram is blank";
					}
					const host = diagrams[0];
					const warm = host.shadowRoot?.querySelector('[fill^="var(--dia-warm-fill"]');
					const fill = warm?.getAttribute("fill");
					if (!warm || !fill) return "the palette witness is missing";
					const probe = document.createElement("span");
					probe.style.color = fill;
					document.body.append(probe);
					const expected = getComputedStyle(probe).color;
					probe.remove();
					return getComputedStyle(warm).fill === expected
						? null
						: "the drawing does not inherit its page palette";
				}, theme);
				if (problem || errors.length || (!raw && svgRequests !== 0)) {
					throw new Error(
						`diagrams ${raw ? "preview" : "built"} ${theme}: ${
							problem ?? errors.join(", ")
						}, SVG requests ${svgRequests}`,
					);
				}
			} finally {
				await context.close();
			}
		}
	}
}

export async function checkDiagramViewer(browser: Browser, base: string): Promise<void> {
	for (const width of [390, 1600]) {
		const context = await browser.newContext({ viewport: { width, height: 844 }, reducedMotion: "reduce" });
		try {
			const page = await context.newPage();
			const errors: string[] = [];
			page.on("pageerror", (error) => errors.push(String(error)));
			const fail = (problem: string) => {
				throw new Error(
					`diagram viewer at ${width}px: ${problem}${errors.length ? `; ${errors.join(", ")}` : ""}`,
				);
			};
			await page.goto(base + "/concepts/", { waitUntil: "networkidle" });
			const scrolling = await page.evaluate(() =>
				[...document.querySelectorAll(".prose figure")].filter((f) => f.scrollWidth > f.clientWidth).length
			);
			if (scrolling) fail(`${scrolling} figure(s) scroll sideways`);
			const button = page.locator(".prose figure .diagram-open").first();
			const viewer = page.locator("dialog.diagram-viewer");
			const viewerOpen = () => viewer.evaluate((d: HTMLDialogElement) => d.open);
			const drawing = page.locator(".prose figure .diagram").first();
			if (width > 600) {
				if (await button.isVisible()) fail("the enlarge button shows on a wide screen");
				await drawing.click();
				if (await viewerOpen()) fail("a tap opened the viewer on a wide screen");
				continue;
			}
			if (!(await button.isVisible())) fail("the enlarge button is hidden");
			const opened = async (how: string) => {
				if (!(await viewerOpen())) fail(`${how} did not open the viewer`);
				const shown = await page.evaluate(() => {
					const stage = document.querySelector(".diagram-viewer-stage");
					const svg = stage?.querySelector(".diagram")?.shadowRoot?.querySelector("svg");
					if (stage == null || svg == null) return "the viewer holds no drawing";
					const drawn = svg.getBoundingClientRect().width;
					if (Math.round(drawn) !== svg.viewBox.baseVal.width) {
						return `the drawing is ${drawn}px wide, not its own ${svg.viewBox.baseVal.width}`;
					}
					if (stage.scrollWidth <= stage.clientWidth) return "the stage does not pan";
					return null;
				});
				if (shown) fail(shown);
			};
			const closed = async (how: string) => {
				if (await viewerOpen()) fail(`${how} left the viewer open`);
				if (!page.url().endsWith("/concepts/")) fail(`${how} left the page for ${page.url()}`);
			};
			await button.click();
			await opened("the enlarge button");
			await page.keyboard.press("Escape");
			await page.waitForFunction(() => history.state?.diagramViewer !== true);
			await closed("Escape");
			await drawing.click();
			await opened("a tap on the drawing");
			await page.goBack();
			await closed("the back gesture");
			if (errors.length) fail("the page threw");
		} finally {
			await context.close();
		}
	}
}
