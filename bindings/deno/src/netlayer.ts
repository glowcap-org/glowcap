/**
 * netlayer.ts — transport-agnostic connection surface over the two
 * netlayer cdylibs.
 *
 * The netlayer seam between transports is exactly four per-connection
 * frame ops (read / write / set-read-timeout / close) plus the
 * `acceptable_location` transport tag the handshake advertises. The
 * `Conn` interface bundles them so ONE pump drives cleartext TCP,
 * `tcp-tls`, or iroh QUIC without per-transport forks. `read_frame`
 * hands back a self-describing PancakeManagedFrame; we copy the body
 * out and release it via the shared `pancake_managed_frame_release`
 * (NEVER a host free).
 */

import {
  allocBuf,
  asBuf,
  type Buf,
  cstr,
  isNull,
  PancakeError,
  type Ptr,
  readBytes,
  readCString,
  viewOf,
} from "./ffi/abi.ts";
import {
  MANAGED_FRAME_SIZE,
  PANCAKE_ENDPOINT_ERR_CLOSED,
  PANCAKE_ENDPOINT_ERR_MALFORMED,
  PANCAKE_ENDPOINT_ERR_WOULD_BLOCK,
  PANCAKE_OK,
} from "./constants.ts";
import { IROH_ID_CAP, type NetIroh } from "./ffi/net_iroh.ts";
import type { NetTcp } from "./ffi/net_tcp.ts";

export type FrameResult = Uint8Array | "would-block" | "closed" | "malformed";

/** One transport connection — the pump's only view of the wire. */
export interface Conn {
  readonly transportName: string;
  readFrame(): FrameResult;
  writeFrame(bytes: Uint8Array): void;
  setReadTimeout(ms: number): void;
  close(): void;
}

function readPtrField(buf: Buf, off = 0): Ptr {
  return Deno.UnsafePointer.create(viewOf(buf).getBigUint64(off, true));
}

// ─── TCP / TLS ─────────────────────────────────────────────────────

interface TcpVtable {
  readonly transportName: string;
  connect(hostPort: Buf): Ptr;
  listen(bindAddr: Buf, outBuf: Buf, cap: bigint): Ptr;
  acceptTimed(listener: Ptr, ms: bigint, outConn: Buf): number;
  setReadTimeout(conn: Ptr, ms: bigint): number;
  readFrame(conn: Ptr, outManaged: Buf): number;
  writeFrame(conn: Ptr, bytes: Buf, len: bigint): number;
  connClose(conn: Ptr): void;
  listenerClose(listener: Ptr): void;
  releaseManaged(frame: Buf): void;
}

class TcpConn implements Conn {
  #vt: TcpVtable;
  #lastError: () => string;
  #ptr: Ptr;
  constructor(vt: TcpVtable, lastError: () => string, ptr: Ptr) {
    this.#vt = vt;
    this.#lastError = lastError;
    this.#ptr = ptr;
  }
  get transportName(): string {
    return this.#vt.transportName;
  }
  readFrame(): FrameResult {
    const managed = allocBuf(MANAGED_FRAME_SIZE);
    const rc = this.#vt.readFrame(this.#ptr, managed);
    if (rc === PANCAKE_OK) {
      const dv = viewOf(managed);
      const ptr = readPtrField(managed);
      const len = Number(dv.getBigUint64(8, true));
      const body = readBytes(ptr, len);
      this.#vt.releaseManaged(managed);
      return body;
    }
    if (rc === PANCAKE_ENDPOINT_ERR_WOULD_BLOCK) return "would-block";
    if (rc === PANCAKE_ENDPOINT_ERR_CLOSED) return "closed";
    if (rc === PANCAKE_ENDPOINT_ERR_MALFORMED) return "malformed";
    throw new PancakeError("tcp_read_frame", rc, this.#lastError());
  }
  writeFrame(bytes: Uint8Array): void {
    const rc = this.#vt.writeFrame(this.#ptr, asBuf(bytes), BigInt(bytes.length));
    if (rc !== PANCAKE_OK) throw new PancakeError("tcp_write_frame", rc, this.#lastError());
  }
  setReadTimeout(ms: number): void {
    const rc = this.#vt.setReadTimeout(this.#ptr, BigInt(ms));
    if (rc !== PANCAKE_OK) throw new PancakeError("tcp_set_read_timeout_ms", rc, this.#lastError());
  }
  close(): void {
    this.#vt.connClose(this.#ptr);
  }
}

/** Cleartext-TCP or `tcp-tls` netlayer (one `libpancake_ffi_net_tcp`). */
export class TcpNetlayer {
  #net: NetTcp;
  #vt: TcpVtable;

  private constructor(net: NetTcp, vt: TcpVtable) {
    this.#net = net;
    this.#vt = vt;
  }

  static cleartext(net: NetTcp): TcpNetlayer {
    const s = net.sym;
    return new TcpNetlayer(net, {
      transportName: "tcp-testing-only",
      connect: (a) => s.pancake_endpoint_tcp_connect(a) as Ptr,
      listen: (a, o, c) => s.pancake_endpoint_tcp_listen(a, o, c) as Ptr,
      acceptTimed: (l, ms, o) => s.pancake_endpoint_tcp_accept_timed(l, ms, o),
      setReadTimeout: (cn, ms) => s.pancake_endpoint_tcp_set_read_timeout_ms(cn, ms),
      readFrame: (cn, om) => s.pancake_endpoint_tcp_read_frame(cn, om),
      writeFrame: (cn, b, l) => s.pancake_endpoint_tcp_write_frame(cn, b, l),
      connClose: (cn) => s.pancake_endpoint_tcp_conn_close(cn),
      listenerClose: (l) => s.pancake_endpoint_tcp_listener_close(l),
      releaseManaged: (f) => s.pancake_managed_frame_release(f),
    });
  }

  static tls(net: NetTcp): TcpNetlayer {
    const s = net.sym;
    return new TcpNetlayer(net, {
      transportName: "tcp-tls",
      connect: (a) => s.pancake_endpoint_tcp_tls_connect(a) as Ptr,
      listen: (a, o, c) => s.pancake_endpoint_tcp_tls_listen(a, o, c) as Ptr,
      acceptTimed: (l, ms, o) => s.pancake_endpoint_tcp_tls_accept_timed(l, ms, o),
      setReadTimeout: (cn, ms) => s.pancake_endpoint_tcp_tls_set_read_timeout_ms(cn, ms),
      readFrame: (cn, om) => s.pancake_endpoint_tcp_tls_read_frame(cn, om),
      writeFrame: (cn, b, l) => s.pancake_endpoint_tcp_tls_write_frame(cn, b, l),
      connClose: (cn) => s.pancake_endpoint_tcp_tls_conn_close(cn),
      listenerClose: (l) => s.pancake_endpoint_tcp_tls_listener_close(l),
      releaseManaged: (f) => s.pancake_managed_frame_release(f),
    });
  }

  get transportName(): string {
    return this.#vt.transportName;
  }

  /** Bind + listen. Returns the listener handle + the actual bound `host:port`. */
  listen(bindAddr: string): { listener: Ptr; boundAddr: string } {
    const out = allocBuf(64);
    const listener = this.#vt.listen(cstr(bindAddr), out, BigInt(out.length));
    if (isNull(listener)) {
      throw new PancakeError(`tcp_listen(${bindAddr})`, -1, this.#net.lastError());
    }
    const boundAddr = readCString(Deno.UnsafePointer.of(out));
    return { listener, boundAddr: boundAddr || bindAddr };
  }

  connect(hostPort: string): Conn {
    const ptr = this.#vt.connect(cstr(hostPort));
    if (isNull(ptr)) throw new PancakeError(`tcp_connect(${hostPort})`, -1, this.#net.lastError());
    return new TcpConn(this.#vt, this.#net.lastError, ptr);
  }

  acceptTimed(listener: Ptr, timeoutMs: number): Conn | "would-block" {
    const out = allocBuf(8);
    const rc = this.#vt.acceptTimed(listener, BigInt(timeoutMs), out);
    if (rc === PANCAKE_OK) return new TcpConn(this.#vt, this.#net.lastError, readPtrField(out));
    if (rc === PANCAKE_ENDPOINT_ERR_WOULD_BLOCK) return "would-block";
    throw new PancakeError("tcp_accept_timed", rc, this.#net.lastError());
  }

  listenerClose(listener: Ptr): void {
    this.#vt.listenerClose(listener);
  }
}

// ─── iroh (QUIC) ───────────────────────────────────────────────────

class IrohConn implements Conn {
  #net: NetIroh;
  #ptr: Ptr;
  constructor(net: NetIroh, ptr: Ptr) {
    this.#net = net;
    this.#ptr = ptr;
  }
  get transportName(): string {
    return "iroh";
  }
  readFrame(): FrameResult {
    const managed = allocBuf(MANAGED_FRAME_SIZE);
    const rc = this.#net.sym.pancake_endpoint_iroh_read_frame(this.#ptr, managed);
    if (rc === PANCAKE_OK) {
      const dv = viewOf(managed);
      const ptr = readPtrField(managed);
      const len = Number(dv.getBigUint64(8, true));
      const body = readBytes(ptr, len);
      this.#net.sym.pancake_managed_frame_release(managed);
      return body;
    }
    if (rc === PANCAKE_ENDPOINT_ERR_WOULD_BLOCK) return "would-block";
    if (rc === PANCAKE_ENDPOINT_ERR_CLOSED) return "closed";
    if (rc === PANCAKE_ENDPOINT_ERR_MALFORMED) return "malformed";
    throw new PancakeError("iroh_read_frame", rc, this.#net.lastError());
  }
  writeFrame(bytes: Uint8Array): void {
    const rc = this.#net.sym.pancake_endpoint_iroh_write_frame(
      this.#ptr,
      asBuf(bytes),
      BigInt(bytes.length),
    );
    if (rc !== PANCAKE_OK) throw new PancakeError("iroh_write_frame", rc, this.#net.lastError());
  }
  setReadTimeout(ms: number): void {
    const rc = this.#net.sym.pancake_endpoint_iroh_set_read_timeout_ms(this.#ptr, BigInt(ms));
    if (rc !== PANCAKE_OK) {
      throw new PancakeError("iroh_set_read_timeout_ms", rc, this.#net.lastError());
    }
  }
  close(): void {
    this.#net.sym.pancake_endpoint_iroh_conn_close(this.#ptr);
  }
}

/** iroh (QUIC) netlayer. The endpoint owns an auto-bound UDP socket. */
export class IrohNetlayer {
  #net: NetIroh;
  #endpoint: Ptr;

  private constructor(net: NetIroh, endpoint: Ptr) {
    this.#net = net;
    this.#endpoint = endpoint;
  }

  static create(net: NetIroh): IrohNetlayer {
    const endpoint = net.sym.pancake_endpoint_iroh_new() as Ptr;
    if (isNull(endpoint)) throw new PancakeError("iroh_new", -1, net.lastError());
    return new IrohNetlayer(net, endpoint);
  }

  get transportName(): string {
    return "iroh";
  }

  endpointId(): string {
    const buf = allocBuf(IROH_ID_CAP);
    const rc = this.#net.sym.pancake_endpoint_iroh_endpoint_id(
      this.#endpoint,
      buf,
      BigInt(buf.length),
    );
    if (rc !== PANCAKE_OK) throw new PancakeError("iroh_endpoint_id", rc, this.#net.lastError());
    return readCString(Deno.UnsafePointer.of(buf));
  }

  boundAddr(): string {
    const buf = allocBuf(64);
    const rc = this.#net.sym.pancake_endpoint_iroh_bound_addr(
      this.#endpoint,
      buf,
      BigInt(buf.length),
    );
    if (rc !== PANCAKE_OK) throw new PancakeError("iroh_bound_addr", rc, this.#net.lastError());
    return readCString(Deno.UnsafePointer.of(buf));
  }

  connect(partnerEndpointId: string, directAddr: string | null = null): Conn {
    const ptr = this.#net.sym.pancake_endpoint_iroh_connect(
      this.#endpoint,
      cstr(partnerEndpointId),
      directAddr === null ? null : cstr(directAddr),
    ) as Ptr;
    if (isNull(ptr)) {
      throw new PancakeError(`iroh_connect(${partnerEndpointId})`, -1, this.#net.lastError());
    }
    return new IrohConn(this.#net, ptr);
  }

  listen(): Ptr {
    const listener = this.#net.sym.pancake_endpoint_iroh_listen(this.#endpoint) as Ptr;
    if (isNull(listener)) throw new PancakeError("iroh_listen", -1, this.#net.lastError());
    return listener;
  }

  acceptTimed(listener: Ptr, timeoutMs: number): Conn | "would-block" {
    const out = allocBuf(8);
    const rc = this.#net.sym.pancake_endpoint_iroh_accept_timed(listener, BigInt(timeoutMs), out);
    if (rc === PANCAKE_OK) return new IrohConn(this.#net, readPtrField(out));
    if (rc === PANCAKE_ENDPOINT_ERR_WOULD_BLOCK) return "would-block";
    throw new PancakeError("iroh_accept_timed", rc, this.#net.lastError());
  }

  listenerClose(listener: Ptr): void {
    this.#net.sym.pancake_endpoint_iroh_listener_close(listener);
  }

  close(): void {
    this.#net.sym.pancake_endpoint_iroh_close(this.#endpoint);
  }
}
