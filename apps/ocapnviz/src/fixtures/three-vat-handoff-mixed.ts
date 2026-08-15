import { TimelineDocument } from "../engine/timeline.ts";
import { endpointStageId } from "../schema/topology.ts";
import { payloadOf, wireFrames } from "./wire-frames.ts";

/**
 * Three-vat handoff with mixed implementations — full flow.
 *
 * Authored at the event layer (primitive). The engine reconstructs
 * the world at any moment by folding events; snapshots are derived,
 * never authored.
 *
 * Cast, each with the OCapN Designator it answers to on the wire:
 * - Alice (Gifter)   — pancake, `127.0.0.1:9001`
 * - Bob   (Receiver) — Goblins, `127.0.0.1:9002`
 * - Carol (Exporter) — pancake, `127.0.0.1:9003`
 *
 * The hand-authored recording shows the per-session profile that a direct
 * connection reports rather than treating the network as one codec, and it
 * keeps the protocol
 * mechanics that always happen but are usually left out of one-line
 * narratives:
 *
 *   1. Three peers join. Two sessions exist immediately:
 *      Alice ↔ Carol (capnp / pancake-next — both pancake) and
 *      Alice ↔ Bob (syrup / OCapN 1.0 — the interop floor). Both
 *      start `negotiating`.
 *   2. `op:start-session` flows both ways for each session
 *      (handshake), then the session transitions to `open`.
 *   3. Alice deposits the gifted reference with Carol
 *      (`op:deliver deposit-gift`) over their Cap'n Proto session,
 *      so a later withdrawal has something to redeem. This is the
 *      one frame here that rides Cap'n Proto.
 *   4. Alice sends `desc:handoff-give` to Bob.
 *   5. Bob receives the gift, resolves the request back to Alice
 *      with `op:resolve`, and dials Carol (new session, syrup /
 *      OCapN 1.0 because Bob is Goblins-flavor — the recorded outcome on
 *      both the codec and CapTP-version axes). Carol accepts that
 *      dial over plain TCP. Her own end of the new session is
 *      hers, and the other end is only a claim: Bob's hello names
 *      the address he answers at, and nothing on the `tcp`
 *      netlayer ties that address to whoever is speaking.
 *   6. Bob ↔ Carol handshake (`op:start-session` both ways), then
 *      the state becomes `open`. The far end is still only a
 *      claim, because a handshake that proves nothing has proved
 *      nothing.
 *   7. Bob sends `desc:handoff-receive` to Carol. Alice signed the
 *      give inside it, naming the key Bob holds on his session with
 *      her, and Bob signed the receive with that same key. Carol
 *      checks both, and that is what finally says who is there: the
 *      moment the frame lands, Carol attaches that end to Bob.
 *   8. Carol resolves back to Bob with `op:resolve`. Done.
 *
 * `op:start-session` and `op:resolve` are modeled as
 * `message-sent` events with the appropriate `label` — the engine
 * doesn't need new event kinds. Promise resolution and the session
 * handshake are the two pieces of CapTP machinery that always fire
 * for any non-`deliver-only` send and any state transition; we
 * skip `op:gc-*` chatter because it's noise without information at
 * this layer.
 *
 * Every message here carries a real frame, taken from pancake's
 * committed corpora and named on the event so the Inspector can say
 * where the bytes came from. See `wire-frames.ts` for the rule about
 * which message may carry which frame.
 *
 * One of those frames teaches something the diagram cannot. The
 * Alice ↔ Carol session speaks Cap'n Proto, but its two handshake
 * frames are Syrup. Every `op:start-session` is the baseline in both
 * its grammar and its version field, whatever the session goes on to
 * speak; each peer states the profile it prefers in the hints of the
 * locator its hello carries (ADR-0103). Select a handshake message
 * and the payload viewer spaces it as bytes. Select the deposit and
 * it spaces the same session's traffic as the 64-bit words Cap'n
 * Proto is made of.
 *
 * The Bob ↔ Carol session teaches the other thing this scenario is
 * here for. A session's end carries what it claims to be and,
 * separately, whatever backed that claim. When nothing backed it the
 * end is attached to no peer, and the document says exactly that
 * rather than inventing someone to hold the claim. So between t=1900
 * and t=3500 that session runs from Carol to an end that is a
 * designator and nothing more.
 *
 * Watch where the stage puts it. The claim is `127.0.0.1:9002`, and
 * that is the address Bob is already drawn under, so the edge is
 * solved as if the end were on Bob and the end is placed most of the
 * way along it. The line runs from Carol and stops there, in open
 * space short of Bob and pointing at him — a wire that ends near
 * somebody without reaching them, which is what an unbacked claim
 * amounts to. Select the shape at the end of it and the Inspector says
 * the same thing in words, that a session runs here and nothing has
 * said who is on this end.
 *
 * Then at t=3500 the signed handoff-receive lands, Carol verifies it,
 * and the end attaches. The shape goes and the line lands on Bob.
 * Nothing was born and nothing died, and no peer moves: the edge was
 * already solved to Bob, so the picture only completes. The moment it
 * happened is the diamond on the session's row in the timeline, which
 * a reader can drag to see the claim hold for longer or shorter.
 * Select the session afterwards and the Inspector names what did the
 * backing, a verified handoff, in place of the warning it carried
 * while the end was loose.
 *
 * That word is chosen carefully, because a handoff proves a narrower
 * thing than it looks. Carol learns that whoever dialed her holds the
 * key Alice's give named. She learns nothing about the address in the
 * hello, and pancake's own handoff path never touches the durable
 * identity a session opened with, so a peer can redeem a gift over
 * plain `tcp` and remain a peer nothing has authenticated.
 *
 * What lets the picture put Bob on that end is the session above it.
 * The other two sessions are Alice's own reports, so her end of each
 * is her own report and the far end carries what actually backed its
 * claim: Carol publishes a trace of the same OCapN Session ID, which
 * is the weakest attribution here and the only viewer-side one. Bob
 * publishes no trace, and plain TCP does not authenticate his claimed
 * designator, so that end remains loose. The handoff later proves that
 * Carol reached the same session party Alice introduced; it does not
 * turn Bob's address claim into an authenticated durable identity.
 */

const AGENT = "ocapnviz:fixtures/three-vat-handoff-mixed";

/** The three OCapN Session IDs this recording carries, each 64 lowercase hex
 *  digits the way a real one is: both ends of a session derive the same value
 *  from their two public identifiers, so it is the string that tells one
 *  conversation watched twice from two unrelated ones.
 *
 *  Named rather than written at each use because the Bob-to-Carol id is said
 *  four times — once as the session's own, and three times through
 *  `endpointStageId` for the end nothing has attributed yet. A second
 *  spelling of it silently detaches those messages from their session. */
const SESSION = {
  aliceCarol: "ca93a0430b191ecd589f6238b626ede6cbe5d5723a7c4dc2cddf2c6a81cd7710",
  aliceBob: "92f686b09614fa7214a0dbb5c66940b5e18df528ee2818be520a992d8afe75c5",
  bobCarol: "07f7c347da92f751c56d5bd074c0051547791937b99e58e4d8879de759a0a488",
} as const;

export const threeVatHandoffMixed = TimelineDocument.parse({
  id: "three-vat-handoff-mixed",
  metadata: {
    "dct:title": "00 · Hand off a capability across three vats",
    "dct:description":
      "Alice introduces Bob to Carol, and Bob then talks to Carol directly. Alice and Carol are pancake, so their session records Cap'n Proto over pancake-next; Bob is Goblins, so both sessions he is on record Syrup over OCapN 1.0. Each session carries its own codec and version, and the picture shows all three at once. Watch the Bob-to-Carol session especially: Carol takes Bob's dial before anything proves who dialed, so that end starts out claiming Bob's address with no peer attached, and only the signed handoff-receive lands the line on Bob.",
    "dct:creator": "pancake project",
    "dct:created": "2026-05-14T00:00:00Z",
  },
  provenance: {
    "prov:wasAttributedTo": AGENT,
  },
  duration: 6000,
  events: [
    // ── t=0: peers join, sessions exist (negotiating) ───────────────
    {
      id: "alice-joins",
      t: 0,
      kind: "peer-joined",
      peerId: "127.0.0.1:9001",
      label: "Alice (gifter)",
      profile: "pancake",
      // The name each peer answers to on the wire, as against the
      // name it is shown by. A claim is a wire name, so this is what
      // a claim can match, and the one below is what Bob's claim on
      // the Bob ↔ Carol session matches.
      designator: "127.0.0.1:9001",
    },
    {
      id: "bob-joins",
      t: 0,
      kind: "peer-joined",
      peerId: "127.0.0.1:9002",
      label: "Bob (receiver)",
      profile: "goblins",
      designator: "127.0.0.1:9002",
    },
    {
      id: "carol-joins",
      t: 0,
      kind: "peer-joined",
      peerId: "127.0.0.1:9003",
      label: "Carol (exporter)",
      profile: "pancake",
      designator: "127.0.0.1:9003",
    },
    {
      // Alice and Carol are both pancake → they speak pancake's
      // native pancake-next wire shape. The other two sessions are
      // forced to v1_0 (Goblins-canonical) because Bob is a
      // Goblins-flavor peer. Per-session negotiation across both codec and
      // CapTP-version axes in one picture.
      id: "alice-carol-opens",
      t: 0,
      kind: "session-opened",
      sessionId: SESSION.aliceCarol,
      // Alice reports this session, so her own end is her own report.
      // Carol's end is attached because Carol publishes her own trace
      // of the same OCapN Session ID: plain `tcp` proves nothing about
      // who answered, and two hosts agreeing is what is left.
      a: {
        peer: "127.0.0.1:9001",
        designator: "127.0.0.1:9001",
        attributedBy: "self-reported",
      },
      b: {
        peer: "127.0.0.1:9003",
        designator: "127.0.0.1:9003",
        attributedBy: "viewer-correlated",
      },
      transport: "tcp",
      codec: "capnp",
      captpVersion: "next",
      initialState: "negotiating",
    },
    {
      id: "alice-bob-opens",
      t: 0,
      kind: "session-opened",
      sessionId: SESSION.aliceBob,
      // Bob is a Goblins vat and publishes no trace this viewer reads,
      // so nothing correlates his end. Plain TCP does not authenticate
      // the designator in his hello, so the end remains loose.
      a: {
        peer: "127.0.0.1:9001",
        designator: "127.0.0.1:9001",
        attributedBy: "self-reported",
      },
      b: {
        designator: "127.0.0.1:9002",
      },
      transport: "tcp",
      codec: "syrup",
      captpVersion: "v1_0",
      initialState: "negotiating",
    },

    // ── t=200-700: session handshakes (op:start-session both ways) ──
    {
      id: "ss-alice-carol-out",
      t: 200,
      kind: "message-sent",
      messageId: "ss-alice-carol-out",
      sessionId: SESSION.aliceCarol,
      from: "127.0.0.1:9001",
      to: "127.0.0.1:9003",
      arrivalT: 400,
      label: "op:start-session",
      ...payloadOf(wireFrames.startSession, AGENT),
    },
    {
      id: "ss-alice-bob-out",
      t: 200,
      kind: "message-sent",
      messageId: "ss-alice-bob-out",
      sessionId: SESSION.aliceBob,
      from: "127.0.0.1:9001",
      to: endpointStageId(SESSION.aliceBob, "b"),
      arrivalT: 400,
      label: "op:start-session",
      ...payloadOf(wireFrames.startSession, AGENT),
    },
    {
      id: "ss-alice-carol-out-deliv",
      t: 400,
      kind: "message-delivered",
      messageId: "ss-alice-carol-out",
    },
    {
      id: "ss-alice-bob-out-deliv",
      t: 400,
      kind: "message-delivered",
      messageId: "ss-alice-bob-out",
    },
    {
      id: "ss-carol-alice-back",
      t: 500,
      kind: "message-sent",
      messageId: "ss-carol-alice-back",
      sessionId: SESSION.aliceCarol,
      from: "127.0.0.1:9003",
      to: "127.0.0.1:9001",
      arrivalT: 700,
      label: "op:start-session",
      ...payloadOf(wireFrames.startSession, AGENT),
    },
    {
      id: "ss-bob-alice-back",
      t: 500,
      kind: "message-sent",
      messageId: "ss-bob-alice-back",
      sessionId: SESSION.aliceBob,
      from: endpointStageId(SESSION.aliceBob, "b"),
      to: "127.0.0.1:9001",
      arrivalT: 700,
      label: "op:start-session",
      ...payloadOf(wireFrames.startSession, AGENT),
    },
    {
      id: "ss-carol-alice-back-deliv",
      t: 700,
      kind: "message-delivered",
      messageId: "ss-carol-alice-back",
    },
    {
      id: "ss-bob-alice-back-deliv",
      t: 700,
      kind: "message-delivered",
      messageId: "ss-bob-alice-back",
    },
    {
      id: "alice-carol-open",
      t: 700,
      kind: "session-state-changed",
      sessionId: SESSION.aliceCarol,
      state: "open",
    },
    {
      id: "alice-bob-open",
      t: 700,
      kind: "session-state-changed",
      sessionId: SESSION.aliceBob,
      state: "open",
    },

    // ── t=900: Alice deposits the gift with Carol ──────────────────
    // The gifter's own leg, and the only Cap'n Proto frame in the
    // scenario. It is fire-and-forget: `Peer.sendDepositGift` sends
    // it with no answer, so nothing comes back and there is nothing
    // for Alice to wait on before she hands Bob the give.
    {
      id: "deposit-gift-sent",
      t: 900,
      kind: "message-sent",
      messageId: "deposit-gift",
      sessionId: SESSION.aliceCarol,
      from: "127.0.0.1:9001",
      to: "127.0.0.1:9003",
      arrivalT: 1100,
      label: "op:deliver deposit-gift",
      ...payloadOf(wireFrames.depositGift, AGENT),
    },
    {
      id: "deposit-gift-delivered",
      t: 1100,
      kind: "message-delivered",
      messageId: "deposit-gift",
    },

    // ── t=1200: Alice sends the handoff-give to Bob ────────────────
    {
      id: "handoff-give-sent",
      t: 1200,
      kind: "message-sent",
      messageId: "handoff-give",
      sessionId: SESSION.aliceBob,
      from: "127.0.0.1:9001",
      to: endpointStageId(SESSION.aliceBob, "b"),
      arrivalT: 1700,
      label: "desc:handoff-give",
      ...payloadOf(wireFrames.handoffGive, AGENT),
    },
    {
      id: "handoff-give-delivered",
      t: 1700,
      kind: "message-delivered",
      messageId: "handoff-give",
    },

    // ── t=1900-2700: Bob acts on the gift ──────────────────────────
    // - Bob resolves the handoff-give back to Alice (op:resolve).
    // - Bob dials Carol → bob-carol session opens (negotiating).
    // - Bob ↔ Carol handshake (op:start-session both ways).
    {
      id: "handoff-give-resolve",
      t: 1900,
      kind: "message-sent",
      messageId: "handoff-give-resolve",
      sessionId: SESSION.aliceBob,
      from: endpointStageId(SESSION.aliceBob, "b"),
      to: "127.0.0.1:9001",
      arrivalT: 2300,
      label: "op:resolve",
      ...payloadOf(wireFrames.resolveFulfillFar, AGENT),
    },
    {
      // Carol accepted this dial, so her end is hers to state and it
      // is the `a` one. The `b` end carries the address Bob's hello
      // claimed and no peer, because the `tcp` netlayer binds nothing
      // about the far side of the socket to that address (ADR-0105).
      // The give Bob is about to present is what will.
      //
      // The address is the one Bob joined under, so the stage aims this
      // end at Bob rather than putting it off on its own, and the wire
      // stops short of him. That is the whole point of writing the
      // claim down instead of minting a peer for it: a claim on
      // somebody can be drawn as a claim on somebody.
      id: "bob-carol-negotiating",
      t: 1900,
      kind: "session-opened",
      sessionId: SESSION.bobCarol,
      a: {
        peer: "127.0.0.1:9003",
        designator: "127.0.0.1:9003",
        attributedBy: "self-reported",
      },
      b: { designator: "127.0.0.1:9002" },
      transport: "tcp",
      codec: "syrup",
      captpVersion: "v1_0",
      initialState: "negotiating",
    },
    {
      id: "ss-bob-carol-out",
      t: 2100,
      kind: "message-sent",
      messageId: "ss-bob-carol-out",
      sessionId: SESSION.bobCarol,
      // From the end itself, not from Bob. Nothing has yet backed the claim
      // this end arrived with, so the recording cannot say whose message
      // this is — only which end of which wire it left. That is the same
      // restraint the session's own `b` shows, said about the traffic.
      from: endpointStageId(SESSION.bobCarol, "b"),
      to: "127.0.0.1:9003",
      arrivalT: 2300,
      label: "op:start-session",
      ...payloadOf(wireFrames.startSession, AGENT),
    },
    {
      id: "handoff-give-resolve-deliv",
      t: 2300,
      kind: "message-delivered",
      messageId: "handoff-give-resolve",
    },
    {
      id: "ss-bob-carol-out-deliv",
      t: 2300,
      kind: "message-delivered",
      messageId: "ss-bob-carol-out",
    },
    {
      id: "ss-carol-bob-back",
      t: 2400,
      kind: "message-sent",
      messageId: "ss-carol-bob-back",
      sessionId: SESSION.bobCarol,
      from: "127.0.0.1:9003",
      to: endpointStageId(SESSION.bobCarol, "b"),
      arrivalT: 2600,
      label: "op:start-session",
      ...payloadOf(wireFrames.startSession, AGENT),
    },
    {
      id: "ss-carol-bob-back-deliv",
      t: 2600,
      kind: "message-delivered",
      messageId: "ss-carol-bob-back",
    },
    {
      id: "bob-carol-open",
      t: 2600,
      kind: "session-state-changed",
      sessionId: SESSION.bobCarol,
      state: "open",
    },

    // ── t=3000-3900: Bob sends the handoff-receive to Carol ────────
    {
      id: "handoff-receive-sent",
      t: 3000,
      kind: "message-sent",
      messageId: "handoff-receive",
      sessionId: SESSION.bobCarol,
      // Still the end and not Bob, and this one most of all: this is the
      // message that BACKS the claim. Naming Bob as its sender would help
      // itself to the very fact it is about to establish, and the
      // attribution that follows at t=3500 would be reporting something the
      // recording had already assumed.
      from: endpointStageId(SESSION.bobCarol, "b"),
      to: "127.0.0.1:9003",
      arrivalT: 3500,
      label: "desc:handoff-receive",
      ...payloadOf(wireFrames.handoffReceive, AGENT),
    },
    {
      id: "handoff-receive-delivered",
      t: 3500,
      kind: "message-delivered",
      messageId: "handoff-receive",
    },
    {
      // Carol has just checked two signatures. Alice signed the give
      // with her key on the Alice ↔ Carol session, and it names the
      // key Bob held on his session with Alice; the receive that
      // arrived here is signed with that same key. So the end stops
      // being loose and is Bob's from now on, and what says so is the
      // handoff itself.
      //
      // `verified-handoff` records that this is the party Alice designated, a
      // different fact from the address in the hello. Nothing here
      // proved that address, and pancake's own handoff path never
      // touches the durable pin, so a peer redeeming a gift over plain
      // `tcp` stays unauthenticated however the handoff goes.
      //
      // The chain closes on the session party Alice introduced because
      // the give names that session key and the receive proves possession.
      //
      // Nothing was born and nothing died: the same session now reaches
      // the peer its claim had been pointing at, so the line completes
      // instead of jumping across the canvas, and no peer moves.
      id: "bob-carol-b-is-bob",
      t: 3500,
      kind: "session-endpoint-attributed",
      sessionId: SESSION.bobCarol,
      side: "b",
      peerId: "127.0.0.1:9002",
      attributedBy: "verified-handoff",
    },
    {
      id: "handoff-receive-resolve",
      t: 3700,
      kind: "message-sent",
      messageId: "handoff-receive-resolve",
      sessionId: SESSION.bobCarol,
      from: "127.0.0.1:9003",
      to: "127.0.0.1:9002",
      arrivalT: 4100,
      label: "op:resolve",
      ...payloadOf(wireFrames.resolveFulfillFar, AGENT),
    },
    {
      id: "handoff-receive-resolve-deliv",
      t: 4100,
      kind: "message-delivered",
      messageId: "handoff-receive-resolve",
    },
  ],
});
