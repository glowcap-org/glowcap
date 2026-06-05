/**
 * scenarios.ts — runnable verification of the pancake-deno binding.
 *
 * Run with the prebuilt cdylibs:
 *
 *   PANCAKE_LIB=.../libpancake_ffi_runtime.so \
 *   PANCAKE_NET_TCP_LIB=.../libpancake_ffi_net_tcp.so \
 *   PANCAKE_NET_IROH_LIB=.../libpancake_ffi_net_iroh.so \
 *   deno run --allow-ffi --allow-env --unstable-ffi src/scenarios.ts
 *
 * Verifies:
 *   1. pancake_version.
 *   2. pancake_ocapn_uri_parse.
 *   3. a typed-value round-trip (build an Argument list → marshal →
 *      project it back through the exact ABI byte layout).
 *   4. a pancake↔pancake handshake over TCP loopback reaching
 *      SESSION_OPEN on BOTH peers.
 *   5. (bonus) the iroh netlayer loads + constructs an endpoint.
 */

import { loadRuntime } from "./ffi/runtime.ts";
import { loadNetTcp } from "./ffi/net_tcp.ts";
import { loadNetIroh } from "./ffi/net_iroh.ts";
import { allocBuf, Arena } from "./ffi/abi.ts";
import { ARGUMENT_SIZE, PANCAKE_CODEC_SYRUP } from "./constants.ts";
import {
  argBool,
  argBytes,
  argInteger,
  argList,
  argString,
  argSymbol,
  type Argument,
  marshalArgumentArray,
  projectArgument,
} from "./values.ts";
import { parseOcapnUri, Peer, version } from "./host.ts";
import { TcpNetlayer } from "./netlayer.ts";
import { type Bridge, DEFAULT_READ_TIMEOUT_MS, runUntilAllOpen, stepAndFlush } from "./pump.ts";

function hex(bytes: Uint8Array, max = 8): string {
  const head = Array.from(bytes.slice(0, max), (b) => b.toString(16).padStart(2, "0")).join("");
  return bytes.length > max ? `${head}… (${bytes.length}B)` : head;
}

function describeArg(a: Argument): string {
  switch (a.kind) {
    case "symbol":
      return `Symbol(${a.value})`;
    case "string":
      return `String("${a.value}")`;
    case "bytes":
      return `Bytes(${hex(a.value)})`;
    case "integer":
      return `Integer(${a.value})`;
    case "bool":
      return `Bool(${a.value})`;
    case "void":
      return "Void";
    case "reference":
      return `Reference(${a.value.kind})`;
    case "list":
      return `List[${a.items.map(describeArg).join(", ")}]`;
  }
}

function argsEqual(a: Argument, b: Argument): boolean {
  if (a.kind !== b.kind) return false;
  switch (a.kind) {
    case "symbol":
    case "string":
      return a.value === (b as typeof a).value;
    case "integer":
      return a.value === (b as typeof a).value;
    case "bool":
      return a.value === (b as typeof a).value;
    case "void":
      return true;
    case "bytes": {
      const bb = (b as typeof a).value;
      return a.value.length === bb.length && a.value.every((x, i) => x === bb[i]);
    }
    case "list": {
      const bi = (b as typeof a).items;
      return a.items.length === bi.length && a.items.every((x, i) => argsEqual(x, bi[i]));
    }
    case "reference":
      return a.value.kind === (b as typeof a).value.kind;
  }
}

// ─── Verifications ─────────────────────────────────────────────────

function verifyVersion(): string {
  const rt = loadRuntime();
  try {
    const v = version(rt);
    console.log(`  pancake_version → "${v}"`);
    if (!v.startsWith("pancake-ffi")) throw new Error(`unexpected version string: ${v}`);
    return v;
  } finally {
    rt.close();
  }
}

function verifyOcapnUri(): void {
  const rt = loadRuntime();
  try {
    const peer = "ocapn://abcd1234.tcp-testing-only";
    const parsed = parseOcapnUri(rt, peer);
    console.log(
      `  pancake_ocapn_uri_parse("${peer}") → transport=${parsed.transport} designator=${parsed.designator} swissnum=${
        parsed.swissnum ? hex(parsed.swissnum) : "none"
      }`,
    );
    if (parsed.transport !== "tcp-testing-only") {
      throw new Error(`unexpected transport: ${parsed.transport}`);
    }
  } finally {
    rt.close();
  }
}

/**
 * Typed-value round-trip: build an Argument list, marshal it into the
 * exact LP64 tagged-union byte layout the C ABI consumes, then project
 * it straight back. This validates every variant's offsets against the
 * projection path (the same code the receive side runs on Rust-emitted
 * buffers).
 */
function verifyValueRoundTrip(): void {
  const original: Argument[] = [
    argSymbol("ping"),
    argString("hello pancake"),
    argInteger(-42),
    argBool(true),
    argBytes(new Uint8Array([0xde, 0xad, 0xbe, 0xef])),
    argList([argSymbol("nested"), argInteger(7), argBool(false)]),
    argList([]),
  ];

  const arena = new Arena();
  const { ptr, count } = marshalArgumentArray(arena, original);
  if (ptr === null || count !== original.length) {
    throw new Error("marshalArgumentArray produced an unexpected shape");
  }
  const view = new Deno.UnsafePointerView(ptr);
  const projected: Argument[] = [];
  for (let i = 0; i < count; i++) projected.push(projectArgument(view, i * ARGUMENT_SIZE));

  for (let i = 0; i < original.length; i++) {
    const ok = argsEqual(original[i], projected[i]);
    console.log(
      `  [${i}] ${describeArg(original[i])} ⇄ ${describeArg(projected[i])} ${ok ? "✓" : "✗"}`,
    );
    if (!ok) throw new Error(`round-trip mismatch at index ${i}`);
  }
}

interface HandshakeResult {
  opened: boolean;
  boundAddr: string;
  dialerPartner: Uint8Array | null;
  listenerPartner: Uint8Array | null;
}

/**
 * Construct two peers, connect them over TCP loopback, and pump both
 * until SESSION_OPEN on both ends. The dialer writes its start-session
 * first.
 */
async function verifyTcpHandshake(): Promise<HandshakeResult> {
  const rt = loadRuntime();
  const netTcp = loadNetTcp();
  const tcp = TcpNetlayer.cleartext(netTcp);

  let listenerHandle: Deno.PointerValue = null;
  let dialerConn: ReturnType<TcpNetlayer["connect"]> | undefined;
  let listenerConn: ReturnType<TcpNetlayer["connect"]> | undefined;
  let dialer: Peer | undefined;
  let listener: Peer | undefined;

  try {
    const bound = tcp.listen("127.0.0.1:0");
    listenerHandle = bound.listener;
    console.log(`  listening on ${bound.boundAddr}`);

    dialerConn = tcp.connect(bound.boundAddr);
    const accepted = tcp.acceptTimed(listenerHandle, 2000);
    if (accepted === "would-block") throw new Error("accept timed out");
    listenerConn = accepted;
    console.log("  TCP loopback connection established");

    dialer = Peer.create(rt, PANCAKE_CODEC_SYRUP);
    listener = Peer.create(rt, PANCAKE_CODEC_SYRUP);
    dialerConn.setReadTimeout(DEFAULT_READ_TIMEOUT_MS);
    listenerConn.setReadTimeout(DEFAULT_READ_TIMEOUT_MS);

    // Dialer writes its start-session first, then the listener.
    dialer.sendStartSession("tcp-testing-only", bound.boundAddr);
    stepAndFlush(dialer, dialerConn);
    listener.sendStartSession("tcp-testing-only", bound.boundAddr);
    stepAndFlush(listener, listenerConn);

    const bridges: Bridge[] = [
      { peer: dialer, conn: dialerConn },
      { peer: listener, conn: listenerConn },
    ];
    const opened = await runUntilAllOpen(bridges, { timeoutMs: 15_000 });

    // Drain the SessionEstablished events for diagnostics.
    const dEst = dialer.pollEventSessionEstablished();
    const lEst = listener.pollEventSessionEstablished();
    if (dEst) console.log(`  dialer  partner locator: ${dEst.partnerLocator}`);
    if (lEst) console.log(`  listener partner locator: ${lEst.partnerLocator}`);

    return {
      opened,
      boundAddr: bound.boundAddr,
      dialerPartner: dialer.getPartnerPeerId(),
      listenerPartner: listener.getPartnerPeerId(),
    };
  } finally {
    dialer?.free();
    listener?.free();
    dialerConn?.close();
    listenerConn?.close();
    if (listenerHandle !== null) tcp.listenerClose(listenerHandle);
    netTcp.close();
    rt.close();
  }
}

function verifyIrohLoads(): void {
  const netIroh = loadNetIroh();
  try {
    const endpoint = netIroh.sym.pancake_endpoint_iroh_new() as Deno.PointerValue;
    if (endpoint === null) {
      console.log(
        "  iroh endpoint construction returned NULL (UDP bind may be sandboxed) — lib loads OK",
      );
      return;
    }
    const idBuf = allocBuf(65);
    netIroh.sym.pancake_endpoint_iroh_endpoint_id(endpoint, idBuf, 65n);
    const id = new Deno.UnsafePointerView(Deno.UnsafePointer.of(idBuf)!).getCString();
    console.log(`  iroh endpoint id: ${id.slice(0, 16)}…`);
    netIroh.sym.pancake_endpoint_iroh_close(endpoint);
  } finally {
    netIroh.close();
  }
}

// ─── Entry point ───────────────────────────────────────────────────

export async function runAll(): Promise<boolean> {
  let allOk = true;
  const section = (n: number, title: string) => console.log(`\n[${n}] ${title}`);

  section(1, "pancake_version");
  verifyVersion();

  section(2, "OCapN URI parse");
  verifyOcapnUri();

  section(3, "typed-value round-trip (marshal ⇄ project)");
  verifyValueRoundTrip();

  section(4, "pancake↔pancake handshake over TCP loopback → SESSION_OPEN");
  const hs = await verifyTcpHandshake();
  console.log(
    `  dialer  session state: ${hs.opened ? "OPEN" : "NOT-OPEN"} (partner peer-id ${
      hs.dialerPartner ? hex(hs.dialerPartner) : "n/a"
    })`,
  );
  console.log(
    `  listener session state: ${hs.opened ? "OPEN" : "NOT-OPEN"} (partner peer-id ${
      hs.listenerPartner ? hex(hs.listenerPartner) : "n/a"
    })`,
  );
  if (hs.opened) {
    console.log("  ✓ BOTH peers reached PANCAKE_SESSION_OPEN");
  } else {
    console.log("  ✗ handshake did not reach SESSION_OPEN on both peers");
    allOk = false;
  }

  section(5, "iroh netlayer load");
  try {
    verifyIrohLoads();
  } catch (e) {
    console.log(`  iroh check skipped: ${(e as Error).message}`);
  }

  console.log(`\n${allOk ? "ALL CHECKS PASSED ✓" : "SOME CHECKS FAILED ✗"}`);
  return allOk;
}

if (import.meta.main) {
  const ok = await runAll();
  Deno.exit(ok ? 0 : 1);
}
