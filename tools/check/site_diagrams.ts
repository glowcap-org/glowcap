/// <reference lib="dom" />
// site-render-check proves both renderers: the published page has declarative
// shadow roots without JavaScript, while Zine's raw preview themes its images
// in the browser. Both must inherit the page palette inside each drawing.
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
