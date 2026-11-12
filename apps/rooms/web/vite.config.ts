import deno from "@deno/vite-plugin";
import react from "@vitejs/plugin-react";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig, type Plugin, type ProxyOptions } from "vite";

const webRoot = fileURLToPath(new URL("./ui/", import.meta.url));
const page = fileURLToPath(new URL("./ui/page.html", import.meta.url));
const entry = fileURLToPath(new URL("./ui/page.js", import.meta.url));
const groundEntry = fileURLToPath(new URL("./ui/ground.js", import.meta.url));
const applicationWasm = fileURLToPath(
	new URL("../../../zig-out/wasm/rooms/rooms_browser_bg.wasm", import.meta.url),
);
const applicationGlue = fileURLToPath(
	new URL("../../../zig-out/wasm/rooms/rooms_browser.js", import.meta.url),
);

const repository = fileURLToPath(new URL("../../../", import.meta.url));
const lockedPackages = fileURLToPath(new URL("../node_modules", import.meta.url));

/** The package directory an import from `importer` would reach before the
 * locked one, if `exists` finds any.
 *
 * An import takes its package from the nearest `node_modules` above the file
 * that imports it. The lock beside the app names every package the page
 * takes, so a package directory left nearer the sources would supply others. */
export function nearerPackages(importer: string, exists: (directory: string) => boolean): string | null {
	if (!importer.startsWith(repository) || importer.includes("/node_modules/")) return null;
	for (let above = dirname(importer); `${above}/`.startsWith(repository); above = dirname(above)) {
		const packages = join(above, "node_modules");
		if (packages === lockedPackages) return null;
		if (exists(packages)) return packages;
	}
	return null;
}

/** Refuse an import that a stray package directory would answer, in a
 * compiled bundle and under Fast Refresh alike. */
function lockedPackagesOnly(): Plugin {
	return {
		name: "rooms-locked-packages",
		enforce: "pre",
		resolveId(_source, importer) {
			const nearer = importer == null ? null : nearerPackages(importer, existsSync);
			if (nearer != null) {
				throw new Error(`${nearer} holds packages nearer the browser sources than the locked ones. Remove it.`);
			}
			return null;
		},
	};
}

export interface DevelopmentListen {
	host: string;
}

export function developmentListen(value: string | undefined): DevelopmentListen {
	const host = value?.trim() || "127.0.0.1";
	return { host };
}

/** The names, beyond an address, this dev server answers to.
 *
 * Vite checks the Host header and allows an IP literal, `localhost`, and
 * anything under it. Every other name has to be named here, so reaching the
 * server by a DNS name is refused until it is. A leading dot matches the name
 * itself and everything under it, which is how one entry covers a whole
 * tailnet: Tailscale gives each machine a name under `ts.net`, and reaching
 * the page that way, or through `tailscale serve`, sends that name in the
 * header. Addresses still work without any of this. */
export function developmentAllowedHosts(value: string | undefined): string[] {
	const named = (value ?? "").split(",").map((host) => host.trim()).filter((host) => host !== "");
	return named.length === 0 ? [".ts.net"] : named;
}

export function developmentPort(value: string | undefined): number {
	const source = value?.trim() || "8080";
	const port = Number(source);
	if (!Number.isInteger(port) || port < 1 || port > 65_535) {
		throw new Error("GLOWCAP_ROOMS_DEV_PORT must be an integer from 1 through 65535");
	}
	return port;
}

export function backendProxy(target: string | undefined): Record<string, ProxyOptions> {
	const match = target?.match(/^http:\/\/127\.0\.0\.1:(\d+)$/);
	const port = Number(match?.[1]);
	if (match == null || !Number.isInteger(port) || port < 1 || port > 65_535) {
		throw new Error("GLOWCAP_ROOMS_DEV_BACKEND must name the loopback Rooms backend");
	}
	return {
		"^/(?:ice|link-preview|llms\\.txt|locator|publish|register|relay|trace)(?:[/?]|$)": {
			target,
			ws: true,
		},
	};
}

/** wasm-bindgen gives its generated module a sibling-file fallback. Rooms
 * supplies the Wasm response explicitly, and the Rust publisher gives that
 * response its content-addressed route. Rewriting the unused fallback keeps
 * Vite from copying the nine-megabyte Wasm file into its temporary output. */
function externalApplicationWasm(): Plugin {
	return {
		name: "rooms-application-wasm",
		enforce: "pre",
		transform(source, id) {
			if (id !== applicationGlue) return null;
			const generated = "new URL('rooms_browser_bg.wasm', import.meta.url)";
			const first = source.indexOf(generated);
			if (first < 0 || source.indexOf(generated, first + generated.length) >= 0) {
				throw new Error("the generated Rooms application has an unexpected Wasm fallback");
			}
			return source.replace(
				generated,
				'new URL(document.documentElement.dataset.roomsWasm ?? "rooms_browser_bg.wasm", document.baseURI)',
			);
		},
	};
}

let lastBuild: { size: number; mtimeMs: number; name: string } | null = null;

/** The build a development page runs: the Wasm application it loads, named
 * by its SHA-256 as the published server names the same file. A rebuild that
 * changes the application changes the name, so an open page reloads into it
 * as a published page does, and one that writes the same bytes does not. */
async function developmentBuild(): Promise<string> {
	// A page with no connection asks every few seconds, so the digest is kept
	// until the file's size or modification time moves.
	const { size, mtimeMs } = await stat(applicationWasm);
	if (lastBuild?.size === size && lastBuild.mtimeMs === mtimeMs) return lastBuild.name;
	const digest = createHash("sha256").update(await readFile(applicationWasm)).digest("hex");
	lastBuild = { size, mtimeMs, name: `vite-development-${digest.slice(0, 16)}` };
	return lastBuild.name;
}

/** Adapt the Rust page contract to Vite in development. Production output
 * still passes through the Rust generation publisher. */
function roomsDevelopment(): Plugin {
	return {
		name: "rooms-development-front",
		apply: "serve",
		transformIndexHtml: {
			order: "pre",
			async handler() {
				return [{
					tag: "script",
					children: `document.documentElement.dataset.uiBuild=${
						JSON.stringify(await developmentBuild())
					};document.documentElement.dataset.roomsWasm="/rooms_browser_bg.wasm";`,
					injectTo: "head-prepend",
				}];
			},
		},
		configureServer(server) {
			server.middlewares.use((request, response, next) => {
				const pathname = new URL(request.originalUrl ?? request.url ?? "/", "http://rooms.invalid").pathname;
				if (pathname === "/ui-version") {
					developmentBuild().then((build) => {
						response.statusCode = 200;
						response.setHeader("Content-Type", "text/plain; charset=utf-8");
						response.setHeader("Cache-Control", "no-store");
						response.end(`${build}\n`);
					}, next);
					return;
				}
				if (pathname === "/rooms_browser_bg.wasm") {
					// Vite owns file streaming, content types, and conditional GET.
					request.url = `/@fs/${applicationWasm}`;
				}
				next();
			});
			return () => {
				server.middlewares.use(async (request, response, next) => {
					if (request.method !== "GET" || !request.headers.accept?.includes("text/html")) {
						next();
						return;
					}
					try {
						const source = await readFile(page, "utf8");
						// page.html's base is /, including when a room route serves it.
						const html = await server.transformIndexHtml("/", source);
						response.statusCode = 200;
						response.setHeader("Content-Type", "text/html; charset=utf-8");
						response.end(html);
					} catch (error) {
						next(error);
					}
				});
			};
		},
	};
}

export default defineConfig(({ command }) => {
	const development = command === "serve";
	return {
		root: webRoot,
		// Chunks and their preloads resolve relative to the module importing
		// them, so one build loads under whatever base path page.html names.
		base: development ? "/" : "./",
		cacheDir: fileURLToPath(new URL("../../../zig-out/cache/rooms-vite/", import.meta.url)),
		appType: "custom",
		// The web server prints the room's locators before Vite starts.
		// Keep them in the terminal across startup and configuration reloads.
		clearScreen: false,
		logLevel: development ? "info" : "warn",
		// Startup owns the Host and React root for one document lifetime. It
		// cannot be replaced as a component: a refresh would open a second Host
		// and leave the rendered controls holding the previous projection.
		plugins: [
			lockedPackagesOnly(),
			externalApplicationWasm(),
			deno(),
			react({ exclude: /\/ui\/main\.tsx$/ }),
			roomsDevelopment(),
		],
		build: {
			// Mobile Safari on iOS 26 is the oldest supported JavaScript engine.
			// Current Chrome and Firefox implement this floor or a newer one.
			target: "safari26",
			copyPublicDir: false,
			// Release notices follow packages actually present in emitted chunks.
			license: { fileName: "bundled-packages.json" },
			emptyOutDir: true,
			minify: "oxc",
			modulePreload: { polyfill: false },
			rolldownOptions: {
				input: { page: entry, ground: groundEntry },
				output: {
					format: "es",
					entryFileNames: "[name].js",
					chunkFileNames: "[name]-[hash].js",
					assetFileNames: "[name]-[hash][extname]",
				},
			},
		},
		server: development
			? {
				...developmentListen(Deno.env.get("GLOWCAP_ROOMS_DEV_HOST")),
				allowedHosts: developmentAllowedHosts(Deno.env.get("GLOWCAP_ROOMS_DEV_ALLOWED_HOSTS")),
				port: developmentPort(Deno.env.get("GLOWCAP_ROOMS_DEV_PORT")),
				strictPort: true,
				proxy: backendProxy(Deno.env.get("GLOWCAP_ROOMS_DEV_BACKEND")),
				fs: {
					allow: [
						webRoot,
						fileURLToPath(new URL("../lib/", import.meta.url)),
						fileURLToPath(new URL("../../../bindings/ts/", import.meta.url)),
						fileURLToPath(new URL("../../../zig-out/wasm/rooms/", import.meta.url)),
						fileURLToPath(new URL("../../../ui/", import.meta.url)),
					],
				},
			}
			: undefined,
	};
});
