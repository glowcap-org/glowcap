// Browser-bundle stubs for the non-browser runtime adapters' host imports.
//
// `@pancake/web` injects its own runtime adapter (FFI over wasm linear memory,
// sockets over WebSocket) before `@pancake/runtime` loads, so the runtime's
// `node_net` and `bun` adapters are never selected in a browser. But a
// browser bundler may still discover them through the runtime selector's
// dynamic import. Their `node:net` / `bun:ffi` imports would then fail to
// resolve. `browser-bundle.json` maps only those two specifiers here. Native
// archive resolution has a separate compile-time browser seam and needs no
// stubs. None of these exports is callable after the web adapter is injected.

const unavailable = (): never => {
	throw new Error("pancake web: a native FFI adapter is not available in the browser");
};

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
