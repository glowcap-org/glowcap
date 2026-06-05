/**
 * pancake-deno — a Deno FFI consumer for the pancake CapTP runtime.
 *
 * Binds the full surface of the three pancake cdylibs via
 * `Deno.dlopen`:
 *   - `libpancake_ffi_runtime`  (protocol core)        → {@link loadRuntime}
 *   - `libpancake_ffi_net_tcp`  (cleartext + TLS TCP)   → {@link loadNetTcp}
 *   - `libpancake_ffi_net_iroh` (QUIC over iroh)        → {@link loadNetIroh}
 *
 * Point `PANCAKE_LIB`, `PANCAKE_NET_TCP_LIB`, and `PANCAKE_NET_IROH_LIB`
 * at the prebuilt `target/release/*.so` artifacts. Run with
 * `--allow-ffi --allow-env --unstable-ffi`.
 */

export * from "./src/constants.ts";
export * from "./src/values.ts";
export {
  type AbortEvent,
  type DeliverEvent,
  drainRelayedResolutions,
  type FrameProbe,
  keypairFree,
  keypairFromSeed,
  keypairNew,
  keypairPubkey,
  type OcapnUri,
  parseOcapnUri,
  Peer,
  type ResolveEvent,
  type SessionEstablishedEvent,
  type StepOutcome,
  SturdyrefDedup,
  syrupFrameProbe,
  version,
} from "./src/host.ts";
export { type Conn, type FrameResult, IrohNetlayer, TcpNetlayer } from "./src/netlayer.ts";
export {
  type Bridge,
  DEFAULT_READ_TIMEOUT_MS,
  type InboundStatus,
  readAndFeed,
  runUntilAllOpen,
  stepAndFlush,
  tick,
  yieldToEventLoop,
} from "./src/pump.ts";
export { loadRuntime, type Runtime } from "./src/ffi/runtime.ts";
export { loadNetTcp, type NetTcp } from "./src/ffi/net_tcp.ts";
export { loadNetIroh, type NetIroh } from "./src/ffi/net_iroh.ts";
export { Arena, cstr, PancakeError, type Ptr } from "./src/ffi/abi.ts";
