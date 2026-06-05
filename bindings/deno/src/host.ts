/**
 * host.ts — the high-level protocol surface over the runtime cdylib.
 *
 * `Peer` wraps a `PancakePeer` handle and exposes lifecycle, the
 * step/queue pump primitives, typed send, and drain-and-poll receive.
 * Module-level helpers cover library metadata, the Ed25519 keypair,
 * the OCapN URI parser, the Syrup frame probe, and the cross-peer
 * coordination table.
 *
 * Every Rust-allocated buffer crossing back (outbound frames, projected
 * args / resolutions / abort messages / partner locators) is released
 * via the matching `pancake_*_free` before this layer returns owned
 * JS values — callers never see a raw pointer.
 */

import {
  allocBuf,
  Arena,
  asBuf,
  type Buf,
  cstr,
  decodeUtf8,
  isNull,
  PancakeError,
  type Ptr,
  readBytes,
  readCString,
  utf8,
  viewOf,
  writePtr,
} from "./ffi/abi.ts";
import type { Runtime } from "./ffi/runtime.ts";
import {
  ARGUMENT_SIZE,
  FRAME_SIZE,
  MANAGED_FRAME_SIZE,
  PANCAKE_ERR_HANDSHAKE_INCOMPLETE,
  PANCAKE_FRAME_COMPLETE,
  PANCAKE_FRAME_INCOMPLETE,
  PANCAKE_FRAME_MALFORMED,
  PANCAKE_OK,
  PANCAKE_REF_BROKEN,
  REFERENCE_SIZE,
  RESOLUTION_SIZE,
  STEP_OUTCOME_SIZE,
} from "./constants.ts";
import {
  type Argument,
  marshalArgumentArray,
  marshalReference,
  marshalResolution,
  projectArgument,
  projectReference,
  projectResolution,
  type Reference,
  type Resolution,
} from "./values.ts";

/** A pointer view over a caller-owned out-buffer. */
function viewPtr(buf: Buf): Deno.UnsafePointerView {
  return new Deno.UnsafePointerView(Deno.UnsafePointer.of(buf)!);
}

/** Read a pointer field out of a caller-owned out-buffer. */
function readPtrField(buf: Buf, offset = 0): Ptr {
  return Deno.UnsafePointer.create(viewOf(buf).getBigUint64(offset, true));
}

export interface StepOutcome {
  kind: number;
  nextDeadlineMs: bigint;
}

export interface DeliverEvent {
  target: Reference;
  args: Argument[];
  answerId: bigint | null;
  resolveMeDesc: Reference | null;
}

export interface ResolveEvent {
  answerId: bigint;
  resolution: Resolution;
}

export interface AbortEvent {
  reasonKind: number;
  message: string;
}

export interface SessionEstablishedEvent {
  partnerPubkey: Uint8Array;
  partnerLocator: string;
}

export interface FrameProbe {
  status: "complete" | "incomplete" | "malformed";
  end: number;
}

/** A pancake CapTP peer: one session, owned by the JS caller. */
export class Peer {
  #rt: Runtime;
  #ptr: Ptr;
  #freed = false;

  private constructor(rt: Runtime, ptr: Ptr) {
    this.#rt = rt;
    this.#ptr = ptr;
  }

  /** Raw handle (for cross-peer helpers). */
  get handle(): Ptr {
    return this.#ptr;
  }

  /**
   * Construct a peer with the canonical-production defaults: a fresh
   * Ed25519 keypair (consumed by the peer), V1.0 + Goblins wire
   * profile. `codec` is `PANCAKE_CODEC_SYRUP` or `_CAPNP`.
   */
  static create(rt: Runtime, codec: number): Peer {
    const kp = rt.sym.pancake_keypair_new() as Ptr;
    if (isNull(kp)) throw new PancakeError("pancake_keypair_new", -1, rt.lastError());
    const ptr = rt.sym.pancake_peer_new(kp, codec) as Ptr;
    if (isNull(ptr)) {
      rt.sym.pancake_keypair_free(kp); // constructor failure does not consume the keypair
      throw new PancakeError("pancake_peer_new", -1, rt.lastError());
    }
    return new Peer(rt, ptr);
  }

  /**
   * Escape-hatch constructor (stub-keyed in-process pairs, explicit
   * PreSpec version, ASCII-padded peer-ids). Production consumers use
   * {@link Peer.create}.
   */
  static createAdvanced(
    rt: Runtime,
    opts: {
      myPeerId?: string | null;
      partnerPeerId?: string | null;
      codec: number;
      captpVersion: number;
      keypair?: Ptr;
    },
  ): Peer {
    const kp = opts.keypair ?? null;
    const ptr = rt.sym.pancake_peer_new_advanced(
      opts.myPeerId == null ? null : cstr(opts.myPeerId),
      opts.partnerPeerId == null ? null : cstr(opts.partnerPeerId),
      opts.codec,
      opts.captpVersion,
      kp,
    ) as Ptr;
    if (isNull(ptr)) {
      throw new PancakeError("pancake_peer_new_advanced", -1, rt.lastError());
    }
    return new Peer(rt, ptr);
  }

  #check(op: string, rc: number): void {
    if (rc !== PANCAKE_OK) throw new PancakeError(op, rc, this.#rt.lastError());
  }

  // ─── Identity ────────────────────────────────────────────────────

  getMyPeerId(): Uint8Array {
    const out = allocBuf(32);
    this.#check(
      "pancake_peer_get_my_peer_id",
      this.#rt.sym.pancake_peer_get_my_peer_id(this.#ptr, out),
    );
    return out;
  }

  /** Partner peer-id, or null if the handshake hasn't completed. */
  getPartnerPeerId(): Uint8Array | null {
    const out = allocBuf(32);
    const rc = this.#rt.sym.pancake_peer_get_partner_peer_id(this.#ptr, out);
    if (rc === PANCAKE_OK) return out;
    if (rc === PANCAKE_ERR_HANDSHAKE_INCOMPLETE) return null;
    throw new PancakeError("pancake_peer_get_partner_peer_id", rc, this.#rt.lastError());
  }

  // ─── Export registration ─────────────────────────────────────────

  registerBootstrapCap(swissnum: Uint8Array, exportId: bigint | number): void {
    this.#check(
      "pancake_peer_register_bootstrap_cap",
      this.#rt.sym.pancake_peer_register_bootstrap_cap(
        this.#ptr,
        asBuf(swissnum),
        BigInt(swissnum.length),
        BigInt(exportId),
      ),
    );
  }

  registerExport(exportId: bigint | number): void {
    this.#check(
      "pancake_peer_register_export",
      this.#rt.sym.pancake_peer_register_export(this.#ptr, BigInt(exportId)),
    );
  }

  // ─── Step + queues ───────────────────────────────────────────────

  step(): StepOutcome {
    const out = allocBuf(STEP_OUTCOME_SIZE);
    this.#check("pancake_peer_step", this.#rt.sym.pancake_peer_step(this.#ptr, out));
    const dv = viewOf(out);
    return { kind: dv.getUint32(0, true), nextDeadlineMs: dv.getBigUint64(8, true) };
  }

  feedInbound(body: Uint8Array): void {
    // The runtime borrows these bytes for the call (decodes + dispatches
    // inline, no owned-Frame copy), so the buffer only needs to stay
    // reachable across the call. `keepalive` guarantees a stable,
    // ArrayBuffer-backed buffer pinned for the call's duration.
    const keepalive = allocBuf(body.length);
    keepalive.set(body);
    const frame = allocBuf(FRAME_SIZE);
    const dv = viewOf(frame);
    writePtr(dv, 0, Deno.UnsafePointer.of(keepalive));
    dv.setBigUint64(8, BigInt(keepalive.length), true);
    this.#check(
      "pancake_peer_feed_inbound",
      this.#rt.sym.pancake_peer_feed_inbound(this.#ptr, frame),
    );
  }

  /**
   * Drain the next outbound frame body, or null if the queue is empty.
   *
   * The runtime hands back a self-describing PancakeManagedFrame (a
   * zero-copy view into runtime memory + embedded release). We copy the
   * body into a JS-owned buffer and release the managed frame via the
   * single pancake_managed_frame_release before returning — callers get
   * the idiomatic JS unit and never see a raw pointer.
   */
  takeOutbound(): Uint8Array | null {
    const frame = allocBuf(MANAGED_FRAME_SIZE);
    const rc = this.#rt.sym.pancake_peer_take_outbound(this.#ptr, frame);
    if (rc === 0) return null;
    if (rc !== 1) throw new PancakeError("pancake_peer_take_outbound", rc, this.#rt.lastError());
    const dv = viewOf(frame);
    const ptr = Deno.UnsafePointer.create(dv.getBigUint64(0, true));
    const len = Number(dv.getBigUint64(8, true));
    const body = readBytes(ptr, len);
    // Release via the embedded callback (NEVER host free); the same
    // release path frees frames from any pancake cdylib.
    this.#rt.sym.pancake_managed_frame_release(frame);
    return body;
  }

  hasOutbound(): boolean {
    return this.#rt.sym.pancake_peer_has_outbound(this.#ptr) === 1;
  }

  hasEvent(): boolean {
    return this.#rt.sym.pancake_peer_has_event(this.#ptr) === 1;
  }

  /** Next event kind without consuming, or null if the queue is empty. */
  peekEventKind(): number | null {
    const out = allocBuf(4);
    const rc = this.#rt.sym.pancake_peer_peek_event_kind(this.#ptr, out);
    if (rc === 0) return null;
    if (rc !== 1) throw new PancakeError("pancake_peer_peek_event_kind", rc, this.#rt.lastError());
    return viewOf(out).getUint32(0, true);
  }

  consumeEvent(): boolean {
    const rc = this.#rt.sym.pancake_peer_consume_event(this.#ptr);
    if (rc === 1) return true;
    if (rc === 0) return false;
    throw new PancakeError("pancake_peer_consume_event", rc, this.#rt.lastError());
  }

  sessionState(): number {
    const out = allocBuf(4);
    this.#check(
      "pancake_peer_session_state",
      this.#rt.sym.pancake_peer_session_state(this.#ptr, out),
    );
    return viewOf(out).getUint32(0, true);
  }

  // ─── Typed send ──────────────────────────────────────────────────

  sendStartSession(transport: string, designator: string): void {
    this.#check(
      "pancake_peer_send_start_session",
      this.#rt.sym.pancake_peer_send_start_session(this.#ptr, cstr(transport), cstr(designator)),
    );
  }

  sendDeliver(target: Reference, args: Argument[], answerId: bigint | number = 0): void {
    const arena = new Arena();
    const targetBuf = marshalReference(arena, target);
    const { ptr, count } = marshalArgumentArray(arena, args);
    this.#check(
      "pancake_peer_send_deliver",
      this.#rt.sym.pancake_peer_send_deliver(
        this.#ptr,
        targetBuf,
        ptr,
        BigInt(count),
        BigInt(answerId),
      ),
    );
  }

  sendResolve(answerId: bigint | number, resolution: Resolution): void {
    const arena = new Arena();
    const resBuf = marshalResolution(arena, resolution);
    this.#check(
      "pancake_peer_send_resolve",
      this.#rt.sym.pancake_peer_send_resolve(this.#ptr, BigInt(answerId), resBuf),
    );
  }

  sendAbort(reasonKind: number, message = ""): void {
    const msg = utf8(message);
    this.#check(
      "pancake_peer_send_abort",
      this.#rt.sym.pancake_peer_send_abort(this.#ptr, reasonKind, msg, BigInt(msg.length)),
    );
  }

  enlivenSturdyref(sturdyref: Reference): void {
    const arena = new Arena();
    const refBuf = marshalReference(arena, sturdyref);
    this.#check(
      "pancake_peer_enliven_sturdyref",
      this.#rt.sym.pancake_peer_enliven_sturdyref(this.#ptr, refBuf),
    );
  }

  shutdown(): void {
    this.#rt.sym.pancake_peer_shutdown(this.#ptr);
  }

  // ─── Typed receive (drain-and-poll) ──────────────────────────────

  pollEventDeliver(): DeliverEvent | null {
    const outTarget = allocBuf(REFERENCE_SIZE);
    const outArgs = allocBuf(8);
    const outArgsCount = allocBuf(8);
    const outAnswerId = allocBuf(8);
    const outRmd = allocBuf(REFERENCE_SIZE);
    const rc = this.#rt.sym.pancake_peer_poll_event_deliver(
      this.#ptr,
      outTarget,
      outArgs,
      outArgsCount,
      outAnswerId,
      outRmd,
    );
    if (rc === 0) return null;
    if (rc !== 1) {
      throw new PancakeError("pancake_peer_poll_event_deliver", rc, this.#rt.lastError());
    }

    const target = projectReference(viewPtr(outTarget), 0);
    const argsPtr = readPtrField(outArgs);
    const count = Number(viewOf(outArgsCount).getBigUint64(0, true));
    const args: Argument[] = [];
    if (argsPtr !== null && count > 0) {
      const argsView = new Deno.UnsafePointerView(argsPtr);
      for (let i = 0; i < count; i++) args.push(projectArgument(argsView, i * ARGUMENT_SIZE));
    }
    const answerIdRaw = viewOf(outAnswerId).getBigUint64(0, true);

    // resolve-me-desc: PANCAKE_REF_BROKEN is the absent sentinel.
    const rmdView = viewPtr(outRmd);
    const rmdKind = rmdView.getUint32(0);
    let resolveMeDesc: Reference | null = null;
    if (rmdKind !== PANCAKE_REF_BROKEN) {
      resolveMeDesc = projectReference(rmdView, 0);
    }
    this.#rt.sym.pancake_typed_resolve_me_desc_free(Deno.UnsafePointer.of(outRmd));
    if (argsPtr !== null) this.#rt.sym.pancake_typed_args_free(argsPtr, BigInt(count));

    return {
      target,
      args,
      answerId: answerIdRaw === 0n ? null : answerIdRaw,
      resolveMeDesc,
    };
  }

  pollEventResolve(): ResolveEvent | null {
    const outAnswerId = allocBuf(8);
    const outRes = allocBuf(RESOLUTION_SIZE);
    const rc = this.#rt.sym.pancake_peer_poll_event_resolve(this.#ptr, outAnswerId, outRes);
    if (rc === 0) return null;
    if (rc !== 1) {
      throw new PancakeError("pancake_peer_poll_event_resolve", rc, this.#rt.lastError());
    }
    const resolution = projectResolution(viewPtr(outRes), 0);
    this.#rt.sym.pancake_typed_resolution_free(Deno.UnsafePointer.of(outRes));
    return { answerId: viewOf(outAnswerId).getBigUint64(0, true), resolution };
  }

  pollEventAbort(): AbortEvent | null {
    const outKind = allocBuf(4);
    const outMsgPtr = allocBuf(8);
    const outMsgLen = allocBuf(8);
    const rc = this.#rt.sym.pancake_peer_poll_event_abort(this.#ptr, outKind, outMsgPtr, outMsgLen);
    if (rc === 0) return null;
    if (rc !== 1) throw new PancakeError("pancake_peer_poll_event_abort", rc, this.#rt.lastError());
    const ptr = readPtrField(outMsgPtr);
    const len = Number(viewOf(outMsgLen).getBigUint64(0, true));
    const message = decodeUtf8(readBytes(ptr, len));
    this.#rt.sym.pancake_typed_abort_message_free(ptr, BigInt(len));
    return { reasonKind: viewOf(outKind).getUint32(0, true), message };
  }

  pollEventSessionEstablished(): SessionEstablishedEvent | null {
    const pubkey = allocBuf(32);
    const outLocPtr = allocBuf(8);
    const outLocLen = allocBuf(8);
    const rc = this.#rt.sym.pancake_peer_poll_event_session_established(
      this.#ptr,
      pubkey,
      outLocPtr,
      outLocLen,
    );
    if (rc === 0) return null;
    if (rc !== 1) {
      throw new PancakeError(
        "pancake_peer_poll_event_session_established",
        rc,
        this.#rt.lastError(),
      );
    }
    const ptr = readPtrField(outLocPtr);
    const len = Number(viewOf(outLocLen).getBigUint64(0, true));
    const partnerLocator = decodeUtf8(readBytes(ptr, len));
    this.#rt.sym.pancake_typed_partner_locator_free(ptr, BigInt(len));
    return { partnerPubkey: pubkey, partnerLocator };
  }

  free(): void {
    if (this.#freed) return;
    this.#freed = true;
    this.#rt.sym.pancake_peer_free(this.#ptr);
  }
}

// ─── Library metadata ──────────────────────────────────────────────

export function version(rt: Runtime): string {
  return readCString(rt.sym.pancake_version() as Ptr);
}

// ─── Ed25519 keypair ───────────────────────────────────────────────

export function keypairNew(rt: Runtime): Ptr {
  const kp = rt.sym.pancake_keypair_new() as Ptr;
  if (isNull(kp)) throw new PancakeError("pancake_keypair_new", -1, rt.lastError());
  return kp;
}

export function keypairFromSeed(rt: Runtime, seed: Uint8Array): Ptr {
  if (seed.length !== 32) throw new Error(`seed must be 32 bytes; got ${seed.length}`);
  const kp = rt.sym.pancake_keypair_from_seed(asBuf(seed), 32n) as Ptr;
  if (isNull(kp)) throw new PancakeError("pancake_keypair_from_seed", -1, rt.lastError());
  return kp;
}

export function keypairFree(rt: Runtime, kp: Ptr): void {
  rt.sym.pancake_keypair_free(kp);
}

export function keypairPubkey(rt: Runtime, kp: Ptr): Uint8Array {
  const out = allocBuf(32);
  const rc = rt.sym.pancake_keypair_pubkey(kp, out);
  if (rc !== PANCAKE_OK) throw new PancakeError("pancake_keypair_pubkey", rc, rt.lastError());
  return out;
}

// ─── OCapN URI parser ──────────────────────────────────────────────

export interface OcapnUri {
  transport: string;
  designator: string;
  swissnum: Uint8Array | null;
}

export function parseOcapnUri(rt: Runtime, uri: string): OcapnUri {
  const ptr = rt.sym.pancake_ocapn_uri_parse(cstr(uri)) as Ptr;
  if (isNull(ptr)) throw new PancakeError("pancake_ocapn_uri_parse", -1, rt.lastError());
  try {
    const view = new Deno.UnsafePointerView(ptr);
    const transport = readCString(view.getPointer(0));
    const designator = readCString(view.getPointer(8));
    const swissPtr = view.getPointer(16);
    const swissLen = Number(view.getBigUint64(24));
    const swissnum = swissPtr === null || swissLen === 0 ? null : readBytes(swissPtr, swissLen);
    return { transport, designator, swissnum };
  } finally {
    rt.sym.pancake_ocapn_uri_free(ptr);
  }
}

// ─── Syrup frame probe ─────────────────────────────────────────────

export function syrupFrameProbe(
  rt: Runtime,
  buf: Uint8Array,
  maxFrameBytes = 16 << 20,
): FrameProbe {
  const outEnd = allocBuf(8);
  const rc = rt.sym.pancake_syrup_frame_probe(
    asBuf(buf),
    BigInt(buf.length),
    outEnd,
    BigInt(maxFrameBytes),
  );
  switch (rc) {
    case PANCAKE_FRAME_COMPLETE:
      return { status: "complete", end: Number(viewOf(outEnd).getBigUint64(0, true)) };
    case PANCAKE_FRAME_INCOMPLETE:
      return { status: "incomplete", end: 0 };
    case PANCAKE_FRAME_MALFORMED:
      return { status: "malformed", end: 0 };
    default:
      throw new PancakeError("pancake_syrup_frame_probe", rc, rt.lastError());
  }
}

// ─── Cross-peer coordination ───────────────────────────────────────

/** A shared sturdyref-dedup table (one per host "runtime"). */
export class SturdyrefDedup {
  #rt: Runtime;
  #ptr: Ptr;
  #freed = false;
  private constructor(rt: Runtime, ptr: Ptr) {
    this.#rt = rt;
    this.#ptr = ptr;
  }
  static create(rt: Runtime): SturdyrefDedup {
    const ptr = rt.sym.pancake_sturdyref_dedup_new() as Ptr;
    if (isNull(ptr)) throw new PancakeError("pancake_sturdyref_dedup_new", -1, rt.lastError());
    return new SturdyrefDedup(rt, ptr);
  }
  absorbPending(peer: Peer): number {
    return this.#rt.sym.pancake_cross_peer_absorb_pending_sturdyref_enlivens(
      this.#ptr,
      peer.handle,
    );
  }
  cacheSettled(peer: Peer): number {
    return this.#rt.sym.pancake_cross_peer_cache_settled_sturdyref_enlivens(this.#ptr, peer.handle);
  }
  free(): void {
    if (this.#freed) return;
    this.#freed = true;
    this.#rt.sym.pancake_sturdyref_dedup_free(this.#ptr);
  }
}

export function drainRelayedResolutions(rt: Runtime, peer: Peer): number {
  return rt.sym.pancake_cross_peer_drain_relayed_resolutions(peer.handle);
}
