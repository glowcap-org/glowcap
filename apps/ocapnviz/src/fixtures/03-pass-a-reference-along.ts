import { TimelineDocument } from "../engine/timeline.ts";
import { payloadOf, wireFrames } from "./wire-frames.ts";

/**
 * Chapter 03 — Pass a reference along.
 *
 * The laptop calls `print(document)` on the printer, handing the document
 * reference itself across as an argument. The printer reads the document
 * directly by capability, and the laptop never touches the bytes.
 *
 * On the wire: the laptop is at `127.0.0.1:9301` and the printer at
 * `127.0.0.1:9302`, over plain `tcp`, and each end carries what backed
 * it — the laptop's own report, and for the printer the two hosts'
 * traces agreeing on one OCapN Session ID.
 * Both peers run pancake, so this session settles on Cap'n Proto over
 * pancake-next. That is the pairing a pancake fleet configures
 * (`HostRuntime.Options.codec` / `.captp_version` in `src/driver/host_runtime.zig`); the
 * Syrup / OCapN 1.0 baseline is what a session settles on the moment a peer
 * at either end cannot follow.
 */

const AGENT = "ocapnviz:fixtures/03-pass-a-reference-along";

export const passAReferenceAlong = TimelineDocument.parse({
  id: "03-pass-a-reference-along",
  metadata: {
    "dct:title": "03 · Pass a reference along",
    "dct:description":
      "A client calls print on a printer and hands over the document as the argument. The document is itself a capability, so the printer reads it directly and the client never sends the bytes. One object, and a different name for it on each side of the session.",
    "dct:creator": "pancake project",
    "dct:created": "2026-05-14T00:00:00Z",
  },
  provenance: { "prov:wasAttributedTo": AGENT },
  duration: 3500,
  events: [
    {
      id: "client-joins",
      t: 0,
      kind: "peer-joined",
      peerId: "127.0.0.1:9301",
      label: "Laptop",
      profile: "pancake",
      designator: "127.0.0.1:9301",
    },
    {
      id: "server-joins",
      t: 0,
      kind: "peer-joined",
      peerId: "127.0.0.1:9302",
      label: "Printer",
      profile: "pancake",
      designator: "127.0.0.1:9302",
    },
    {
      id: "session-opens",
      t: 0,
      kind: "session-opened",
      sessionId: "56c2a18a27f28c73752ae2e92af7a73c5429d58117f16d808f8abf97ddb246b2",
      a: {
        peer: "127.0.0.1:9301",
        designator: "127.0.0.1:9301",
        attributedBy: "self-reported",
      },
      b: {
        peer: "127.0.0.1:9302",
        designator: "127.0.0.1:9302",
        attributedBy: "viewer-correlated",
      },
      transport: "tcp",
      codec: "capnp",
      captpVersion: "next",
      initialState: "negotiating",
    },
    {
      id: "ss-out",
      t: 200,
      kind: "message-sent",
      messageId: "ss-out",
      sessionId: "56c2a18a27f28c73752ae2e92af7a73c5429d58117f16d808f8abf97ddb246b2",
      from: "127.0.0.1:9301",
      to: "127.0.0.1:9302",
      arrivalT: 400,
      label: "op:start-session",
      ...payloadOf(wireFrames.startSession, AGENT),
    },
    {
      id: "ss-out-d",
      t: 400,
      kind: "message-delivered",
      messageId: "ss-out",
    },
    {
      id: "ss-back",
      t: 500,
      kind: "message-sent",
      messageId: "ss-back",
      sessionId: "56c2a18a27f28c73752ae2e92af7a73c5429d58117f16d808f8abf97ddb246b2",
      from: "127.0.0.1:9302",
      to: "127.0.0.1:9301",
      arrivalT: 700,
      label: "op:start-session",
      ...payloadOf(wireFrames.startSession, AGENT),
    },
    {
      id: "ss-back-d",
      t: 700,
      kind: "message-delivered",
      messageId: "ss-back",
    },
    {
      id: "session-open",
      t: 700,
      kind: "session-state-changed",
      sessionId: "56c2a18a27f28c73752ae2e92af7a73c5429d58117f16d808f8abf97ddb246b2",
      state: "open",
    },
    {
      id: "print-call",
      t: 1100,
      kind: "message-sent",
      messageId: "print-call",
      sessionId: "56c2a18a27f28c73752ae2e92af7a73c5429d58117f16d808f8abf97ddb246b2",
      from: "127.0.0.1:9301",
      to: "127.0.0.1:9302",
      arrivalT: 1500,
      label: "op:deliver printer.print(document)",
    },
    {
      id: "print-call-d",
      t: 1500,
      kind: "message-delivered",
      messageId: "print-call",
    },
    {
      id: "print-resolve",
      t: 1900,
      kind: "message-sent",
      messageId: "print-resolve",
      sessionId: "56c2a18a27f28c73752ae2e92af7a73c5429d58117f16d808f8abf97ddb246b2",
      from: "127.0.0.1:9302",
      to: "127.0.0.1:9301",
      arrivalT: 2300,
      label: "op:resolve fulfill(receipt)",
    },
    {
      id: "print-resolve-d",
      t: 2300,
      kind: "message-delivered",
      messageId: "print-resolve",
    },
    {
      id: "gc",
      t: 2700,
      kind: "message-sent",
      messageId: "gc",
      sessionId: "56c2a18a27f28c73752ae2e92af7a73c5429d58117f16d808f8abf97ddb246b2",
      from: "127.0.0.1:9301",
      to: "127.0.0.1:9302",
      arrivalT: 3000,
      label: "op:gc-exports",
      ...payloadOf(wireFrames.gcExportsCapnp, AGENT),
    },
    {
      id: "gc-d",
      t: 3000,
      kind: "message-delivered",
      messageId: "gc",
    },
  ],
});
