// Idiomatic JavaScript/TypeScript API for glowcap: a full OCapN/CapTP host
// over the symbol-disjoint `libglowcap_host` and `libglowcap_driver`
// archives (ADR-0112), with `libglowcap_ocapn` owning their shared value and
// locator vocabulary (ADR-0059). Host owns `glowcap_host_*`; driver exports
// only `glowcap_driver_*` and adopts a quiescent Host. One module
// runs on Deno and Bun; the runtime-specific FFI and sockets are isolated
// behind `./internal/ffi/runtime.ts`.
//
// The library owns every CapTP decision: routing, three-party redemption,
// gift origination, far vows. On Deno a provider-backed `Runtime.connect` rides a
// stepping driver loop (`./driver_loop.ts`) that owns the socket and the
// pumping; for explicit embedder-supplied channels the binding moves transport
// packets itself: each `Session`'s serve loop feeds the Host transport seam
// and honors the host's action queue (dial, flush, entropy,
// settle). A transport
// that links its own glowcap archive lives in its own module beside this one:
// `@glowcap/tcp`, `@glowcap/inproc`, `@glowcap/onion`, and the optional
// `@glowcap/iroh` package, as a C consumer links archives à la carte.
//
// The implementation is split by responsibility into sibling modules; this
// file is the barrel that re-exports the public surface, so `@glowcap/runtime`'s
// import path is one place. The layers: `errors` (the `GlowcapError` family),
// `value` (the value vocabulary plus the `Ref`/`Argument` application layer),
// `codec`/`context` (marshalling and allocation scopes), `trampoline` (the one
// FFI behavior callback), `host` (the `Host`), `action` (host-action
// decode+execute), `promise` (the `RemotePromise` send returns), `gc`
// (ADR-0063), `runtime` (Host + transport composition), `dial` (the internal
// connector executor), `session` (the `Session` verbs and mint/handshake),
// `pump` (the packet-fed embedder serve/feed/flush
// choreography), and `locator` (OCapN URIs).
//
//   await using runtime = await Runtime.open({ providers: [tcp.provider()] });
//   await using session = await runtime.connect(tcp.locator("127.0.0.1", 9099));
//   session.serve().catch(() => {});
//   const greeter = await session.fetch("greeter");
//   const reply = await session.send(greeter, "greet", ["world"]);

import { ocapnS as s } from "./internal/ffi/ocapn.ts";

export {
	FetchFailed,
	GlowcapError,
	PublicationNotFound,
	retainCleanupFailures,
	retainSecondaryFailure,
	secondaryFailureCount,
	secondaryFailures,
	VowBroken,
} from "./errors.ts";
export type { CarrierFailure, CarrierPhase } from "./carrier_failure.ts";
export {
	type Argument,
	type Behavior,
	type CaptpVersion,
	type Codec,
	FEATURE_BASELINE,
	FEATURE_FULL,
	FEATURE_HANDOFF,
	FEATURE_MINIMUM,
	FEATURE_MULTI_LOCATION,
	FEATURE_PIPELINING,
	FEATURE_STURDYREF,
	FEATURE_UNTAG,
	FEATURE_WIRE_DELTA,
	type FeatureSet,
	Kw,
	PSet,
	PStruct,
	Reachability,
	Ref,
	type SessionProfile,
	Sym,
	Tagged,
	tagged,
} from "./value.ts";
export {
	Context,
	type ContextAllocator,
	type FailureEvent,
	type FailureLayer,
	type FailureScope,
	takeRuntimeFailures,
} from "./context.ts";
export {
	DURABLE_SWISS_ENTROPY_BYTES,
	Host,
	type HostOptions,
	type HostProfile,
	type SessionLimitOptions,
} from "./host.ts";
export { type CloseOptions } from "./lifecycle.ts";
export { RemotePromise } from "./promise.ts";
export { SignalingSendOwner } from "./signaling.ts";
// The live timeline producer (opt-in): a sink over the versioned timeline
// schema ocapnviz's Live mode consumes, fed by this Host's own session opens,
// closes, and message traffic. The rooms server serves it at `/trace`.
export {
	annotateSession,
	CAPTP_VERSION_WIRE,
	enableTrace,
	type TraceCaptpVersion,
	type TraceCodec,
	type TraceEvent,
	type TraceSink,
} from "./trace.ts";
// The handshake bound is applied inside `Session`'s establish spine, which
// every dial and every accept path reaches; the constant is exported so a
// caller choosing its own budget can say how it relates to the default.
export {
	type AcceptedTransport,
	type Channel,
	currentSession,
	durableIdentityAuthenticated,
	type DurableProvenance,
	HANDSHAKE_TIMEOUT_MS,
	type PartnerIdentity,
	type SendRedeemingResult,
	Session,
} from "./session.ts";
export { type ConnectOptions, Runtime, type RuntimeOptions } from "./runtime.ts";
export {
	abortable,
	Connector,
	type ConnectorRequest,
	type DriverProvider,
	type TransportOperationOptions,
} from "./transport.ts";
// The WebSocket byte channel and the cold-dial rendezvous accept half
// (ADR-0088). Runtime-neutral: the `WebSocket` global is a web standard every
// supported runtime ships. The dialing half is not exported here: a
// `keyed-relay` locator names its relay route in its `rendezvous-relay` hint,
// and `@glowcap/relay` supplies the connector and FFI provider that
// follow it.
export {
	type RendezvousHandle,
	type RendezvousRoute,
	type RendezvousTransport,
	serveRendezvous,
} from "./rendezvous.ts";
export { openWebSocketChannel, webSocketChannel } from "./websocket.ts";
// Bun loads its FFI adapter asynchronously (its `bun:ffi` import stays off the
// static graph), so a Bun program awaits this once before the first
// synchronous FFI use (`new Host()`, `abiVersion()`). Deno and the browser
// resolve synchronously and never need it; `Runtime.open` and async transport
// helpers already await it.
export { ensureRuntimeReady } from "./internal/ffi/runtime.ts";
export {
	bareLocator,
	designatorHostPort,
	encodePeerLocator,
	formatLocatorUri,
	formatPeerUri,
	formatSturdyRef,
	HINT_ALT_LOCATORS,
	HINT_DIRECT_ADDRESSES,
	HINT_VIA,
	type HintValue,
	type HintWireForm,
	isKeyDesignator,
	type Locator,
	parseLocator,
	parseSturdyRef,
	stringHint,
	type SturdyRef,
	TRANSPORT_ID,
	TRANSPORT_INPROC,
	TRANSPORT_IROH,
	TRANSPORT_KEYED_RELAY,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_NOISE_RELAY,
	TRANSPORT_NOISE_TCP,
	TRANSPORT_ONION,
	TRANSPORT_TCP,
	TRANSPORT_WEBRTC,
} from "./locator.ts";

/** The linked library's ABI version as `[major, minor, patch]`. */
export function abiVersion(): [number, number, number] {
	const major = new Uint8Array(4),
		minor = new Uint8Array(4),
		patch = new Uint8Array(4);
	s.glowcap_abi_version(major, minor, patch);
	return [
		new DataView(major.buffer).getUint32(0, true),
		new DataView(minor.buffer).getUint32(0, true),
		new DataView(patch.buffer).getUint32(0, true),
	];
}
