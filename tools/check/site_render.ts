/// <reference lib="dom" />
// Render every built documentation-site page at phone width and fail on what
// the source checks cannot see: a console or page error, document-level
// horizontal overflow, or a widow. The site's layout regressions have arrived
// exactly here (a grid column whose bare `1fr` meant `minmax(auto, 1fr)`, a
// tab strip that widened the page), and only a real layout engine can measure
// them.
//
// A widow is a text block whose last line holds one word when that word and
// the one before it would fit together on the line. `tools/gen/site_normalize.py`
// binds each block's last two words to prevent it, and this measures what the
// binding left. A pair wider than its column breaks anyway and is not counted,
// and neither is a run of code chips, which wraps as a row of tokens.
//
// The autodoc under reference/api/ is covered too: its viewer is Zig's, but
// what overflowed there in practice was glowcap's own module doc prose (an
// unbreakable run of slash-joined code spans), which is exactly this
// repository's to fix. A failure there wants a doc-comment fix first and an
// upstream-viewer diagnosis second.
//
// Validated against injected defects: removing the tab strip's `flex-wrap`
// (the shipped overflow bug) failed twelve pages, and a template script that
// throws failed every page on the console arm, and a 320px-only overflow (a
// long inline command span) escaped the 390px pass until 320 joined the
// measured set. Not validated against: overflow confined to widths between
// the four sampled ones.
//
// Usage: deno run --allow-all tools/check/site_render.ts <site-root>

import { chromium } from "playwright";

const siteRoot = Deno.args[0];
if (!siteRoot) {
	console.error("usage: site_render.ts <site-root>");
	Deno.exit(2);
}

// The site is built for a /glowcap/ base URL, so serve it under that prefix.
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
	if (!path.startsWith("/glowcap/")) return new Response("not found", { status: 404 });
	path = path.slice("/glowcap".length);
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

// Every rendered page is a directory holding an index.html.
const pages: string[] = [];
async function walk(dir: string, rel: string): Promise<void> {
	for await (const entry of Deno.readDir(dir)) {
		if (!entry.isDirectory && entry.name === "index.html") pages.push(`/glowcap${rel}/`);
		if (entry.isDirectory) {
			await walk(`${dir}/${entry.name}`, `${rel}/${entry.name}`);
		}
	}
}
await walk(siteRoot, "");
pages.sort();
if (pages.length < 20) {
	console.error(
		`site_render: found only ${pages.length} pages under ${siteRoot}; a real site build has more, refusing a vacuous pass`,
	);
	Deno.exit(1);
}

// Runs in the page. Returns the text of each block whose last line holds one
// word that could have shared the line with the word before it.
function findWidows(): string[] {
	const blocks = "p, li, dd, dt, figcaption, blockquote, caption, h1, h2, h3, h4, h5, h6, td, th";
	const found: string[] = [];
	for (const block of Array.from(document.querySelectorAll<HTMLElement>(blocks))) {
		if (block.closest("pre, nav")) continue;
		const words: { rect: DOMRect; width: number; code: boolean }[] = [];
		const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
		for (let node = walker.nextNode(); node; node = walker.nextNode()) {
			const parent = node.parentElement;
			if (parent == null || parent.closest(blocks) !== block) continue;
			const text = node.textContent ?? "";
			for (const match of text.matchAll(/\S+/g)) {
				const range = document.createRange();
				range.setStart(node, match.index);
				range.setEnd(node, match.index + match[0].length);
				const rects = range.getClientRects();
				const rect = rects[rects.length - 1];
				if (rect == null || rect.width === 0) continue;
				// A word hyphenated across lines sits on the last line it reaches,
				// but needs its whole width to move.
				const width = Array.from(rects).reduce((sum, part) => sum + part.width, 0);
				words.push({ rect, width, code: parent.closest("code, kbd, samp") != null });
			}
		}
		const cell = block.tagName === "TD" || block.tagName === "TH";
		if (words.length < (cell ? 3 : 2) || words.every((word) => word.code)) continue;
		const lineHeight = Math.min(...words.map((word) => word.rect.height));
		const bottom = Math.max(...words.map((word) => word.rect.bottom));
		const lastLine = words.filter((word) => word.rect.bottom > bottom - lineHeight / 2);
		if (lastLine.length !== 1 || lastLine.length === words.length) continue;
		const last = lastLine[0];
		const before = words[words.length - 2];
		const style = getComputedStyle(block);
		const column = block.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
		const space = parseFloat(style.fontSize) * 0.3;
		if (before.width + space + last.width <= column) {
			found.push((block.textContent ?? "").replace(/\s+/g, " ").trim().slice(-60));
		}
	}
	return found;
}

// Four sample widths spanning the fluid layout's range: 390 the common
// phone, 320 the narrowest still in use (each has caught an overflow the
// other missed), 768 a tablet, 1600 a wide desktop. Console and page errors
// are width-independent, so only the first width collects them.
const widths = [390, 320, 768, 1600];
const browser = await chromium.launch();
const failures: string[] = [];
for (const [i, width] of widths.entries()) {
	const page = await browser.newPage({ viewport: { width, height: 844 } });
	for (const p of pages) {
		const errors: string[] = [];
		const onConsole = (m: { type(): string; text(): string }) => {
			if (m.type() === "error") errors.push(m.text());
		};
		const onPageError = (e: unknown) => errors.push(String(e));
		if (i === 0) {
			page.on("console", onConsole);
			page.on("pageerror", onPageError);
		}
		try {
			await page.goto(base + p, { waitUntil: "networkidle", timeout: 20_000 });
			const overflow = await page.evaluate(() =>
				document.documentElement.scrollWidth - document.documentElement.clientWidth
			);
			if (overflow > 0) failures.push(`${p}: ${overflow}px of horizontal overflow at ${width}px width`);
			if (!p.includes("/reference/api/")) {
				for (const widow of await page.evaluate(findWidows)) {
					failures.push(`${p}: widow at ${width}px width: "${widow}"`);
				}
			}
		} catch (e) {
			failures.push(`${p}: ${e}`);
		}
		if (i === 0) {
			page.off("console", onConsole);
			page.off("pageerror", onPageError);
			for (const e of errors) failures.push(`${p}: console: ${e}`);
		}
	}
	await page.close();
}
await browser.close();
await server.shutdown();

if (failures.length > 0) {
	for (const f of failures) console.error(`site_render: ${f}`);
	Deno.exit(1);
}
console.log(`site_render: ${pages.length} pages render clean at ${widths.join("px, ")}px`);
