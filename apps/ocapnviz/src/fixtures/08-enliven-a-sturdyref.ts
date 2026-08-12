import { TimelineDocument } from "../engine/timeline.ts";
import { payloadOf, wireFrames } from "./wire-frames.ts";

/**
 * Chapter 08 — Enlivening a sturdyref.
 *
 * The client holds a sturdyref to something in the archive server: opaque
 * authority bytes plus a peer locator. Nothing can be delivered to it until
 * the client enlivens it, which turns the sturdyref into a far reference
 * bound to a live session by way of one bootstrap fetch. Once the archive
 * answers with that reference, the client can call through it.
 *
 * Enlivening the same sturdyref again costs nothing on the wire: the session
 * remembers the reference it already got and hands back the same one.
 *
 * On the wire: a sturdyref is only worth writing down if the peer it names
 * can be recognized again later, so this pair runs over `iroh`, whose
 * designator is the remote node id. That id is a key, and dialing it is what
 * proves who answered. Each peer is identified by that key, and the friendly
 * name beside it is a label the picture shows in its place. The client's end
 * is its own report; the archive's end is attached because the QUIC
 * connection proved the far side holds the key the locator named, which is
 * what makes the sturdyref worth keeping across a restart.
 *
 * A keyed cleartext netlayer would not do here. `keyed-tcp` demands the
 * dialed key and refuses a peer that claims another, but nothing proves the
 * claim, so the identity a sturdyref rests on would be one anybody on the
 * path could answer for. The Reference's transport section says which
 * netlayers prove a peer and which only address one.
 * Both peers run pancake, so this session settles on Cap'n Proto over
 * pancake-next. That is the pairing a pancake fleet configures
 * (`HostRuntime.Options.codec` / `.captp_version` in `src/driver/host_runtime.zig`); the
 * Syrup / OCapN 1.0 baseline is what a session settles on the moment a peer
 * at either end cannot follow.
 */

const AGENT = "ocapnviz:fixtures/08-enliven-a-sturdyref";

export const enlivenASturdyref = TimelineDocument.parse({
  id: "08-enliven-a-sturdyref",
  metadata: {
    "dct:title": "08 · Enliven a sturdyref",
    "dct:description":
      "A sturdyref is a capability you can write down: some authority bytes plus the locator of the peer holding it. Before sending to one you enliven it, which fetches a live reference over a session. Enlivening the same sturdyref a second time costs no round-trip, because the session already remembers the answer.",
    "dct:creator": "pancake project",
    "dct:created": "2026-05-14T00:00:00Z",
  },
  provenance: { "prov:wasAttributedTo": AGENT },
  duration: 4500,
  events: [
    {
      id: "a-joins",
      t: 0,
      kind: "peer-joined",
      peerId:
        "3c8f0b6e4a92d715086bf3c7e2a940d51b6c8e30f7a24d9b5e01c6a83f2d7b04",
      label: "Client",
      profile: "pancake",
      designator:
        "3c8f0b6e4a92d715086bf3c7e2a940d51b6c8e30f7a24d9b5e01c6a83f2d7b04",
    },
    {
      id: "b-joins",
      t: 0,
      kind: "peer-joined",
      peerId:
        "91d4a70c5e38b26f0a7d1c94e5b830f26a4c9d7e13850bf6a2c04e7d9b3f18ea",
      label: "Archive server",
      profile: "pancake",
      designator:
        "91d4a70c5e38b26f0a7d1c94e5b830f26a4c9d7e13850bf6a2c04e7d9b3f18ea",
    },
    {
      id: "session-opens",
      t: 0,
      kind: "session-opened",
      sessionId:
        "80053a30eeef4d931d6bdd2870b1b2f063765a3b9ec2eb64dd08d9aa00dfa760",
      a: {
        peer:
          "3c8f0b6e4a92d715086bf3c7e2a940d51b6c8e30f7a24d9b5e01c6a83f2d7b04",
        designator:
          "3c8f0b6e4a92d715086bf3c7e2a940d51b6c8e30f7a24d9b5e01c6a83f2d7b04",
        attributedBy: "self-reported",
      },
      b: {
        peer:
          "91d4a70c5e38b26f0a7d1c94e5b830f26a4c9d7e13850bf6a2c04e7d9b3f18ea",
        designator:
          "91d4a70c5e38b26f0a7d1c94e5b830f26a4c9d7e13850bf6a2c04e7d9b3f18ea",
        attributedBy: "authenticated-transport",
      },
      transport: "iroh",
      codec: "capnp",
      captpVersion: "next",
      initialState: "negotiating",
    },
    {
      id: "ss-out",
      t: 200,
      kind: "message-sent",
      messageId: "ss-out",
      sessionId:
        "80053a30eeef4d931d6bdd2870b1b2f063765a3b9ec2eb64dd08d9aa00dfa760",
      from: "3c8f0b6e4a92d715086bf3c7e2a940d51b6c8e30f7a24d9b5e01c6a83f2d7b04",
      to: "91d4a70c5e38b26f0a7d1c94e5b830f26a4c9d7e13850bf6a2c04e7d9b3f18ea",
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
      sessionId:
        "80053a30eeef4d931d6bdd2870b1b2f063765a3b9ec2eb64dd08d9aa00dfa760",
      from: "91d4a70c5e38b26f0a7d1c94e5b830f26a4c9d7e13850bf6a2c04e7d9b3f18ea",
      to: "3c8f0b6e4a92d715086bf3c7e2a940d51b6c8e30f7a24d9b5e01c6a83f2d7b04",
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
      sessionId:
        "80053a30eeef4d931d6bdd2870b1b2f063765a3b9ec2eb64dd08d9aa00dfa760",
      state: "open",
    },
    {
      id: "enliven-fetch",
      t: 1100,
      kind: "message-sent",
      messageId: "enliven-fetch",
      sessionId:
        "80053a30eeef4d931d6bdd2870b1b2f063765a3b9ec2eb64dd08d9aa00dfa760",
      from: "3c8f0b6e4a92d715086bf3c7e2a940d51b6c8e30f7a24d9b5e01c6a83f2d7b04",
      to: "91d4a70c5e38b26f0a7d1c94e5b830f26a4c9d7e13850bf6a2c04e7d9b3f18ea",
      arrivalT: 1500,
      label: "op:deliver bootstrap.fetch(SwissNum)  (enliven)",
    },
    {
      id: "enliven-fetch-d",
      t: 1500,
      kind: "message-delivered",
      messageId: "enliven-fetch",
    },
    {
      id: "enliven-resolve",
      t: 1800,
      kind: "message-sent",
      messageId: "enliven-resolve",
      sessionId:
        "80053a30eeef4d931d6bdd2870b1b2f063765a3b9ec2eb64dd08d9aa00dfa760",
      from: "91d4a70c5e38b26f0a7d1c94e5b830f26a4c9d7e13850bf6a2c04e7d9b3f18ea",
      to: "3c8f0b6e4a92d715086bf3c7e2a940d51b6c8e30f7a24d9b5e01c6a83f2d7b04",
      arrivalT: 2200,
      label: "op:resolve fulfill(Far(thermostat))",
    },
    {
      id: "enliven-resolve-d",
      t: 2200,
      kind: "message-delivered",
      messageId: "enliven-resolve",
    },
    {
      id: "set-target",
      t: 2600,
      kind: "message-sent",
      messageId: "set-target",
      sessionId:
        "80053a30eeef4d931d6bdd2870b1b2f063765a3b9ec2eb64dd08d9aa00dfa760",
      from: "3c8f0b6e4a92d715086bf3c7e2a940d51b6c8e30f7a24d9b5e01c6a83f2d7b04",
      to: "91d4a70c5e38b26f0a7d1c94e5b830f26a4c9d7e13850bf6a2c04e7d9b3f18ea",
      arrivalT: 3000,
      label: "op:deliver thermostat.setTarget(18)",
    },
    {
      id: "set-target-d",
      t: 3000,
      kind: "message-delivered",
      messageId: "set-target",
    },
    {
      id: "set-target-resolve",
      t: 3300,
      kind: "message-sent",
      messageId: "set-target-resolve",
      sessionId:
        "80053a30eeef4d931d6bdd2870b1b2f063765a3b9ec2eb64dd08d9aa00dfa760",
      from: "91d4a70c5e38b26f0a7d1c94e5b830f26a4c9d7e13850bf6a2c04e7d9b3f18ea",
      to: "3c8f0b6e4a92d715086bf3c7e2a940d51b6c8e30f7a24d9b5e01c6a83f2d7b04",
      arrivalT: 3700,
      label: "op:resolve fulfill(ok)",
    },
    {
      id: "set-target-resolve-d",
      t: 3700,
      kind: "message-delivered",
      messageId: "set-target-resolve",
    },
    // A repeat enliven would short-circuit (no wire round-trip).
    // Nothing on the wire — represented here by the absence of a
    // second fetch/resolve pair, keeping the visualization honest
    // about the dedup sidecar's behavior.
  ],
});
