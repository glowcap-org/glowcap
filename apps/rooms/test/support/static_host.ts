// The published page as a static host serves it: `rooms-web --export-static`
// written once per call, then served as plain files from a loopback port.
// The browser sees a real origin with no Rooms server behind it, which a
// routed document cannot give: Chrome's local network check treats a
// fulfilled document as public and blocks its sockets to loopback.
import { ROOT, WEB } from "./paths.ts";

/** The content types the front serves, so the static host says the same. */
const CONTENT_TYPES: Readonly<Record<string, string>> = {
	css: "text/css; charset=utf-8",
	html: "text/html; charset=utf-8",
	js: "text/javascript; charset=utf-8",
	json: "application/json",
	txt: "text/plain; charset=utf-8",
	wasm: "application/wasm",
	woff2: "font/woff2",
};

export interface StaticHost {
	/** The page's origin, with no trailing slash. */
	readonly origin: string;
	close(): Promise<void>;
}

/** Export the prepared generation and serve it until closed. */
export async function serveStaticExport(): Promise<StaticHost> {
	const root = await Deno.makeTempDir({ prefix: "rooms-static-" });
	const output = await Deno.makeTempDir({ dir: root });
	const assets = Deno.realPathSync(`${ROOT}zig-out/rooms-web/current`);
	const exported = await new Deno.Command(WEB, {
		args: [`--export-static=${output}/page`, `--assets=${assets}`],
		cwd: ROOT,
		stdout: "null",
		stderr: "piped",
	}).output();
	if (!exported.success) {
		throw new Error(`rooms-web --export-static failed: ${new TextDecoder().decode(exported.stderr)}`);
	}
	const page = `${output}/page`;
	const index = await Deno.readFile(`${page}/index.html`);
	const server = Deno.serve({ hostname: "127.0.0.1", port: 0, onListen() {} }, async (request) => {
		const path = decodeURIComponent(new URL(request.url).pathname);
		const found = await Deno.realPath(`${page}${path}`).catch(() => null);
		const file = found != null && found.startsWith(`${page}/`) && (await Deno.stat(found)).isFile ? found : null;
		if (file == null) {
			// A route with no file behind it is answered by the one page. A file the
			// export wrote is served as itself, `ui-version` included: answering that
			// with the page tells the page another build is being served, and it
			// reloads out from under whatever it was doing.
			if (!/\.[a-z0-9]+$/i.test(path)) {
				return new Response(index, { headers: { "content-type": CONTENT_TYPES.html } });
			}
			return new Response("not here\n", { status: 404 });
		}
		const name = file.slice(file.lastIndexOf("/") + 1);
		const type = name.includes(".") ? CONTENT_TYPES[name.slice(name.lastIndexOf(".") + 1)] : CONTENT_TYPES.txt;
		if (type == null) return new Response("not served\n", { status: 404 });
		return new Response(await Deno.readFile(file), { headers: { "content-type": type } });
	});
	return {
		origin: `http://127.0.0.1:${server.addr.port}`,
		async close() {
			await server.shutdown();
			await Deno.remove(root, { recursive: true });
		},
	};
}
