/// <reference lib="dom" />
// Render every built documentation-site page at phone width and fail on what
// the source checks cannot see: a console or page error, or document-level
// horizontal overflow. The site's layout regressions have arrived exactly
// here (a grid column whose bare `1fr` meant `minmax(auto, 1fr)`, a tab strip
// that widened the page), and only a real layout engine can measure them.
//
// The autodoc under reference/api/ is covered too: its viewer is Zig's, but
// what overflowed there in practice was pancake's own module doc prose (an
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

// The site is built for a /pancake/ base URL, so serve it under that prefix.
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

// Every rendered page is a directory holding an index.html.
const pages: string[] = [];
async function walk(dir: string, rel: string): Promise<void> {
	for await (const entry of Deno.readDir(dir)) {
		if (!entry.isDirectory && entry.name === "index.html") pages.push(`/pancake${rel}/`);
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
