#!/usr/bin/env -S deno run -A
/** The process owner behind `zig build rooms-web-static`.
 *
 * Exports the prepared generation with `rooms-web --export-static` into a new
 * temporary directory and serves it the way GitHub Pages serves a project
 * site: a file, a directory's `index.html`, or else the export's `404.html`
 * with status 404. Nothing outside the base path is served. The export is
 * removed when the host stops.
 *
 * The page it serves has no Rooms server behind it, which is the point: it is
 * the page `glowcap.org/rooms/app/` serves, run locally. */
import { extname, join, normalize, sep as SEPARATOR } from "node:path";

export interface StaticLaunch {
	web: string;
	assets: string;
	base: string;
	port: number;
}

const usage = "rooms-web-static takes [--base=/<path>/] [--port=<port>]";

export function parseStaticLaunch(args: string[]): StaticLaunch {
	const [web, assets, ...options] = args;
	if (web == null || web.trim() === "" || assets == null || assets.trim() === "") {
		throw new Error("rooms-web-static needs the rooms-web executable and the prepared generation");
	}
	let base = "/rooms/app/";
	let port = 5173;
	for (const option of options) {
		const [name, value] = option.split(/=(.*)/s, 2);
		if (name === "--base" && value != null && /^\/(?:[^?#]*\/)?$/.test(value)) base = value;
		else if (
			name === "--port" && value != null && /^\d+$/.test(value) && Number(value) >= 1 && Number(value) <= 65_535
		) {
			port = Number(value);
		} else throw new Error(`${usage}, not ${option}`);
	}
	return { web, assets, base, port };
}

/** The file under `root` a request path names, or null when the path is
 * outside `base` or climbs out of `root`. */
export function exportedPath(root: string, base: string, pathname: string): string | null {
	if (!pathname.startsWith(base)) return null;
	let rest: string;
	try {
		rest = decodeURIComponent(pathname.slice(base.length));
	} catch {
		return null;
	}
	const path = normalize(join(root, rest));
	return path === root || path.startsWith(root + SEPARATOR) ? path : null;
}

/** Where a request for the base without its trailing slash moves to, as
 * GitHub Pages moves a directory's address, or null for any other request. */
export function slashRedirect(base: string, url: URL): string | null {
	if (base === "/" || url.pathname !== base.slice(0, -1)) return null;
	return new URL(base + url.search + url.hash, url).href;
}

const types: Record<string, string> = {
	".html": "text/html; charset=utf-8",
	".js": "text/javascript; charset=utf-8",
	".css": "text/css; charset=utf-8",
	".wasm": "application/wasm",
	".woff2": "font/woff2",
	".json": "application/json",
	".svg": "image/svg+xml",
	".png": "image/png",
	".txt": "text/plain; charset=utf-8",
};

async function readFile(path: string): Promise<{ body: Uint8Array<ArrayBuffer>; type: string } | null> {
	let info: Deno.FileInfo;
	try {
		info = await Deno.stat(path);
	} catch (error) {
		if (error instanceof Deno.errors.NotFound || error instanceof Deno.errors.NotADirectory) return null;
		throw error;
	}
	if (info.isDirectory) return readFile(join(path, "index.html"));
	if (!info.isFile) return null;
	return {
		body: new Uint8Array(await Deno.readFile(path)),
		type: types[extname(path)] ?? "application/octet-stream",
	};
}

async function exportSite(launch: StaticLaunch, site: string): Promise<void> {
	const exported = await new Deno.Command(launch.web, {
		args: [`--export-static=${site}`, `--assets=${launch.assets}`, `--base=${launch.base}`],
		stdout: "inherit",
		stderr: "inherit",
	}).output();
	if (!exported.success) throw new Error(`rooms-web --export-static exited with status ${exported.code}`);
}

async function main(): Promise<void> {
	const launch = parseStaticLaunch(Deno.args);
	const scratch = await Deno.makeTempDir({ prefix: "rooms-static-" });
	const remove = () => Deno.removeSync(scratch, { recursive: true });
	try {
		// The export refuses a directory that exists, so it writes a new one
		// inside the temporary directory this host owns.
		const site = join(scratch, "site");
		await exportSite(launch, site);
		const missing = await Deno.readFile(join(site, "404.html"));
		const hostname = Deno.env.get("GLOWCAP_ROOMS_DEV_HOST")?.trim() || "127.0.0.1";
		const server = Deno.serve({
			hostname,
			port: launch.port,
			onListen: () => console.log(`\n  static page      http://localhost:${launch.port}${launch.base}\n`),
		}, async (request) => {
			const url = new URL(request.url);
			const moved = slashRedirect(launch.base, url);
			if (moved != null) return Response.redirect(moved, 301);
			const path = exportedPath(site, launch.base, url.pathname);
			const found = path == null ? null : await readFile(path);
			if (found != null) return new Response(found.body, { headers: { "content-type": found.type } });
			if (path == null) return new Response("not found", { status: 404 });
			return new Response(missing, { status: 404, headers: { "content-type": types[".html"] } });
		});
		for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
			Deno.addSignalListener(signal, () => void server.shutdown());
		}
		await server.finished;
	} finally {
		remove();
	}
}

if (import.meta.main) await main();
