import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import deno from "@deno/vite-plugin";
import { devListen } from "./vite-dev-listen.ts";

// Deno runs Vite via `npm:vite` (see `deno.json` tasks).
// `@deno/vite-plugin` teaches Vite to use Deno's resolver for bare
// imports, so import-map entries in `deno.json` work without a
// materialized `node_modules/` (still produced opportunistically for
// Vite-internal cache use).
//
// PixiJS is bundled, not externalized to a CDN. We tried CDN
// externalization once; it crashed at runtime because esbuild's
// dep-optimization pass for `pixi-viewport` doesn't run Vite plugins,
// so `pixi-viewport`'s internal `import "pixi.js"` ended up bundling
// a second copy of PixiJS — Container instances from one copy lack
// the v8 mixin methods attached to the other copy's prototype, and
// the renderer crashes with `s[n].collectRenderables is not a
// function`. Bundling everything keeps the one-Container-prototype
// invariant the v8 mixin pattern requires.
//
// `optimizeDeps.include` pre-bundles the heavy deps at server start;
// combined with `server.warmup`, the dev server boots hot.
const glowcapHostWasm = new URL(
	"../../zig-out/wasm/glowcap_host.wasm",
	import.meta.url,
);

/** Add the canonical wasm Host without replacing Vite's `public/` directory.
 * Development serves the build artifact directly; production emits the same
 * bytes as a root asset beside the public font, favicon, and service worker. */
function glowcapHostWasmPlugin(): Plugin {
	return {
		name: "glowcap-host-wasm",
		configureServer(server) {
			server.middlewares.use(async (req, res, next) => {
				if (
					new URL(req.originalUrl ?? "/", "http://localhost")
						.pathname !==
						"/glowcap_host.wasm"
				) {
					next();
					return;
				}
				try {
					const bytes = await Deno.readFile(glowcapHostWasm);
					res.statusCode = 200;
					res.setHeader("Content-Type", "application/wasm");
					res.setHeader("Content-Length", String(bytes.byteLength));
					res.end(bytes);
				} catch (error) {
					next(error);
				}
			});
		},
		async generateBundle() {
			this.emitFile({
				type: "asset",
				fileName: "glowcap_host.wasm",
				source: await Deno.readFile(glowcapHostWasm),
			});
		},
	};
}

export default defineConfig({
	plugins: [glowcapHostWasmPlugin(), deno(), react()],
	resolve: {
		alias: {
			"virtual:glowcap-web": new URL(
				"../../bindings/ts/web/mod.ts",
				import.meta.url,
			).pathname,
		},
	},
	server: {
		...devListen(Deno.env.get("OCAPNVIZ_HOST")),
		port: 5173,
		warmup: {
			clientFiles: [
				"./src/main.tsx",
				"./src/App.tsx",
				"./src/render/Stage.tsx",
				"./src/engine/engine.ts",
			],
		},
		// Vite restarts itself when `vite.config.ts` changes, but in our
		// `pixi → deno task → deno run` chain that restart loses the
		// signal-forwarding parent and wedges the terminal — Ctrl-C
		// reaches the wrappers, they exit, the new vite child becomes an
		// orphan no signal can reach. Excluding the config file from the
		// file-system watcher disables the auto-restart; edits to
		// vite.config.ts require a manual `pixi run dev` restart, which
		// is rare. Source-file HMR is unaffected.
		// `.deno/` is the per-subtree npm cache — ignoring it keeps HMR
		// quiet when ad-hoc Deno scripts (e.g. the playwright harness)
		// materialize npm tarballs into it.
		watch: {
			ignored: [
				"**/vite.config.*",
				"**/deno.json",
				"**/deno.lock",
				"**/.deno/**",
			],
		},
	},
	optimizeDeps: {
		include: [
			"pixi.js",
			"pixi-viewport",
			"miniplex",
			"d3-force",
			"react",
			"react-dom/client",
			"react/jsx-runtime",
			"zod",
		],
	},
});
