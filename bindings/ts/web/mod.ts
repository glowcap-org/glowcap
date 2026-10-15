// @glowcap/web: the browser entry for the glowcap runtime (ADR-0070).
//
// A browser tab becomes a real OCapN peer: the same sans-io protocol core the
// FFI archives link, compiled to wasm32 (`zig build wasm-driver` →
// `glowcap_host.wasm`), with the byte channel on a WebSocket. The proof
// (`zig build web-peer-test`) covers the keyed handshake, fetch and call, and
// a host call back into a wasm-hosted object. `init` instantiates the module,
// builds the runtime adapter over it (FFI over linear memory, sockets over
// WebSocket, struct layout from the module's own descriptor), installs the
// adapter, and only then loads `@glowcap/runtime`, so the same `Session` /
// `Server` / `connect` surface every dlopen runtime uses runs unchanged on
// top of it.
//
//   import { init } from "@glowcap/web";
//   const runtime = await init({ wasm: await fetch("/glowcap_host.wasm") });
//   const session = await runtime.connect(locator);
//
// The one seam a page may need to shape is `wsUrl`: how a dial's host:port
// maps onto the WebSocket URL that carries its bytes (dial the peer directly
// by default, or point every dial at a byte gateway).

import { makeWebAdapter, type WsUrl } from "./adapter.ts";
import { IROH_RELAY_DIAL_ALLOWANCE_MS } from "./relay_budget.ts";
import { INVALID_ARGUMENT, TRANSPORT_ONION } from "@glowcap/abi";
import type {
	CaptpVersion,
	Codec,
	Connector,
	ConnectorRequest,
	FeatureSet,
	Host,
	HostProfile,
	Locator,
	Runtime,
} from "@glowcap/runtime";

/** What `init` accepts as the wasm module source. */
export type WasmSource =
	| WebAssembly.Module
	| BufferSource
	| Response
	| Promise<Response>;

export interface WebRuntimeOptions {
	/** Core-authored coherent codec/version pair. */
	profile?: HostProfile;
	/** Wire codec for this managed Runtime. */
	codec?: Codec;
	/** CapTP profile for this managed Runtime. */
	captpVersion?: CaptpVersion;
	/** Feature offer for this managed Runtime. */
	features?: FeatureSet;
	/** Durable identity seed for this managed Runtime. */
	seed?: Uint8Array;
	/** Additional browser-owned byte connectors. */
	connectors?: readonly Connector[];
	/** Runtime-wide OCapN handshake budget. */
	handshakeTimeoutMs?: number | null;
}

export interface WebInitOptions extends WebRuntimeOptions {
	/** The `glowcap_host.wasm` module: compiled module, raw bytes, or a
	 * `fetch` response (streamed when the host supports it). */
	wasm: WasmSource;
	/** Map a dial's host:port to its WebSocket URL; defaults to
	 * `ws://host:port/` (the peer itself accepts WebSocket). */
	wsUrl?: WsUrl;
	/** Map an `ocapn://` locator (an FFI-only transport such as iroh) to the
	 * WebSocket URL of a byte relay that dials it, e.g.
	 * `` (loc) => `wss://example/relay?locator=${encodeURIComponent(loc)}` ``.
	 * Without it, dialing an FFI-only locator refuses. Cold-dialing a
	 * `keyed-relay` peer is not configured here: its locator carries the relay
	 * route in its `rendezvous-relay` hint, which the `@glowcap/relay`
	 * connector follows (ADR-0088). */
	relayUrl?: (locator: string) => string;
}

type RuntimeModule = typeof import("@glowcap/runtime");

/** The runtime vocabulary plus the browser's managed default Runtime. */
export type WebRuntime = RuntimeModule & {
	readonly runtime: Runtime;
	readonly host: Runtime["host"];
	connect: Runtime["connect"];
	close(): Promise<void>;
	openRuntime(options?: WebRuntimeOptions): Promise<Runtime>;
};

// The same registry key `internal/ffi/runtime.ts` consults before probing for
// a runtime; `Symbol.for` pairs the two without importing the runtime early
// (importing it would run its adapter selection before ours is installed).
const injected_adapter_key = Symbol.for("glowcap.runtime.adapter");

export type { WsUrl } from "./adapter.ts";
export { IROH_RELAY_DIAL_ALLOWANCE_MS } from "./relay_budget.ts";
// The WebSocket byte channel and the rendezvous accept half are runtime-neutral
// runtime surface (ADR-0088); re-exported here so a page keeps one import. The
// redeeming (dialing) side follows the locator's `rendezvous-relay` hint
// through the `@glowcap/relay` connector, so one mechanism carries every cold
// dial.
export { openWebSocketChannel, type RendezvousHandle, serveRendezvous, webSocketChannel } from "@glowcap/runtime";

let loaded: Promise<WebRuntime> | null = null;
let loadedOptions: WebInitOptions | null = null;

/** The configured relay mapping for FFI-only locators, read by the browser
 * dial path for FFI-only transports (`browser_iroh_stub.ts`). Null before `init` or
 * when the page configured none. */
export function _relayUrl(): ((locator: string) => string) | null {
	return loadedOptions?.relayUrl ?? null;
}

/** Instantiate the wasm peer and load the glowcap runtime over it. One
 * configuration per page: the runtime binds its adapter at load, so a repeat
 * call with the same options object returns the first load, a repeat with a
 * different one throws, and a failed load clears the slot so a corrected
 * retry can succeed. */
export function init(options: WebInitOptions): Promise<WebRuntime> {
	if (loaded !== null) {
		if (loadedOptions !== options) {
			throw new Error(
				"glowcap web: init was already called with a different configuration",
			);
		}
		return loaded;
	}
	loadedOptions = options;
	loaded = initFresh(options);
	loaded.catch(() => {
		loaded = null;
		loadedOptions = null;
	});
	return loaded;
}

async function initFresh(options: WebInitOptions): Promise<WebRuntime> {
	const registry = globalThis as Record<symbol, unknown>;
	if (registry[injected_adapter_key] !== undefined) {
		throw new Error("glowcap web: a runtime adapter is already installed");
	}

	// The module imports the two hosted-object callback shapes: behavior dispatch
	// and FFI actor retirement. The adapter fills these late-bound slots when
	// the runtime registers its shared trampolines.
	let behaviorTrampoline:
		| ((...args: number[]) => number)
		| null = null;
	let hostedFreeTrampoline: ((ctx: number) => void) | null = null;
	const imports: WebAssembly.Imports = {
		env: {
			glowcap_behavior_trampoline: (...args: number[]): number =>
				behaviorTrampoline === null ? INVALID_ARGUMENT : behaviorTrampoline(...args),
			glowcap_hosted_free_trampoline: (ctx: number): void => hostedFreeTrampoline?.(ctx),
		},
	};

	const instance = await instantiate(options.wasm, imports);
	// The wasm runtime types `exports` as an untyped record, and the module's own
	// ABI (checked against the struct layout below) is the real shape.
	const exports = instance.exports as unknown as Parameters<typeof makeWebAdapter>[0];

	// Read the module's self-described wasm32 struct layout (probe the word
	// count, then fill).
	const count = exports.glowcap_wasm_abi_layout(0, 0) >>> 0;
	const byteLen = count * 4;
	const ptr = exports.glowcap_wasm_alloc(byteLen) >>> 0;
	if (ptr === 0) throw new Error("glowcap web: descriptor allocation failed");
	let words: Uint32Array;
	try {
		if ((exports.glowcap_wasm_abi_layout(ptr, count) >>> 0) !== count) {
			throw new Error("glowcap web: layout descriptor returned a short blob");
		}
		words = new Uint32Array(exports.memory.buffer.slice(ptr, ptr + byteLen));
	} finally {
		exports.glowcap_wasm_free(ptr, byteLen);
	}

	const web = makeWebAdapter(exports, words, { wsUrl: options.wsUrl });
	// Route the module's trampoline import through the adapter: it converts
	// the raw i32s to the runtime's bigint vocabulary and forwards to whatever
	// callback the runtime registered through `makeCallback`.
	behaviorTrampoline = (ctx, turn, verbPtr, verbLen, argsPtr, argsLen, outReply) =>
		web.behaviorTrampolineImport(ctx, turn, verbPtr, verbLen, argsPtr, argsLen, outReply);
	hostedFreeTrampoline = (ctx) => web.hostedFreeTrampolineImport(ctx);

	registry[injected_adapter_key] = web.adapter;
	try {
		const runtimeApi = await import("@glowcap/runtime");
		const openRuntime = async (runtimeOptions: WebRuntimeOptions = {}): Promise<Runtime> => {
			return await runtimeApi.Runtime.open({
				connectors: [
					...browserConnectors(runtimeApi, options),
					...(runtimeOptions.connectors ?? []),
				],
				profile: runtimeOptions.profile,
				codec: runtimeOptions.codec,
				captpVersion: runtimeOptions.captpVersion,
				features: runtimeOptions.features,
				seed: runtimeOptions.seed,
				handshakeTimeoutMs: runtimeOptions.handshakeTimeoutMs,
			});
		};
		const runtime = await openRuntime({
			profile: options.profile,
			codec: options.codec,
			captpVersion: options.captpVersion,
			features: options.features,
			seed: options.seed,
			handshakeTimeoutMs: options.handshakeTimeoutMs,
			connectors: options.connectors,
		});
		return Object.assign({}, runtimeApi, {
			runtime,
			host: runtime.host,
			connect: runtime.connect.bind(runtime),
			close: runtime.close.bind(runtime),
			openRuntime,
		});
	} catch (error) {
		// A failed load must not squat the page's one adapter slot: left
		// registered, the next attempt is refused as "already installed" and
		// the failure that matters (a stale wasm's archive
		// fingerprint, a refused Host) is never seen again. Only this
		// attempt's own registration is withdrawn; a committed adapter
		// belongs to the runtime and stays.
		if (registry[injected_adapter_key] === web.adapter) {
			delete registry[injected_adapter_key];
		}
		throw error;
	}
}

function browserConnectors(
	runtimeApi: RuntimeModule,
	options: WebInitOptions,
): Connector[] {
	const wsUrl = options.wsUrl ?? ((host: string, port: number) => `ws://${host}:${port}/`);
	const establish = async (
		host: Host,
		locator: Locator,
		request: ConnectorRequest,
		url: string,
		verifiedChannelKey: string | null = null,
		handshakeAllowanceMs = 0,
	) => {
		const channel = await runtimeApi.openWebSocketChannel(url, undefined, request.signal);
		try {
			return await runtimeApi.abortable(
				runtimeApi.Session.establishDialedLocator(
					host,
					locator,
					channel,
					request.handshakeTimeoutMs
						? request.handshakeTimeoutMs + handshakeAllowanceMs
						: request.handshakeTimeoutMs,
					verifiedChannelKey,
				),
				request.signal,
				(error) => host.recordCallerlessBindingFailure("web.session.cancel.cleanup", error),
				(session) => session.closeTransport(),
			);
		} catch (error) {
			throw await runtimeApi.retainCleanupFailures(error, [() => channel.close()]);
		}
	};
	const tcp = new runtimeApi.Connector(
		[runtimeApi.TRANSPORT_TCP, runtimeApi.TRANSPORT_KEYED_TCP],
		async (host, locator, request) => {
			const address = locator.transport === runtimeApi.TRANSPORT_TCP
				? locator.designator
				: runtimeApi.stringHint(locator, runtimeApi.HINT_DIRECT_ADDRESSES);
			if (address == null) {
				throw new runtimeApi.GlowcapError(
					INVALID_ARGUMENT,
					`${locator.transport} requires a direct-addresses hint`,
				);
			}
			const { hostname, port } = runtimeApi.designatorHostPort(address);
			return await establish(host, locator, request, wsUrl(hostname, port));
		},
	);
	const connectors = [tcp];
	if (options.relayUrl != null) {
		const viaRelay =
			(verifiedChannelKey: (locator: Locator) => string | null, handshakeAllowanceMs = 0) =>
			async (host: Host, locator: Locator, request: ConnectorRequest) =>
				await establish(
					host,
					locator,
					request,
					options.relayUrl!(runtimeApi.formatLocatorUri(locator)),
					verifiedChannelKey(locator),
					handshakeAllowanceMs,
				);
		connectors.push(
			// The relay dials iroh itself and its QUIC handshake proves the node
			// id, so the designator is the channel's verified key.
			new runtimeApi.Connector(
				[runtimeApi.TRANSPORT_IROH],
				viaRelay(
					(locator) => locator.designator,
					// The relay may spend the runtime's dial retry budget before
					// forwarding the first handshake byte to this browser.
					IROH_RELAY_DIAL_ALLOWANCE_MS,
				),
			),
			// An onion service id is an address, not an identity (ADR-0108), so
			// the relayed channel proves no key and the session reports what the
			// partner claims about itself.
			new runtimeApi.Connector([TRANSPORT_ONION], viaRelay(() => null)),
		);
	}
	return connectors;
}

async function instantiate(
	source: WasmSource,
	imports: WebAssembly.Imports,
): Promise<WebAssembly.Instance> {
	const resolved = await source;
	if (resolved instanceof WebAssembly.Module) {
		return new WebAssembly.Instance(resolved, imports);
	}
	if (typeof Response !== "undefined" && resolved instanceof Response) {
		if (typeof WebAssembly.instantiateStreaming === "function") {
			return (await WebAssembly.instantiateStreaming(resolved, imports)).instance;
		}
		const bytes = await resolved.arrayBuffer();
		return (await WebAssembly.instantiate(bytes, imports)).instance;
	}
	return (await WebAssembly.instantiate(resolved as BufferSource, imports)).instance;
}
