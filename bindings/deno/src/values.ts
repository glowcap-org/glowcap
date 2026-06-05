/**
 * values.ts — the codec-neutral typed-value model + fixed-size
 * tagged-union marshalling.
 *
 * These TypeScript discriminated unions mirror the C tagged unions
 * (`PancakeReference`, `PancakeArgument`, `PancakeResolution`). The
 * marshalling writes the LP64 byte layout the C ABI expects; the
 * projection reads it back. Layout offsets live in `constants.ts`.
 *
 * Send side: `marshal*` builds a struct buffer + pins every leaf
 * (peer-id / swissnum / symbol / string / nested array) in the arena
 * so its pointer stays valid for the FFI call. pancake copies every
 * leaf on push (recursive copy-on-push), so the arena is discardable
 * once the call returns.
 *
 * Receive side: `project*` reads from a `Deno.UnsafePointerView` over
 * either a caller-owned out-buffer or a Rust-allocated array; the
 * caller is responsible for the matching `pancake_typed_*_free`.
 */

import {
  allocBuf,
  Arena,
  type Buf,
  decodeUtf8,
  readBytes,
  utf8,
  viewOf,
  writePtr,
} from "./ffi/abi.ts";
import {
  ARGUMENT_SIZE,
  PANCAKE_ARG_BOOL,
  PANCAKE_ARG_BYTES,
  PANCAKE_ARG_INTEGER,
  PANCAKE_ARG_LIST,
  PANCAKE_ARG_REFERENCE,
  PANCAKE_ARG_STRING,
  PANCAKE_ARG_SYMBOL,
  PANCAKE_ARG_VOID,
  PANCAKE_REF_BROKEN,
  PANCAKE_REF_FAR,
  PANCAKE_REF_NEAR,
  PANCAKE_REF_PROMISE,
  PANCAKE_REF_STURDY,
  PANCAKE_RES_BREAK,
  PANCAKE_RES_FULFILL,
  PAYLOAD_OFFSET,
  REFERENCE_SIZE,
  RESOLUTION_SIZE,
} from "./constants.ts";

// ─── Model ─────────────────────────────────────────────────────────

export type Reference =
  | { kind: "near"; exportId: bigint }
  | { kind: "far"; peerId: Uint8Array; importId: bigint }
  | { kind: "promise"; answerId: bigint; pipelinePathLen: number }
  | { kind: "sturdy"; peerId: Uint8Array | null; swissnum: Uint8Array }
  | { kind: "broken"; reason: string };

export type Argument =
  | { kind: "symbol"; value: string }
  | { kind: "bytes"; value: Uint8Array }
  | { kind: "reference"; value: Reference }
  | { kind: "integer"; value: bigint }
  | { kind: "bool"; value: boolean }
  | { kind: "string"; value: string }
  | { kind: "void" }
  | { kind: "list"; items: Argument[] };

export type Resolution =
  | { kind: "fulfill"; value: Argument }
  | { kind: "break"; reason: string };

// ─── Builders ──────────────────────────────────────────────────────

export const refNear = (exportId: bigint | number): Reference => ({
  kind: "near",
  exportId: BigInt(exportId),
});
export const refFar = (peerId: Uint8Array, importId: bigint | number): Reference => {
  if (peerId.length !== 32) throw new Error(`far peerId must be 32 bytes; got ${peerId.length}`);
  return { kind: "far", peerId, importId: BigInt(importId) };
};
export const refSturdy = (peerId: Uint8Array | null, swissnum: Uint8Array): Reference => ({
  kind: "sturdy",
  peerId,
  swissnum,
});

export const argSymbol = (value: string): Argument => ({ kind: "symbol", value });
export const argBytes = (value: Uint8Array): Argument => ({ kind: "bytes", value });
export const argReference = (value: Reference): Argument => ({ kind: "reference", value });
export const argInteger = (value: bigint | number): Argument => ({
  kind: "integer",
  value: BigInt(value),
});
export const argBool = (value: boolean): Argument => ({ kind: "bool", value });
export const argString = (value: string): Argument => ({ kind: "string", value });
export const argVoid = (): Argument => ({ kind: "void" });
export const argList = (items: Argument[]): Argument => ({ kind: "list", items });

export const resFulfill = (value: Argument): Resolution => ({ kind: "fulfill", value });
export const resBreak = (reason: string): Resolution => ({ kind: "break", reason });

// ─── Send-side marshalling ─────────────────────────────────────────

function pinBytes(arena: Arena, src: Uint8Array): { ptr: Deno.PointerValue; len: number } {
  if (src.length === 0) return { ptr: null, len: 0 };
  const copy = allocBuf(src.length);
  copy.set(src);
  return { ptr: arena.pin(copy), len: src.length };
}

/** Marshal a `Reference` into a `REFERENCE_SIZE`-byte struct buffer. */
export function marshalReference(arena: Arena, ref: Reference): Buf {
  const buf = allocBuf(REFERENCE_SIZE);
  const dv = viewOf(buf);
  const p = PAYLOAD_OFFSET;
  switch (ref.kind) {
    case "near": {
      dv.setUint32(0, PANCAKE_REF_NEAR, true);
      dv.setBigUint64(p, ref.exportId, true);
      break;
    }
    case "far": {
      dv.setUint32(0, PANCAKE_REF_FAR, true);
      const { ptr, len } = pinBytes(arena, ref.peerId);
      writePtr(dv, p, ptr);
      dv.setBigUint64(p + 8, BigInt(len), true);
      dv.setBigUint64(p + 16, ref.importId, true);
      break;
    }
    case "sturdy": {
      dv.setUint32(0, PANCAKE_REF_STURDY, true);
      if (ref.peerId && ref.peerId.length === 32) {
        const { ptr } = pinBytes(arena, ref.peerId);
        writePtr(dv, p, ptr);
        dv.setBigUint64(p + 8, 32n, true);
      } else {
        writePtr(dv, p, null);
        dv.setBigUint64(p + 8, 0n, true);
      }
      const { ptr: sptr, len: slen } = pinBytes(arena, ref.swissnum);
      writePtr(dv, p + 16, sptr);
      dv.setBigUint64(p + 24, BigInt(slen), true);
      break;
    }
    default:
      throw new Error(
        `reference kind "${(ref as Reference).kind}" is receive-only on the send side`,
      );
  }
  return buf;
}

/** Marshal an `Argument` into an `ARGUMENT_SIZE`-byte struct buffer. */
export function marshalArgument(arena: Arena, arg: Argument): Buf {
  const buf = allocBuf(ARGUMENT_SIZE);
  const dv = viewOf(buf);
  const p = PAYLOAD_OFFSET;
  switch (arg.kind) {
    case "symbol":
    case "string": {
      dv.setUint32(0, arg.kind === "symbol" ? PANCAKE_ARG_SYMBOL : PANCAKE_ARG_STRING, true);
      const { ptr, len } = pinBytes(arena, utf8(arg.value));
      writePtr(dv, p, ptr);
      dv.setBigUint64(p + 8, BigInt(len), true);
      break;
    }
    case "bytes": {
      dv.setUint32(0, PANCAKE_ARG_BYTES, true);
      const { ptr, len } = pinBytes(arena, arg.value);
      writePtr(dv, p, ptr);
      dv.setBigUint64(p + 8, BigInt(len), true);
      break;
    }
    case "reference": {
      dv.setUint32(0, PANCAKE_ARG_REFERENCE, true);
      // Embed the full PancakeReference by value at the payload offset.
      buf.set(marshalReference(arena, arg.value), p);
      break;
    }
    case "integer": {
      dv.setUint32(0, PANCAKE_ARG_INTEGER, true);
      dv.setBigInt64(p, arg.value, true);
      break;
    }
    case "bool": {
      dv.setUint32(0, PANCAKE_ARG_BOOL, true);
      dv.setUint8(p, arg.value ? 1 : 0);
      break;
    }
    case "void": {
      dv.setUint32(0, PANCAKE_ARG_VOID, true);
      break;
    }
    case "list": {
      dv.setUint32(0, PANCAKE_ARG_LIST, true);
      const { ptr, count } = marshalArgumentArray(arena, arg.items);
      writePtr(dv, p, ptr);
      dv.setBigUint64(p + 8, BigInt(count), true);
      break;
    }
  }
  return buf;
}

/** Marshal an array of `Argument`s into one contiguous pinned buffer. */
export function marshalArgumentArray(
  arena: Arena,
  args: Argument[],
): { ptr: Deno.PointerValue; count: number } {
  if (args.length === 0) return { ptr: null, count: 0 };
  const arr = allocBuf(args.length * ARGUMENT_SIZE);
  for (let i = 0; i < args.length; i++) {
    arr.set(marshalArgument(arena, args[i]), i * ARGUMENT_SIZE);
  }
  return { ptr: arena.pin(arr), count: args.length };
}

/** Marshal a `Resolution` into a `RESOLUTION_SIZE`-byte struct buffer. */
export function marshalResolution(arena: Arena, res: Resolution): Buf {
  const buf = allocBuf(RESOLUTION_SIZE);
  const dv = viewOf(buf);
  const p = PAYLOAD_OFFSET;
  switch (res.kind) {
    case "fulfill": {
      dv.setUint32(0, PANCAKE_RES_FULFILL, true);
      buf.set(marshalArgument(arena, res.value), p);
      break;
    }
    case "break": {
      dv.setUint32(0, PANCAKE_RES_BREAK, true);
      const { ptr, len } = pinBytes(arena, utf8(res.reason));
      writePtr(dv, p, ptr);
      dv.setBigUint64(p + 8, BigInt(len), true);
      break;
    }
  }
  return buf;
}

// ─── Receive-side projection ───────────────────────────────────────

function followBytes(view: Deno.UnsafePointerView, off: number): Uint8Array {
  const ptr = view.getPointer(off);
  const len = Number(view.getBigUint64(off + 8));
  return readBytes(ptr, len);
}

export function projectReference(view: Deno.UnsafePointerView, base: number): Reference {
  const kind = view.getUint32(base);
  const p = base + PAYLOAD_OFFSET;
  switch (kind) {
    case PANCAKE_REF_NEAR:
      return { kind: "near", exportId: view.getBigUint64(p) };
    case PANCAKE_REF_FAR: {
      const peerId = followBytes(view, p);
      const importId = view.getBigUint64(p + 16);
      return { kind: "far", peerId, importId };
    }
    case PANCAKE_REF_PROMISE:
      return {
        kind: "promise",
        answerId: view.getBigUint64(p),
        pipelinePathLen: Number(view.getBigUint64(p + 8)),
      };
    case PANCAKE_REF_STURDY: {
      const peerLen = Number(view.getBigUint64(p + 8));
      const peerId = peerLen === 0 ? null : readBytes(view.getPointer(p), peerLen);
      const swissnum = readBytes(view.getPointer(p + 16), Number(view.getBigUint64(p + 24)));
      return { kind: "sturdy", peerId, swissnum };
    }
    case PANCAKE_REF_BROKEN:
      return { kind: "broken", reason: decodeUtf8(followBytes(view, p)) };
    default:
      throw new Error(`projectReference: unknown kind ${kind}`);
  }
}

export function projectArgument(view: Deno.UnsafePointerView, base: number): Argument {
  const kind = view.getUint32(base);
  const p = base + PAYLOAD_OFFSET;
  switch (kind) {
    case PANCAKE_ARG_SYMBOL:
      return { kind: "symbol", value: decodeUtf8(followBytes(view, p)) };
    case PANCAKE_ARG_BYTES:
      return { kind: "bytes", value: followBytes(view, p) };
    case PANCAKE_ARG_REFERENCE:
      return { kind: "reference", value: projectReference(view, p) };
    case PANCAKE_ARG_INTEGER:
      return { kind: "integer", value: view.getBigInt64(p) };
    case PANCAKE_ARG_BOOL:
      return { kind: "bool", value: view.getUint8(p) !== 0 };
    case PANCAKE_ARG_STRING:
      return { kind: "string", value: decodeUtf8(followBytes(view, p)) };
    case PANCAKE_ARG_VOID:
      return { kind: "void" };
    case PANCAKE_ARG_LIST: {
      const itemsPtr = view.getPointer(p);
      const count = Number(view.getBigUint64(p + 8));
      if (count === 0 || itemsPtr === null) return { kind: "list", items: [] };
      const itemsView = new Deno.UnsafePointerView(itemsPtr);
      const items: Argument[] = [];
      for (let i = 0; i < count; i++) {
        items.push(projectArgument(itemsView, i * ARGUMENT_SIZE));
      }
      return { kind: "list", items };
    }
    default:
      throw new Error(`projectArgument: unknown kind ${kind}`);
  }
}

export function projectResolution(view: Deno.UnsafePointerView, base: number): Resolution {
  const kind = view.getUint32(base);
  const p = base + PAYLOAD_OFFSET;
  switch (kind) {
    case PANCAKE_RES_FULFILL:
      return { kind: "fulfill", value: projectArgument(view, p) };
    case PANCAKE_RES_BREAK:
      return { kind: "break", reason: decodeUtf8(followBytes(view, p)) };
    default:
      throw new Error(`projectResolution: unknown kind ${kind}`);
  }
}
