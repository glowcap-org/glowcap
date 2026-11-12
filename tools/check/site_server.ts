// The built site served from a loopback port at the origin root, for the
// checks that open its pages in a browser (`site_render.ts`, `site_tabs.ts`).
// A request names a file under the site root or nothing: a path that resolves
// outside the root, or to no file, answers 404, and any other read failure
// answers 500 with its cause, so a broken build never reads as a missing page.

const CONTENT_TYPES: Readonly<Record<string, string>> = {
	".html": "text/html; charset=utf-8",
	".css": "text/css",
	".js": "text/javascript",
	".svg": "image/svg+xml",
	".png": "image/png",
	".woff2": "font/woff2",
	".wasm": "application/wasm",
};

export interface SiteServer {
	/** The site's origin, with no trailing slash. */
	readonly base: string;
	close(): Promise<void>;
}

/** Serve `siteRoot` on 127.0.0.1 until closed. */
export async function serveSite(siteRoot: string): Promise<SiteServer> {
	const root = await Deno.realPath(siteRoot);
	const server = Deno.serve({ hostname: "127.0.0.1", port: 0, onListen: () => {} }, async (request) => {
		let path = decodeURIComponent(new URL(request.url).pathname);
		if (path.endsWith("/")) path += "index.html";
		let file: string;
		try {
			file = await Deno.realPath(root + path);
		} catch (error) {
			if (error instanceof Deno.errors.NotFound) return new Response("not found\n", { status: 404 });
			return new Response(`unreadable: ${error}\n`, { status: 500 });
		}
		if (!file.startsWith(`${root}/`)) return new Response("not found\n", { status: 404 });
		try {
			const body = await Deno.readFile(file);
			const type = CONTENT_TYPES[file.slice(file.lastIndexOf("."))];
			return new Response(body, { headers: type == null ? {} : { "content-type": type } });
		} catch (error) {
			return new Response(`unreadable: ${error}\n`, { status: 500 });
		}
	});
	return {
		base: `http://127.0.0.1:${server.addr.port}`,
		close: () => server.shutdown(),
	};
}
