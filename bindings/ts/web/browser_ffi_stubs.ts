// Browser-bundle stubs for the non-browser FFI adapters' host imports.
//
// `@pancake/web` injects its own runtime adapter (FFI over wasm linear memory,
// sockets over WebSocket) before `@pancake/stack` loads, so the stack's
// `node_net` and `bun` adapters are never selected in a browser. But a
// single-file browser bundle still statically includes them (the runtime
// selector's dynamic import over `./adapters/*` is glob-expanded by the
// bundler), and their top-level `node:net` / `bun:ffi` imports would fail to
// resolve in a browser. `browser-bundle.json` maps those specifiers here so the
// bundle resolves cleanly. None of these is ever called: selecting the adapter
// that would call them cannot happen once the web adapter is injected.

const unavailable = (): never => {
	throw new Error("pancake web: a native FFI adapter is not available in the browser");
};

// Default export for `node:*` built-ins imported as a default (e.g.
// `import process from "node:process"`). The stack's archive-cascade path is
// dead in a browser (the injected adapter's `dlopen` ignores paths), so these
// are imported but never called.
export default {};

// node:net (the node/bun socket adapter, and the iroh binding's node path)
export const connect = unavailable;
export const createServer = unavailable;
export class Socket {}
export class Server {}

// bun:ffi (the bun FFI adapter)
export const dlopen = unavailable;
export const FFIType: Record<string, number> = {};
export class JSCallback {}
export const ptr = unavailable;
export const toArrayBuffer = unavailable;
