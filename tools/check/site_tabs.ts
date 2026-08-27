/// <reference lib="dom" />
// Press the website's code-tabs and prove the example switches. Every
// first-call transport snippet on Start building, the binding pages, the
// transport pages, and the relay page ships as a `code-tabs` block that a
// template script (site/layouts/templates/base.shtml) enhances into a tab
// strip: label/fence pairs become buttons, and clicking one hides the other
// panels. `site_render.ts` proves the pages load without console errors and
// do not overflow, but it never clicks, so a broken `select()` would ship a
// tab strip that renders and does nothing. This proof does the click.
//
// For every built page that carries a `code-tabs` block with two or more
// panels, it asserts the enhancement ran (a `.tab-bar` exists), the first
// panel opens and the rest are hidden, and then, for each other tab, that
// clicking it shows exactly that panel, hides the first, and moves
// `aria-pressed` onto the clicked button. The copy button rides the same
// selection, so it also asserts one copy button sits in the strip.
//
// Validated against injected defects: neutering `select()` so every panel
// stays visible failed on all 11 tabbed pages (139 visible-panel assertions),
// and dropping the click listener so the panel never moves failed the same
// pages on both the visible-panel and aria-pressed assertions. The
// tabbed-page floor below guards a vacuous pass if a build renders no tabs.
// Not validated against: a page whose tabs switch but whose panel content is
// wrong, which the snippet compile checks (site-zig-examples-check and
// siblings) own instead.
//
// Usage: deno run --allow-all tools/check/site_tabs.ts <site-root>

import { chromium } from "playwright";

const siteRoot = Deno.args[0];
if (!siteRoot) {
	console.error("usage: site_tabs.ts <site-root>");
	Deno.exit(2);
}

const types: Record<string, string> = {
	".html": "text/html; charset=utf-8",
	".css": "text/css",
	".js": "text/javascript",
	".svg": "image/svg+xml",
	".png": "image/png",
	".woff2": "font/woff2",
	".wasm": "application/wasm",
};
const server = Deno.serve({ port: 0, onListen: () => {} }, async (req) => {
	const url = new URL(req.url);
	let path = decodeURIComponent(url.pathname);
	if (!path.startsWith("/pancake/")) return new Response("not found", { status: 404 });
	path = path.slice("/pancake".length);
	if (path.endsWith("/")) path += "index.html";
	try {
		const body = await Deno.readFile(siteRoot + path);
		const dot = path.lastIndexOf(".");
		const type = dot >= 0 ? types[path.slice(dot)] : undefined;
		return new Response(body, { headers: type ? { "content-type": type } : {} });
	} catch {
		return new Response("not found", { status: 404 });
	}
});
const base = `http://127.0.0.1:${server.addr.port}`;

const pages: string[] = [];
async function walk(dir: string, rel: string): Promise<void> {
	for await (const entry of Deno.readDir(dir)) {
		if (!entry.isDirectory && entry.name === "index.html") pages.push(`/pancake${rel}/`);
		if (entry.isDirectory) await walk(`${dir}/${entry.name}`, `${rel}/${entry.name}`);
	}
}
await walk(siteRoot, "");
pages.sort();

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1024, height: 844 } });
const failures: string[] = [];
let tabbedPages = 0;

for (const p of pages) {
	try {
		await page.goto(base + p, { waitUntil: "networkidle", timeout: 20_000 });
	} catch (e) {
		failures.push(`${p}: ${e}`);
		continue;
	}
	// How many enhanced tab strips does this page carry, and how many panels each?
	const boxes = await page.evaluate(() => {
		const out: { hasBar: boolean; tabs: number; panels: number; copy: number }[] = [];
		for (const box of document.querySelectorAll(".block.code-tabs")) {
			const bar = box.querySelector(".tab-bar");
			out.push({
				hasBar: bar !== null,
				tabs: bar ? bar.querySelectorAll("button:not(.copy-btn)").length : 0,
				panels: box.querySelectorAll("pre").length,
				copy: box.querySelectorAll(".copy-btn").length,
			});
		}
		return out;
	});
	for (const [b, box] of boxes.entries()) {
		if (box.panels < 2) continue; // a single-panel block is not tabbed
		tabbedPages += b === 0 ? 1 : 0;
		if (!box.hasBar) {
			failures.push(
				`${p}: code-tabs block ${b} has ${box.panels} panels but no tab strip (enhancement did not run)`,
			);
			continue;
		}
		if (box.tabs !== box.panels) {
			failures.push(`${p}: block ${b} has ${box.tabs} tabs for ${box.panels} panels`);
			continue;
		}
		if (box.copy !== 1) {
			failures.push(`${p}: block ${b} has ${box.copy} copy buttons, expected 1`);
		}
		// Press every tab in turn and assert only its panel shows.
		// Address tabs and panels by index inside the page rather than through a
		// CSS selector: the copy button shares the button tag, so nth-of-type
		// would miscount it, and index order is exactly what `select()` uses.
		for (let want = 0; want < box.tabs; want++) {
			const shown = await page.evaluate((args) => {
				const boxes = document.querySelectorAll(".block.code-tabs");
				const el = boxes[args.b];
				const buttons = Array.from(el.querySelectorAll(".tab-bar button")).filter((n) =>
					!n.classList.contains("copy-btn")
				) as HTMLButtonElement[];
				buttons[args.want].click();
				const panels = Array.from(el.querySelectorAll("pre")) as HTMLElement[];
				return {
					visible: panels.map((pre, i) => (pre.hidden ? -1 : i)).filter((i) => i >= 0),
					pressed: buttons.map((btn, i) => (btn.getAttribute("aria-pressed") === "true" ? i : -1)).filter((
						i,
					) => i >= 0),
				};
			}, { b, want });
			if (shown.visible.length !== 1 || shown.visible[0] !== want) {
				failures.push(`${p}: block ${b} tab ${want} clicked, visible panels ${JSON.stringify(shown.visible)}`);
			}
			if (shown.pressed.length !== 1 || shown.pressed[0] !== want) {
				failures.push(`${p}: block ${b} tab ${want} clicked, aria-pressed on ${JSON.stringify(shown.pressed)}`);
			}
		}
	}
}
await page.close();
await browser.close();
await server.shutdown();

// The first-call matrix spans Start building, four binding pages, and four
// transport/relay pages. A real build renders tabs on every one; a handful is
// the honest floor below which the walk found nothing to press.
const floor = 6;
if (tabbedPages < floor) {
	console.error(`site_tabs: pressed tabs on only ${tabbedPages} pages (floor ${floor}); refusing a vacuous pass`);
	Deno.exit(1);
}
if (failures.length > 0) {
	for (const f of failures) console.error(`site_tabs: ${f}`);
	Deno.exit(1);
}
console.log(`site_tabs: pressed every tab on ${tabbedPages} tabbed pages; each selects its own panel`);
