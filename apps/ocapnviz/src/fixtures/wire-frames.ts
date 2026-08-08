/**
 * The wire frames the built-in recordings carry.
 *
 * Every entry below is a real pancake encoding, read byte for byte
 * out of a file this repository commits and checks. Nothing here is
 * hand-written to look like a frame: `wire-frames.test.ts` reads each
 * `source` file off disk and fails if a single byte drifts, which is
 * what keeps the Inspector's payload viewer showing protocol rather
 * than decoration.
 *
 * The two corpora these come from:
 *
 * - `test/oracle/corpus/*.bin` are Syrup frames. pancake builds the
 *   record for a message arm and the upstream Racket Syrup encoder
 *   serializes it, so the bytes are not pancake's own opinion of
 *   Syrup. `zig build fixture-gen-check` regenerates and compares
 *   them.
 * - `test/codec/capnp_fixtures/*.bin` are Cap'n Proto frames written
 *   by `zig build gen-capnp-fixtures` and locked byte for byte by
 *   `test/codec/capnp_golden_test.zig`.
 *
 * ## Which message gets a frame
 *
 * A recording is authored, so its peers, timings, and positions are
 * invented. Its payloads are not allowed to be. A frame is attached
 * to a message only when the frame encodes that message's arm and
 * nothing the message's label states is contradicted by the bytes.
 * So a message labelled `op:deliver deposit-gift` carries the
 * deliver whose arguments begin with that very symbol. One labelled
 * `op:deliver queue('Hot Knife')` carries nothing, because no
 * committed frame calls that verb, and a reader who switched the
 * viewer to UTF-8 would catch us at it. A message with no truthful
 * frame available carries none, and the Inspector says so.
 */

import type { Codec } from "../schema/topology.ts";

/** One committed frame, ready to hang on a `message-sent` event. */
export interface WireFrame {
  /** Repository-relative path of the file these bytes were read
   *  from. It travels onto the event as `prov:wasDerivedFrom`, and
   *  the test reads that same path back. */
  readonly source: string;
  /** The codec that produced the frame. A fact about the bytes, and
   *  not always the codec of the session carrying them: every
   *  `op:start-session` is Syrup whatever the session goes on to
   *  speak (ADR-0103). */
  readonly codec: Codec;
  /** The frame, base64. The length is not stated beside it: the
   *  bytes already say it, and a second spelling of one fact is a
   *  spelling that can drift. */
  readonly bytesB64: string;
}

/**
 * Every frame the recordings may draw on. One record, so the byte
 * check below walks exactly what the fixtures can reach: a frame
 * declared beside a hand-kept list is a frame the check can silently
 * skip, which is the one hole this module exists to close.
 */
export const wireFrames = {
  /**
   * The keyed `op:start-session` hello. Its version field reads
   * `"1.0"`, the baseline every OCapN implementation speaks, and it
   * reads that on a `pancake-next` session as much as a v1.0 one. A
   * peer states the profile it prefers in the hints of the locator
   * this hello carries, never in the version field (ADR-0103).
   */
  startSession: {
    source: "test/oracle/corpus/op_start_session_v1_0.bin",
    codec: "syrup",
    bytesB64:
      "PDE2J29wOnN0YXJ0LXNlc3Npb24zIjEuMFsxMCdwdWJsaWMta2V5WzMnZWNjWzUnY3VydmU3J0VkMjU1MTldWzUnZmxhZ3M1J2VkZHNhXVsxJ3EzMjqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqql1dXTwxMCdvY2Fwbi1wZWVyNidtZW1vcnk4ImV4cG9ydGVye30+Wzcnc2lnLXZhbFs1J2VkZHNhWzEncjMyOszMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMXVsxJ3MzMjrMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzF1dXT4=",
  },

  /** A signed `desc:handoff-give`, the gifter's introduction: a
   *  `desc:sig-envelope` wrapping the give and its Ed25519
   *  signature. */
  handoffGive: {
    source: "test/oracle/corpus/desc_handoff_give_signed.bin",
    codec: "syrup",
    bytesB64:
      "PDE3J2Rlc2M6c2lnLWVudmVsb3BlPDE3J2Rlc2M6aGFuZG9mZi1naXZlWzEwJ3B1YmxpYy1rZXlbMydlY2NbNSdjdXJ2ZTcnRWQyNTUxOV1bNSdmbGFnczUnZWRkc2FdWzEncTMyOkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCXV1dPDEwJ29jYXBuLXBlZXI2J21lbW9yeTgiZXhwb3J0ZXJ7fT4zMjrMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzDMyOhERERERERERERERERERERERERERERERERERERERERERMzI6AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE+Wzcnc2lnLXZhbFs1J2VkZHNhWzEncjMyOqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqXVsxJ3MzMjqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqql1dXT4=",
  },

  /** A signed `desc:handoff-receive`: the recipient's claim, which
   *  quotes the gifter's whole signed give inside its own
   *  envelope. */
  handoffReceive: {
    source: "test/oracle/corpus/desc_handoff_receive_signed.bin",
    codec: "syrup",
    bytesB64:
      "PDE3J2Rlc2M6c2lnLWVudmVsb3BlPDIwJ2Rlc2M6aGFuZG9mZi1yZWNlaXZlMzI63d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d0zMjoiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIjErPDE3J2Rlc2M6c2lnLWVudmVsb3BlPDE3J2Rlc2M6aGFuZG9mZi1naXZlWzEwJ3B1YmxpYy1rZXlbMydlY2NbNSdjdXJ2ZTcnRWQyNTUxOV1bNSdmbGFnczUnZWRkc2FdWzEncTMyOkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCXV1dPDEwJ29jYXBuLXBlZXI2J21lbW9yeTgiZXhwb3J0ZXJ7fT4zMjrMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzDMyOhERERERERERERERERERERERERERERERERERERERERERMzI6AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE+Wzcnc2lnLXZhbFs1J2VkZHNhWzEncjMyOqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqXVsxJ3MzMjqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqql1dXT4+Wzcnc2lnLXZhbFs1J2VkZHNhWzEncjMyOru7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7XVsxJ3MzMjq7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u11dXT4=",
  },

  /** An `op:resolve` fulfilling an answer with a far reference. */
  resolveFulfillFar: {
    source: "test/oracle/corpus/op_resolve_fulfill_far.bin",
    codec: "syrup",
    bytesB64:
      "PDEwJ29wOnJlc29sdmU3KzwxNSdyZXNvbHZlOmZ1bGZpbGw8MTEnZGVzYzpleHBvcnQ1Kz4+Pg==",
  },

  /** An `op:gc-exports` dropping two export positions, with the
   *  parallel wire-delta list beside them. Thirty bytes, which is
   *  most of what there is to say about it.
   *
   *  Its Cap'n Proto twin sits below. The same arm in both codecs is
   *  the pair a recording draws on to stay truthful: a frame's codec
   *  is a fact about its bytes, so a session speaking Cap'n Proto
   *  cannot carry the Syrup one. */
  gcExportsSyrup: {
    source: "test/oracle/corpus/op_gc_exports.bin",
    codec: "syrup",
    bytesB64: "PDEzJ29wOmdjLWV4cG9ydHNbMys3K11bMSsyK10+",
  },

  /** The same `op:gc-exports` arm in Cap'n Proto: two export
   *  positions and their wire deltas, laid out as the 64-bit words
   *  the hex dump groups by. */
  gcExportsCapnp: {
    source: "test/codec/capnp_fixtures/op_gc_export.bin",
    codec: "capnp",
    bytesB64:
      "AAAAAAkAAAAAAAAAAQABAAIAAAAAAAAAAAAAAAAAAgAFAAAAFQAAAAkAAAAVAAAAAgAAAAAAAAADAAAAAAAAAAEAAAAAAAAAAQAAAAAAAAA=",
  },

  /** A v1.0 `op:deliver` carrying a `resolve_me_desc`: the trailing
   *  `<desc:import-object 99>` is the resolver the caller wants its
   *  answer delivered to. */
  deliverWithResolveMeDesc: {
    source: "test/oracle/corpus/op_deliver_v1_0_with_resolve_me_desc.bin",
    codec: "syrup",
    bytesB64:
      "PDEwJ29wOmRlbGl2ZXI8MTEnZGVzYzpleHBvcnQ3Kz5bNTpoZWxsb100Mis8MTgnZGVzYzppbXBvcnQtb2JqZWN0OTkrPj4=",
  },

  /** The gifter's `deposit-gift` deliver, in Cap'n Proto. This is
   *  the frame the payload viewer's word grouping was built for: the
   *  segment table, the root struct pointer, and the argument list
   *  all land on 64-bit boundaries the dump makes visible. */
  depositGift: {
    source: "test/codec/capnp_fixtures/op_deliver_deposit_gift.bin",
    codec: "capnp",
    bytesB64:
      "AAAAAB0AAAAAAAAAAQABAAAAAAAAAAAAAAAAAAIAAwAAAAAAAAAAAAAAAAAAAAAACAAAAAIAAgAVAAAATwAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMAAAAAgABAAEAAAAAAAAAAAAAAAAAAAAZAAAAYgAAAAAAAAAAAAAAAAAAAAAAAAAVAAAAMgAAAAIAAAAAAAAAAAAAAAAAAAAMAAAAAgACAGRlcG9zaXQtZ2lmdAAAAABnaWZ0LTEAAAEAAAAAAAAABQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  },
} as const satisfies Record<string, WireFrame>;

/** The frames as a list, derived rather than restated. */
export const allWireFrames: readonly WireFrame[] = Object.values(wireFrames);

/**
 * The fields a `message-sent` event needs to carry `frame`: the
 * bytes, the codec that produced them, and a provenance record
 * naming the file they were read from. `agent` is the fixture's own
 * attribution, which the event carries either way; a payload only
 * adds where its bytes came from.
 */
export function payloadOf(frame: WireFrame, agent: string) {
  return {
    bytesB64: frame.bytesB64,
    bytesCodec: frame.codec,
    provenance: {
      "prov:wasAttributedTo": agent,
      "prov:wasDerivedFrom": [frame.source],
    },
  };
}
