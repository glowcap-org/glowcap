// Idiomatic JavaScript/TypeScript API for pancake — a full OCapN/CapTP host
// over the byte-fed host archive `libpancake_driver` (ADR-0072), with the
// shared vocabulary of `libpancake_ocapn` beside it (ADR-0059). One module
// runs on Deno and Bun; the runtime-specific FFI and sockets are isolated
// behind `./internal/ffi/runtime.ts`.
//
// The library owns every CapTP decision — routing, three-party redemption,
// gift origination, far vows — and the binding moves bytes: each
// `Session`'s serve loop feeds raw reads to the core's stream delimiter and
// honors the host's action queue (dial, flush, entropy, settle). A transport
// that links its own pancake archive lives in its own module beside this one —
// `./transport/tcp.ts`, `./transport/inproc.ts`, and the optional
// `@pancake/iroh` package — exactly as a C consumer links archives à la carte.
//
// The implementation is split by responsibility into sibling modules; this
// file is the barrel that re-exports the public surface, so `@pancake/stack`'s
// import path is one place. The layers: `errors` (the `PancakeError` family),
// `value` (the value vocabulary plus the `Ref`/`AppValue` application layer),
// `codec`/`context` (marshalling and allocation scopes), `trampoline` (the one
// native behavior callback), `host` (the `Host`), `action` (host-action
// decode+execute), `promise` (the `RemotePromise` send returns), `gc`
// (ADR-0063), `dial` (unified dial executor + `connect`), `listen`
// (`Server` / `listen` / keyed-tcp host), `session` (the `Session` verbs
// and mint/handshake), `pump` (the byte-fed embedder serve/feed/flush
// choreography), and `locator` (OCapN URIs).
//
//   const conn = await connect(tcpLocator("127.0.0.1", 9099));
//   conn.serve().catch(() => {});
//   const greeter = await conn.fetch("greeter");
//   const reply = await conn.send(greeter, "greet", ["world"]);

import { ocapnS as s } from "./internal/ffi/ocapn.ts";

export { FetchFailed, PancakeError, VowBroken } from "./errors.ts";
export {
	type AppValue,
	type Behavior,
	type Codec,
	Kw,
	PSet,
	Reachability,
	Ref,
	Sym,
	Tagged,
	tagged,
} from "./value.ts";
export { Context, type ContextAllocator } from "./context.ts";
export { Host } from "./host.ts";
export { RemotePromise } from "./promise.ts";
export { type Channel, Session } from "./session.ts";
export { connect } from "./dial.ts";
export { KeyedTcpServer, listen, listenKeyedTcp, Server } from "./listen.ts";
export {
	designatorHostPort,
	encodePeerLocator,
	formatPeerUri,
	HINT_DIRECT_ADDRESSES,
	keyedTcpLocator,
	type Locator,
	parseLocator,
	socketAddrDesignator,
	tcpLocator,
	TRANSPORT_INPROC,
	TRANSPORT_IROH,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_TCP,
} from "./locator.ts";

/** The linked library's ABI version as `[major, minor, patch]`. */
export function abiVersion(): [number, number, number] {
	const major = new Uint8Array(4),
		minor = new Uint8Array(4),
		patch = new Uint8Array(4);
	s.pancake_abi_version(major, minor, patch);
	return [
		new DataView(major.buffer).getUint32(0, true),
		new DataView(minor.buffer).getUint32(0, true),
		new DataView(patch.buffer).getUint32(0, true),
	];
}
