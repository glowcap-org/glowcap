import deno from "@deno/vite-plugin";
import react from "@vitejs/plugin-react";
import { readFile } from "node:fs/promises";
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
				'new URL(document.documentElement.dataset.roomsWasm ?? "/rooms_browser_bg.wasm", location.href)',
			);
		},
	};
}

/** Adapt the Rust page contract to Vite in development. Production output
 * still passes through the Rust generation publisher. */
function roomsDevelopment(): Plugin {
	return {
		name: "rooms-development-front",
		apply: "serve",
		transformIndexHtml: {
			order: "pre",
			handler() {
				return [{
					tag: "script",
					children:
						'document.documentElement.dataset.uiBuild="vite-development";document.documentElement.dataset.roomsWasm="/rooms_browser_bg.wasm";',
					injectTo: "head-prepend",
				}];
			},
		},
		configureServer(server) {
			server.middlewares.use((request, response, next) => {
				const pathname = new URL(request.originalUrl ?? request.url ?? "/", "http://rooms.invalid").pathname;
				if (pathname === "/ui-version") {
					response.statusCode = 200;
					response.setHeader("Content-Type", "text/plain; charset=utf-8");
					response.setHeader("Cache-Control", "no-store");
					response.end("vite-development\n");
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
						const html = await server.transformIndexHtml(request.originalUrl ?? request.url ?? "/", source);
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
		cacheDir: fileURLToPath(new URL("../../../zig-out/cache/rooms-vite/", import.meta.url)),
		appType: "custom",
		// The web server prints the room's locators before Vite starts.
		// Keep them in the terminal across startup and configuration reloads.
		clearScreen: false,
		logLevel: development ? "info" : "warn",
		// Startup owns the Host and React root for one document lifetime. It
		// cannot be replaced as a component: a refresh would open a second Host
		// and leave the rendered controls holding the previous projection.
		plugins: [externalApplicationWasm(), deno(), react({ exclude: /\/ui\/main\.tsx$/ }), roomsDevelopment()],
		build: {
			// Mobile Safari on iOS 26 is the oldest supported JavaScript engine.
			// Current Chrome and Firefox implement this floor or a newer one.
			target: "safari26",
			copyPublicDir: false,
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
						fileURLToPath(new URL("../../../ui/fonts/", import.meta.url)),
					],
				},
			}
			: undefined,
	};
});
