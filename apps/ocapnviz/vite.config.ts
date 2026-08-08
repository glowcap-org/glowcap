import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import deno from "@deno/vite-plugin";

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
export default defineConfig({
  plugins: [deno(), react()],
  server: {
    host: "127.0.0.1",
    port: 5173,
    // Vite 8 host-blocks any request whose Host header isn't listed
    // here. The Coder workspace forwards `5173--main--jimi-cuda--
    // jimi.coder.prod.netflix.net` to the local 127.0.0.1:5173 port;
    // without the allowlist entry the dev server responds with the
    // "Blocked request" page. Wildcard the coder.prod.netflix.net
    // domain so any workspace name / port-suffix combo passes.
    allowedHosts: [".coder.prod.netflix.net", "127.0.0.1", "localhost"],
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
