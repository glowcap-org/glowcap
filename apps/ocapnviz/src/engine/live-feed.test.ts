import { assert, assertEquals } from "@std/assert";
import {
  type BaseTimelineEvent,
  convertEvent,
  LiveFeed,
  type LivePeerFactory,
  makeBaseEventConverter,
  newFeedState,
} from "./live-feed.ts";
import { startLiveMode } from "./live-mode.ts";
import type { TimelineEvent } from "./timeline.ts";
import {
  type BuiltinCaptpVersion,
  CAPTP_VERSION_WIRE,
  endpointNodeId,
  GOBLINS_PROFILE,
  PANCAKE_PROFILE,
  type PeerProfile,
  sessionEndpoint,
  UNNAMED_PROFILE,
} from "../schema/topology.ts";
import { Observation } from "./temporal/recording.ts";
import type { PancakeWebModule } from "./pancake-web-api.ts";

/**
 * Narrow `TimelineEvent | undefined` to a specific `kind`. Returns
 * the event so the caller can chain field access without further
 * non-null / discriminant gymnastics.
 *
 * This pattern repeats across the file because `assertEquals` is not
 * a TypeScript predicate — it asserts at runtime but does not narrow
 * the type, and `noUncheckedIndexedAccess` returns `T | undefined`
 * from array indexing.
 */
function expectKind<K extends TimelineEvent["kind"]>(
  ev: TimelineEvent | undefined,
  kind: K,
): Extract<TimelineEvent, { kind: K }> {
  assert(ev !== undefined, `expected event of kind ${kind}, got undefined`);
  assert(
    ev.kind === kind,
    `expected event of kind ${kind}, got ${ev.kind}`,
  );
  return ev as Extract<TimelineEvent, { kind: K }>;
}

Deno.test("ocapn.session-opened synthesizes peer-joined for both peers", () => {
  const convert = makeBaseEventConverter();
  const ev: BaseTimelineEvent = {
    v: 1,
    sim_t_ns: 5_000_000,
    kind: "ocapn.session-opened",
    session: "alice--bob",
    a: "alice",
    b: "bob",
    codec: "syrup",
  };
  const out = convert(ev);
  assertEquals(out.length, 3);
  expectKind(out[0], "peer-joined");
  expectKind(out[1], "peer-joined");
  const session = expectKind(out[2], "session-opened");
  assertEquals(session.sessionId, "alice--bob");
  assertEquals(session.a.peer, "alice");
  assertEquals(session.b.peer, "bob");
  assertEquals(session.codec, "syrup");
});

Deno.test("peer-joined fires exactly once per peer across multiple events", () => {
  const convert = makeBaseEventConverter();
  const session = convert({
    v: 1,
    sim_t_ns: 5_000_000,
    kind: "ocapn.session-opened",
    session: "alice--bob",
    a: "alice",
    b: "bob",
    codec: "syrup",
  });
  const message = convert({
    v: 1,
    sim_t_ns: 6_000_000,
    kind: "ocapn.message-decoded",
    session: "alice--bob",
    src: "alice",
    dst: "bob",
    op: "op:deliver",
    len: 50,
  });
  assertEquals(session.length, 3);
  assertEquals(message.length, 1);
  expectKind(message[0], "message-sent");
});

Deno.test("ocapn.message-decoded yields message-sent with op label", () => {
  const convert = makeBaseEventConverter();
  convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "alice--bob",
    a: "alice",
    b: "bob",
    codec: "syrup",
  });
  const out = convert({
    v: 1,
    sim_t_ns: 10_000_000,
    kind: "ocapn.message-decoded",
    session: "alice--bob",
    src: "alice",
    dst: "bob",
    op: "op:start-session",
    len: 275,
  });
  assertEquals(out.length, 1);
  const msg = expectKind(out[0], "message-sent");
  assertEquals(msg.from, "alice");
  assertEquals(msg.to, "bob");
  assertEquals(msg.label, "op:start-session");
});

Deno.test("ocapn.message-decoded with depart_ns anchors message at depart, arrival at sim_t", () => {
  const convert = makeBaseEventConverter();
  const out = convert({
    v: 1,
    sim_t_ns: 217_000_000,
    kind: "ocapn.message-decoded",
    session: "eu-bob--us-alice",
    src: "us-alice",
    dst: "eu-bob",
    op: "op:start-session",
    len: 275,
    depart_ns: 136_000_000,
  });
  // Two synthesized peer-joined + one message-sent.
  assertEquals(out.length, 3);
  const msg = expectKind(out[2], "message-sent");
  assertEquals(msg.t, 136); // depart at 136ms
  assertEquals(msg.arrivalT, 217); // arrive at 217ms (real flight ≈ 81ms)
  assertEquals(msg.from, "us-alice");
  assertEquals(msg.to, "eu-bob");
});

Deno.test("ocapn.message-decoded without depart_ns stamps the unobserved-flight sentinel", () => {
  // A live host tap observes only arrival. `arrivalT === t` is the
  // "flight unobserved" sentinel: the projection reads a zero
  // flight as absent and substitutes its visible default, so the
  // message flies instead of flashing for a sub-frame instant.
  const convert = makeBaseEventConverter();
  const out = convert({
    v: 1,
    sim_t_ns: 5_000_000,
    kind: "ocapn.message-decoded",
    session: "alice--bob",
    src: "alice",
    dst: "bob",
    op: "op:deliver",
    len: 50,
  });
  assertEquals(out.length, 3);
  const msg = expectKind(out[2], "message-sent");
  assertEquals(msg.t, 5);
  assertEquals(msg.arrivalT, 5);
});

Deno.test("converter generates monotonic unique ids", () => {
  const convert = makeBaseEventConverter();
  const base: BaseTimelineEvent = {
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "s",
    a: "a",
    b: "b",
    codec: "syrup",
  };
  const a = convert({ ...base, session: "s1", a: "a1", b: "b1" });
  const b = convert({ ...base, session: "s2", a: "a2", b: "b2" });
  const c = convert({ ...base, session: "s3", a: "a3", b: "b3" });
  const aFirst = a[0];
  const bFirst = b[0];
  const cFirst = c[0];
  assert(aFirst && bFirst && cFirst, "each conversion produced an event");
  assert(aFirst.id !== bFirst.id);
  assert(bFirst.id !== cFirst.id);
  assert(aFirst.id !== cFirst.id);
});

Deno.test("a kind this viewer does not read yields nothing", () => {
  // The feed reads the `ocapn.*` and `trace.*` families and ignores
  // everything else rather than guessing at it. A producer is free to
  // put its own records on the same stream, and a viewer that threw or
  // drew something on one would make that impossible.
  const convert = makeBaseEventConverter();
  const cases = [
    { kind: "UnknownKind" },
    { kind: "some.other.family" },
    { kind: "ocapn.a-kind-from-a-later-schema" },
    { kind: "" },
    { kind: 42 },
  ];
  for (const c of cases) {
    const ev: BaseTimelineEvent = { v: 1, sim_t_ns: 0, ...c };
    assertEquals(convert(ev).length, 0, `expected [] for kind=${c.kind}`);
  }
});

Deno.test("a non-number timestamp yields nothing", () => {
  const convert = makeBaseEventConverter();
  const out = convert({
    v: 1,
    sim_t_ns: "0",
    kind: "ocapn.session-opened",
    session: "alice--bob",
    a: "alice",
    b: "bob",
    codec: "syrup",
  });
  assertEquals(out, []);
});

Deno.test("live-feed: a host tap's outbound flag resolves src/dst from session-opened", () => {
  // The live producer names only its session and direction; the converter
  // owns endpoint labeling from the session-opened it already saw, so every
  // producer veneer can stay a stamp-and-forward.
  const convert = makeBaseEventConverter();
  convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "live-s7",
    a: "rooms",
    b: "alice",
    codec: "syrup",
  });
  const outbound = convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.message-decoded",
    session: "live-s7",
    outbound: true,
    op: "notify",
  });
  const sent = outbound.find((ev) => ev.kind === "message-sent");
  assertEquals(sent?.kind === "message-sent" ? sent.from : null, "rooms");
  assertEquals(sent?.kind === "message-sent" ? sent.to : null, "alice");
  const inbound = convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "ocapn.message-decoded",
    session: "live-s7",
    outbound: false,
    op: "post",
  });
  const got = inbound.find((ev) => ev.kind === "message-sent");
  assertEquals(got?.kind === "message-sent" ? got.from : null, "alice");
  assertEquals(got?.kind === "message-sent" ? got.to : null, "rooms");
  const closed = convert({
    v: 1,
    sim_t_ns: 3_000_000,
    kind: "ocapn.session-closed",
    session: "live-s7",
  });
  // The session's own close lands on stage, then the far end leaves.
  const closeEv = closed.find((ev) => ev.kind === "session-closed");
  assertEquals(
    closeEv?.kind === "session-closed" ? closeEv.sessionId : null,
    "live-s7",
  );
  const left = closed.find((ev) => ev.kind === "peer-left");
  assertEquals(left?.kind === "peer-left" ? left.peerId : null, "alice");
});

// ── Stage ledger: incarnations, refcounted leaves, epochs ──

function openSession(
  convert: (ev: BaseTimelineEvent) => TimelineEvent[],
  session: string,
  b: string,
  t_ns: number,
): TimelineEvent[] {
  return convert({
    v: 1,
    sim_t_ns: t_ns,
    kind: "ocapn.session-opened",
    session,
    a: "rooms",
    b,
    codec: "syrup",
  });
}

function closeSession(
  convert: (ev: BaseTimelineEvent) => TimelineEvent[],
  session: string,
  t_ns: number,
): TimelineEvent[] {
  return convert({
    v: 1,
    sim_t_ns: t_ns,
    kind: "ocapn.session-closed",
    session,
  });
}

Deno.test("session-closed retires the partner but keeps the reporting host", () => {
  const convert = makeBaseEventConverter();
  openSession(convert, "s1", "bob", 0);
  const out = closeSession(convert, "s1", 10_000_000);
  assertEquals(out.length, 2);
  expectKind(out[0], "session-closed");
  const left = expectKind(out[1], "peer-left");
  assertEquals(left.peerId, "bob");
  // The reporting host (`a`) outlives its sessions: no leave for it.
});

Deno.test("a peer with two live sessions survives one closing", () => {
  // Reconnect overlap: the same identity opens a second session
  // before the first one's close lands. The old close must not
  // retire the peer while the new session still references it.
  const convert = makeBaseEventConverter();
  openSession(convert, "s1", "bob", 0);
  openSession(convert, "s2", "bob", 1_000_000);
  const firstClose = closeSession(convert, "s1", 2_000_000);
  assertEquals(firstClose.length, 1); // session-closed only, no peer-left
  expectKind(firstClose[0], "session-closed");
  const lastClose = closeSession(convert, "s2", 3_000_000);
  assertEquals(lastClose.length, 2);
  expectKind(lastClose[0], "session-closed");
  assertEquals(expectKind(lastClose[1], "peer-left").peerId, "bob");
});

Deno.test("a returning peer gets a fresh incarnation id, same label", () => {
  // The timeline's entity model gives each id ONE lifetime, so a
  // wire name that returns after leaving renders as a new stage
  // entity. The label stays the wire name.
  const convert = makeBaseEventConverter();
  openSession(convert, "s1", "bob", 0);
  closeSession(convert, "s1", 10_000_000);
  const again = openSession(convert, "s2", "bob", 20_000_000);
  const rejoined = expectKind(again[0], "peer-joined");
  assertEquals(rejoined.peerId, "bob#2");
  assertEquals(rejoined.label, "bob");
  const session = expectKind(again[1], "session-opened");
  assertEquals(session.b.peer, "bob#2");
});

Deno.test("a reused wire session id gets a fresh stage session id", () => {
  const convert = makeBaseEventConverter();
  openSession(convert, "s1", "bob", 0);
  closeSession(convert, "s1", 10_000_000);
  const again = openSession(convert, "s1", "carol", 20_000_000);
  const session = expectKind(again[1], "session-opened");
  assertEquals(session.sessionId, "s1#2");
});

Deno.test("messages route to the current session incarnation", () => {
  const convert = makeBaseEventConverter();
  openSession(convert, "s1", "bob", 0);
  closeSession(convert, "s1", 10_000_000);
  openSession(convert, "s1", "carol", 20_000_000);
  const out = convert({
    v: 1,
    sim_t_ns: 21_000_000,
    kind: "ocapn.message-decoded",
    session: "s1",
    outbound: true,
    op: "op:deliver",
  });
  assertEquals(out.length, 1);
  const msg = expectKind(out[0], "message-sent");
  assertEquals(msg.sessionId, "s1#2");
  assertEquals(msg.from, "rooms");
  assertEquals(msg.to, "carol"); // first incarnation keeps the bare name
});

Deno.test("an epoch change retires the dead process's topology", () => {
  // A restarted producer restarts its seq and may reuse session
  // ids. Its old topology goes out of view; the converter ends
  // everything from the previous epoch, then the new process's
  // events build fresh incarnations.
  //
  // Out of VIEW, not closed. Some of what the dead process was
  // showing died with it and some did not — two browser tabs talking
  // directly kept going — and from here those are indistinguishable.
  // So the timeline says the one thing true of both.
  const convert = makeBaseEventConverter();
  convert({
    v: 1,
    sim_t_ns: 0,
    epoch: 111,
    kind: "ocapn.session-opened",
    session: "s1",
    a: "rooms",
    b: "bob",
    codec: "syrup",
  });
  const out = convert({
    v: 1,
    sim_t_ns: 1_000_000,
    epoch: 222,
    kind: "ocapn.session-opened",
    session: "s1",
    a: "rooms",
    b: "bob",
    codec: "syrup",
  });
  // Old epoch retired: the session and both peers go out of view,
  // then the new epoch's joins + open with fresh incarnations.
  const kinds = out.map((e) => e.kind);
  assertEquals(kinds, [
    "session-unobserved",
    "peer-unobserved",
    "peer-unobserved",
    "peer-joined",
    "peer-joined",
    "session-opened",
  ]);
  // And nothing claimed the network did anything.
  assertEquals(
    out.filter((e) => e.kind === "session-closed" || e.kind === "peer-left")
      .length,
    0,
    "a feed restarting is not a teardown anyone observed",
  );
  const session = expectKind(out[5], "session-opened");
  assertEquals(session.sessionId, "s1#2");
  assertEquals(session.a.peer, "rooms#2");
  assertEquals(session.b.peer, "bob#2");
});

Deno.test("session-opened arrives on stage already open", () => {
  // The trace reports a session only after its handshake, so the
  // stage must not show "negotiating" for its whole life.
  const convert = makeBaseEventConverter();
  const out = openSession(convert, "s1", "bob", 0);
  const session = expectKind(out[2], "session-opened");
  assertEquals(session.initialState, "open");
});

Deno.test("an unverified claim is session-scoped, not an identity", () => {
  // Two browser tabs behind a relay both CLAIM `127.0.0.1:0` (a
  // browser peer has no listening address). An unverified name
  // must not merge them onto one stage peer: each session gets its
  // own, and the label disambiguates along with the id, so the two
  // are told apart on screen and not only in the document. A claim
  // is not an identity, so nothing is lost by qualifying it.
  const convert = makeBaseEventConverter();
  const openUnverified = (session: string, t_ns: number) =>
    convert({
      v: 1,
      sim_t_ns: t_ns,
      kind: "ocapn.session-opened",
      session,
      a: "rooms",
      b: "127.0.0.1:0",
      codec: "syrup",
      provenance: "unauthenticated",
    });
  const first = openUnverified("s1", 0);
  const second = openUnverified("s2", 1_000_000);
  // Neither claim draws a peer at all, which is the strongest form of "not
  // an identity": there is nothing for a second session's identical claim to
  // be merged onto, and nothing to dispose of when it turns out to be
  // somebody. The claim rides the end that carries it.
  for (const batch of [first, second]) {
    const opened = expectKind(
      batch.find((e) => e.kind === "session-opened"),
      "session-opened",
    );
    assertEquals(opened.a.peer, "rooms");
    assertEquals(opened.b.peer, undefined, "an unproven claim attaches nobody");
    assertEquals(opened.b.designator, "127.0.0.1:0");
    assertEquals(opened.b.attributedBy, undefined);
  }
  // Only the reporting host is ever drawn, and only once: the first session
  // joins it and the second finds it already there.
  assertEquals(
    first.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
    ["rooms"],
  );
  assertEquals(
    second.filter((e) => e.kind === "peer-joined").length,
    0,
    "the second identical claim drew nobody new",
  );
  // Closing one tab's session retires no peer but the room's own row stays:
  // the loose end had nobody to retire.
  const closed = closeSession(convert, "s1", 2_000_000);
  assertEquals(
    closed.filter((e) => e.kind === "peer-left").length,
    0,
    "a loose end leaving takes no peer with it",
  );
});

Deno.test("a room nick is a name for an end, never a name that identifies it", () => {
  // A real Goblins vat joins a pancake room over plain tcp. The room server is
  // the only producer that can see it, and everything it has about that end is
  // a claim: the vat's designator is an address, so the host's provenance
  // verdict is `unauthenticated`, and the nick the room states is an
  // application annotation about a membership that can change hands.
  //
  // So the end stays loose, and this is the design working rather than a gap
  // in it. Attributing on the address would merge every session that ever
  // claimed it; attributing on the nick would merge whoever wears it next.
  // Nothing here concludes Goblins either — pancake speaks the v1.0 floor over
  // Syrup as readily as a vat does, so the profile the far side runs is not
  // something this observation can reach.
  const convert = makeBaseEventConverter();
  const open = convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-opened",
    session: "p0/live-h1-s1",
    a: "127.0.0.1:9099",
    a_label: "rooms",
    b: "127.0.0.1:41234",
    transport: "tcp",
    provenance: "unauthenticated",
    session_id: wireName("c"),
    codec: "syrup",
    captp_version: "1.0",
  });
  const opened = expectKind(
    open.find((e) => e.kind === "session-opened"),
    "session-opened",
  );
  assertEquals(
    opened.b.peer,
    undefined,
    "an address nothing proved names nobody",
  );
  assertEquals(opened.b.designator, "127.0.0.1:41234");
  assertEquals(
    open.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
    ["127.0.0.1:9099"],
    "only the reporting host is drawn",
  );
  // The room then vouches for the member's nick, and the end is still loose:
  // no peer arrives to wear it, and no profile is concluded from it.
  const named = convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "ocapn.session-meta",
    session: "p0/live-h1-s1",
    meta: { label: "goblins-carol" },
  });
  assertEquals(
    named.filter((e) => e.kind === "peer-joined").length,
    0,
    "a nick draws no peer",
  );
  assertEquals(
    named.filter((e) =>
      e.kind === "peer-updated" &&
      expectKind(e, "peer-updated").profile !== undefined
    ).length,
    0,
    "a nick says nothing about what the far side runs",
  );
});

Deno.test("a verified name IS an identity across sessions", () => {
  const convert = makeBaseEventConverter();
  const open = (session: string, t_ns: number) =>
    convert({
      v: 1,
      sim_t_ns: t_ns,
      kind: "ocapn.session-opened",
      session,
      a: "rooms",
      b: "ed25519:bobkey",
      codec: "syrup",
      provenance: "authenticated-transport",
    });
  const first = open("s1", 0);
  const second = open("s2", 1_000_000);
  expectKind(first[1], "peer-joined");
  // Second session: no new peer-joined for bob — same identity.
  assertEquals(second.length, 1);
  const session = expectKind(second[0], "session-opened");
  assertEquals(session.b.peer, "ed25519:bobkey");
});

Deno.test("message payload passes through: whole frame or capped head", () => {
  // The producer owns the cap; this layer neither decodes nor
  // re-bounds. Whole frame: bytes_b64 + len. Capped: summary's
  // head + true length.
  const convert = makeBaseEventConverter();
  openSession(convert, "s1", "bob", 0);
  const whole = convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.message-decoded",
    session: "s1",
    outbound: false,
    op: "post",
    bytes_b64: "U3lydXAh",
    len: 6,
  });
  const wholeMsg = expectKind(whole[0], "message-sent");
  assertEquals(wholeMsg.bytesB64, "U3lydXAh");
  assertEquals(wholeMsg.byteLen, 6);
  const capped = convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "ocapn.message-decoded",
    session: "s1",
    outbound: true,
    op: "post",
    summary: { len: 9000, head_b64: "U3lydXAh" },
  });
  const cappedMsg = expectKind(capped[0], "message-sent");
  assertEquals(cappedMsg.bytesB64, "U3lydXAh");
  assertEquals(cappedMsg.byteLen, 9000);
});

Deno.test("replay is state, not events: topology applies, messages stay out", () => {
  // A (re)connecting viewer hears the producer's replay marked
  // `replay: true`. Session opens must materialize (the viewer
  // needs the live topology to route what it sees next); replayed
  // messages happened before this viewer watched, so they must not
  // enter its capture.
  //
  // The batch is one picture, so the topology lands when the endpoint
  // says the batch has ended rather than record by record — that is
  // what lets a wire reported by both its ends be drawn once, already
  // knowing both.
  const convert = makeBaseEventConverter();
  const held = convert({
    v: 1,
    sim_t_ns: 0,
    replay: true,
    kind: "ocapn.session-opened",
    session: "s1",
    a: "rooms",
    b: "bob",
    codec: "syrup",
  });
  assertEquals(
    held.length,
    0,
    "a replayed open waits for the end of its batch",
  );
  const replayedMsg = convert({
    v: 1,
    sim_t_ns: 1_000_000,
    replay: true,
    kind: "ocapn.message-decoded",
    session: "s1",
    outbound: true,
    op: "post",
  });
  assertEquals(replayedMsg.length, 0);
  const opened = convert({
    v: 1,
    sim_t_ns: 1_500_000,
    kind: "trace.replay-end",
  });
  assertEquals(opened.length, 3); // two joins + the open: state applies
  // The replayed message stayed out of the capture even though it rode
  // the same batch.
  assertEquals(opened.filter((e) => e.kind === "message-sent").length, 0);
  // The live tail after the replay flows normally.
  const liveMsg = convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "ocapn.message-decoded",
    session: "s1",
    outbound: true,
    op: "post",
  });
  assertEquals(liveMsg.length, 1);
  expectKind(liveMsg[0], "message-sent");
});

Deno.test("replay completion removes observations absent from the snapshot", () => {
  const convert = makeBaseEventConverter();
  convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p0/s1",
    a: "rooms",
    b: "alice",
    codec: "syrup",
  });
  const reconciled = convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "trace.replay-end",
  });
  assertEquals(
    reconciled.filter((ev) => ev.kind === "session-unobserved").length,
    1,
  );
});

Deno.test("replay completion retains observations still in the snapshot", () => {
  const convert = makeBaseEventConverter();
  const open: BaseTimelineEvent = {
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p0/s1",
    a: "rooms",
    b: "alice",
    codec: "syrup",
  };
  convert(open);
  assertEquals(convert({ ...open, replay: true }), []);
  assertEquals(
    convert({
      v: 1,
      sim_t_ns: 2_000_000,
      kind: "trace.replay-end",
    }),
    [],
    "a retained observation was closed and reopened during snapshot replacement",
  );
});

Deno.test("session-meta folds into the partner's label, identity untouched", () => {
  // The annotation pipeline's viewer edge: the producing app states
  // which member a session carries, and the converter turns it into
  // a peer-updated on the session's PARTNER — a claim about naming,
  // never identity (the stage id does not change).
  const convert = makeBaseEventConverter();
  openSession(convert, "s1", "127.0.0.1:0", 0);
  const out = convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-meta",
    session: "s1",
    meta: { label: "carol" },
  });
  assertEquals(out.length, 1);
  const updated = expectKind(out[0], "peer-updated");
  assertEquals(updated.peerId, "127.0.0.1:0");
  assertEquals(updated.label, "carol");
  // A session the converter has not seen open: nothing to name yet.
  assertEquals(
    convert({
      v: 1,
      sim_t_ns: 2_000_000,
      kind: "ocapn.session-meta",
      session: "nope",
      meta: { label: "x" },
    }).length,
    0,
  );
});

Deno.test("a name claimed before its session opens lands at the open", () => {
  // A producer replaying its state to a connecting viewer can send
  // the name before the session it names. Dropping it would leave
  // that member under its locator for the rest of the feed.
  const convert = makeBaseEventConverter();
  assertEquals(
    convert({
      v: 1,
      sim_t_ns: 1_000_000,
      kind: "ocapn.session-meta",
      session: "s1",
      meta: { label: "carol" },
    }).length,
    0,
  );
  const opened = openSession(convert, "s1", "127.0.0.1:0", 2_000_000);
  const updated = expectKind(
    opened.find((ev) => ev.kind === "peer-updated"),
    "peer-updated",
  );
  assertEquals(updated.peerId, "127.0.0.1:0");
  assertEquals(updated.label, "carol");
  // At the open's own time: the peer arrives already named.
  assertEquals(updated.t, 2);
});

Deno.test("a claim is spent once, and the newest claim wins", () => {
  const convert = makeBaseEventConverter();
  const claim = (label: string) =>
    convert({
      v: 1,
      sim_t_ns: 1_000_000,
      kind: "ocapn.session-meta",
      session: "s1",
      meta: { label },
    });
  claim("stale");
  claim("carol");
  const opened = openSession(convert, "s1", "127.0.0.1:0", 2_000_000);
  const updates = opened.filter((ev) => ev.kind === "peer-updated");
  assertEquals(updates.length, 1);
  assertEquals(expectKind(updates[0], "peer-updated").label, "carol");

  // The same wire id opening again is a new incarnation, and the
  // spent claim must not name it.
  closeSession(convert, "s1", 3_000_000);
  const reopened = openSession(convert, "s1", "127.0.0.1:0", 4_000_000);
  assertEquals(reopened.filter((ev) => ev.kind === "peer-updated").length, 0);
});

Deno.test("restating the name a peer already answers to is not a rename", () => {
  // The rooms server annotates a session when a member subscribes to
  // a room and again when it registers for direct messages, both
  // with the same nick. One join must paint one diamond, not two
  // saying the same thing.
  const convert = makeBaseEventConverter();
  openSession(convert, "s1", "127.0.0.1:0", 0);
  const claim = (label: string, t_ns: number) =>
    convert({
      v: 1,
      sim_t_ns: t_ns,
      kind: "ocapn.session-meta",
      session: "s1",
      meta: { label },
    });
  assertEquals(claim("carol", 1_000_000).length, 1);
  assertEquals(claim("carol", 2_000_000).length, 0);
  // A different name still renames.
  const renamed = claim("carol-away", 3_000_000);
  assertEquals(renamed.length, 1);
  assertEquals(expectKind(renamed[0], "peer-updated").label, "carol-away");
});

Deno.test("a claim restating a peer's join name is not a rename", () => {
  // The name a peer joined under is the name it answers to, so a
  // producer stating it explicitly changes nothing.
  const convert = makeBaseEventConverter();
  openSession(convert, "s1", "carol", 0);
  assertEquals(
    convert({
      v: 1,
      sim_t_ns: 1_000_000,
      kind: "ocapn.session-meta",
      session: "s1",
      meta: { label: "carol" },
    }).length,
    0,
  );
});

Deno.test("a claim for a session that closed instead of opening is dropped", () => {
  // The close ends that wire id's life. A claim still waiting on it
  // has nothing left to name, and must not name the next session to
  // take the same id.
  const convert = makeBaseEventConverter();
  convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-meta",
    session: "s1",
    meta: { label: "carol" },
  });
  closeSession(convert, "s1", 2_000_000);
  const opened = openSession(convert, "s1", "127.0.0.1:0", 3_000_000);
  assertEquals(opened.filter((ev) => ev.kind === "peer-updated").length, 0);
});

Deno.test("the negotiated CapTP profile comes from the producer, not a guess", () => {
  // The viewer used to stamp v1_0 on every session because the tap
  // reported the codec and not the version, so a pancake-to-pancake
  // session drawn as capnp still read as CapTP 1.0.
  const convert = makeBaseEventConverter();
  const nextOut = convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "s1",
    a: "rooms",
    b: "bob",
    codec: "capnp",
    captp_version: CAPTP_VERSION_WIRE.next,
  });
  assertEquals(expectKind(nextOut[2], "session-opened").captpVersion, "next");
  // A producer that reports none predates the field; the only profile
  // that existed then was the floor.
  const floorOut = makeBaseEventConverter()({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "s2",
    a: "rooms",
    b: "carol",
    codec: "syrup",
  });
  assertEquals(expectKind(floorOut[2], "session-opened").captpVersion, "v1_0");

  const unknownOut = makeBaseEventConverter()({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "s3",
    a: "rooms",
    b: "dave",
    codec: "syrup",
    captp_version: "future-profile",
  });
  assertEquals(
    expectKind(unknownOut[2], "session-opened").captpVersion,
    "unknown",
  );

  const nonStringOut = makeBaseEventConverter()({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "s4",
    a: "rooms",
    b: "erin",
    codec: "syrup",
    captp_version: 1,
  });
  assertEquals(
    expectKind(nonStringOut[2], "session-opened").captpVersion,
    "unknown",
  );
});

Deno.test("an unknown negotiated codec stays unknown", () => {
  const convert = makeBaseEventConverter();
  const out = convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "s1",
    a: "rooms",
    b: "bob",
    codec: "unknown",
  });
  assertEquals(expectKind(out[2], "session-opened").codec, "unknown");
});

Deno.test("a future negotiated codec keeps its wire word", () => {
  const convert = makeBaseEventConverter();
  const out = convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "s1",
    a: "rooms",
    b: "bob",
    codec: "postcard",
  });
  assertEquals(expectKind(out[2], "session-opened").codec, "postcard");
});

Deno.test("an absent, empty, or non-string codec is unknown", () => {
  const convert = makeBaseEventConverter();
  const absentOut = convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "s1",
    a: "rooms",
    b: "bob",
  });
  assertEquals(expectKind(absentOut[2], "session-opened").codec, "unknown");

  const emptyOut = makeBaseEventConverter()({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "s2",
    a: "rooms",
    b: "bob",
    codec: "",
  });
  assertEquals(expectKind(emptyOut[2], "session-opened").codec, "unknown");

  const numericOut = makeBaseEventConverter()({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "s3",
    a: "rooms",
    b: "bob",
    codec: 1,
  });
  assertEquals(expectKind(numericOut[2], "session-opened").codec, "unknown");
});

Deno.test("a departed producer's own node leaves with the last session to it", () => {
  // The reported bug: refresh a tab and its node stayed on stage forever.
  //
  // A reporting host outlives its sessions on purpose — a room server is
  // there whether or not anyone is connected — and that was right while the
  // room server was the only producer. A browser tab is a producer now, and
  // its life ends when it reloads, so the endpoint says which producer left
  // and the host it spoke for stops being one. What takes it off stage is
  // the last session touching it going, and the converter ends this
  // producer's sessions itself when it hears the departure.
  //
  // The row ends UNOBSERVED: a publishing socket closed, which is all
  // anyone here saw. A tab that merely turned tracing off looks the same.
  const convert = makeBaseEventConverter();
  const opened = convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s1",
    a: "tab-designator",
    b: "rooms",
    codec: "syrup",
  });
  assert(opened.some((e) => e.kind === "peer-joined"));

  convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-closed",
    session: "p2/live-h1-s1",
  });
  const left = convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "trace.producer-left",
    scope: "p2",
  });
  const gone = left.filter((e) => e.kind === "peer-unobserved");
  assertEquals(gone.length, 1);
  assertEquals(
    expectKind(gone[0], "peer-unobserved").peerId,
    "tab-designator",
  );
  assertEquals(
    left.filter((e) => e.kind === "peer-left").length,
    0,
    "a publishing socket closing is not a departure anyone observed",
  );
});

Deno.test("a producer leaving does not retire another producer's host", () => {
  // The hazard in the fix: the ledger already had a whole-topology
  // retirement for a restarted process, and reaching for that here would
  // have wiped every other producer's peers off the stage.
  const convert = makeBaseEventConverter();
  convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p1/live-h1-s1",
    a: "rooms",
    b: "someone",
    codec: "syrup",
  });
  convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s1",
    a: "tab-designator",
    b: "rooms",
    codec: "syrup",
  });
  convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "ocapn.session-closed",
    session: "p2/live-h1-s1",
  });
  const left = convert({
    v: 1,
    sim_t_ns: 3_000_000,
    kind: "trace.producer-left",
    scope: "p2",
  });
  const gone = left.filter((e) => e.kind === "peer-unobserved").map((e) => expectKind(e, "peer-unobserved").peerId);
  assertEquals(gone, ["tab-designator"]);
});

Deno.test("an explicit close retires a shared wire before producer departure", () => {
  // Both producers observe one transport. A protocol close from either end
  // proves that shared wire ended; it is not observer loss and must not wait
  // for the second endpoint's duplicate close.
  const convert = makeBaseEventConverter();
  const wire = "d".repeat(64);
  convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p1/live-h1-s1",
    a: "rooms",
    b: "127.0.0.1:0",
    provenance: "unauthenticated",
    session_id: wire,
    codec: "syrup",
  });
  convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s1",
    a: "tab-designator",
    b: "rooms",
    session_id: wire,
    codec: "syrup",
  });
  const closed = convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "ocapn.session-closed",
    session: "p2/live-h1-s1",
  });
  assertEquals(closed.filter((e) => e.kind === "session-closed").length, 1);
  const left = convert({
    v: 1,
    sim_t_ns: 3_000_000,
    kind: "trace.producer-left",
    scope: "p2",
  });
  assertEquals(left.filter((e) => e.kind === "peer-left").length, 0);
  assertEquals(left.filter((e) => e.kind === "session-closed").length, 0);
  assertEquals(left.filter((e) => e.kind === "peer-unobserved").length, 1);
  const duplicate = convert({
    v: 1,
    sim_t_ns: 4_000_000,
    kind: "ocapn.session-closed",
    session: "p1/live-h1-s1",
  });
  assertEquals(duplicate.length, 0);
});

// ── Two ends of one wire ──

/** The wire name both peers of a session derive. Any 64 hex digits will do
 * here; what matters is that both producers report the SAME one. */
function wireName(seed: string): string {
  return seed.repeat(64).slice(0, 64);
}

Deno.test("two producers watching one wire draw one session", () => {
  // A browser tab publishes its own trace and the room server reports the
  // same connection. Both name the same wire, because both ends of a CapTP
  // session derive that name from the two public identifiers with the pair
  // sorted. One conversation is one edge however many ends report it.
  const convert = makeBaseEventConverter();
  const wire = wireName("a");
  const first = convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p1/live-h1-s1",
    a: "rooms",
    b: "127.0.0.1:0",
    provenance: "unauthenticated",
    session_id: wire,
    codec: "syrup",
  });
  assertEquals(first.filter((e) => e.kind === "session-opened").length, 1);
  const second = convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s1",
    a: "tab-designator",
    b: "rooms",
    session_id: wire,
    codec: "syrup",
  });
  assertEquals(second.filter((e) => e.kind === "session-opened").length, 0);
  // The tab is drawn once, by the report that could say who it is. The room's
  // report drew nobody for that end, so this join has nothing to be a
  // duplicate of — two producers leave two nodes on stage, not three.
  assertEquals(
    second.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
    ["tab-designator"],
  );
  assertEquals(
    pictureOf([...first, ...second]).peers.map((p) => p.split("=")[0]),
    ["rooms", "tab-designator"],
  );
  // And the edge already on stage takes the tab on the end the room reported
  // as its partner, rather than a second edge being drawn to it.
  const attached = expectKind(
    second.find((e) => e.kind === "session-endpoint-attributed"),
    "session-endpoint-attributed",
  );
  assertEquals(attached.side, "b");
  assertEquals(attached.peerId, "tab-designator");
});

Deno.test("a tab's later session hangs off the node its end attached to", () => {
  // The whole point of joining two reports on one wire. The room sees a member
  // as an unverified claim and the member sees itself by its own key
  // designator; without the wire to join them the member is two nodes, and the
  // direct message it opens later hangs off the wrong one.
  const convert = makeBaseEventConverter();
  const roomWire = wireName("b");
  convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p1/live-h1-s1",
    a: "rooms",
    b: "127.0.0.1:0",
    provenance: "unauthenticated",
    session_id: roomWire,
    codec: "syrup",
  });
  const joined = convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s1",
    a: "tab-designator",
    b: "rooms",
    session_id: roomWire,
    codec: "syrup",
  });
  // The tab's own report is what draws it, under its own designator.
  const tab = expectKind(
    joined.find((e) => e.kind === "peer-joined"),
    "peer-joined",
  ).peerId;
  assertEquals(tab, "tab-designator");
  // Now the same tab opens a direct session to someone else. Its own end
  // must be the node already on stage, not a fresh one.
  const dm = convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s2",
    a: "tab-designator",
    b: "other-tab",
    session_id: wireName("c"),
    codec: "syrup",
  });
  const opened = expectKind(
    dm.find((e) => e.kind === "session-opened"),
    "session-opened",
  );
  const newNodes = dm.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId);
  // Only the far end of the direct session is new.
  assertEquals(newNodes, ["other-tab"]);
  assertEquals(opened.a.peer, tab, "the tab's two sessions meet at one node");
  assertEquals(opened.a.attributedBy, "self-reported");
  assertEquals(opened.b.peer, "other-tab");
});

Deno.test("one message reported by both ends draws once", () => {
  // Each end of a session sees every message of it, so a merged feed would
  // double the whole conversation. The core tags each message with a hash of
  // its own wire bytes: one frame crosses one wire, so both ends derive the
  // same tag with nothing to coordinate, and the second sighting folds into
  // the first.
  const convert = makeBaseEventConverter();
  const wire = wireName("e");
  convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p1/live-h1-s1",
    a: "alice",
    b: "bob",
    session_id: wire,
    codec: "syrup",
  });
  convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s1",
    a: "bob",
    b: "alice",
    session_id: wire,
    codec: "syrup",
  });
  const sent = convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "ocapn.message-decoded",
    session: "p1/live-h1-s1",
    outbound: true,
    op: "dm",
    digest: "00112233445566778899aabbccddeeff",
  });
  assertEquals(sent.filter((e) => e.kind === "message-sent").length, 1);
  const echo = convert({
    v: 1,
    sim_t_ns: 2_100_000,
    kind: "ocapn.message-decoded",
    session: "p2/live-h1-s1",
    outbound: false,
    op: "dm",
    digest: "00112233445566778899aabbccddeeff",
  });
  assertEquals(echo.filter((e) => e.kind === "message-sent").length, 0);
});

Deno.test("a peer sending the same bytes twice draws twice", () => {
  // The fold consumes a tag rather than remembering it, so a genuine repeat
  // still draws. Remembering would silently swallow every retransmission of
  // an identical frame for the life of the session.
  const convert = makeBaseEventConverter();
  const wire = wireName("f");
  convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p1/live-h1-s1",
    a: "alice",
    b: "bob",
    session_id: wire,
    codec: "syrup",
  });
  convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s1",
    a: "bob",
    b: "alice",
    session_id: wire,
    codec: "syrup",
  });
  const tag = "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f";
  const drawn = [
    "p1/live-h1-s1",
    "p2/live-h1-s1",
    "p1/live-h1-s1",
    "p2/live-h1-s1",
  ]
    .map((session, i) =>
      convert({
        v: 1,
        sim_t_ns: 2_000_000 + i * 1000,
        kind: "ocapn.message-decoded",
        session,
        outbound: session.startsWith("p1"),
        op: "ping",
        digest: tag,
      }).filter((e) => e.kind === "message-sent").length
    );
  assertEquals(drawn, [1, 0, 1, 0]);
});

Deno.test("either endpoint closes the shared wire immediately", () => {
  // A direct message closed from the receiving tab must end the session in
  // the picture. Both ends may report the close, but the first observation is
  // already conclusive and the duplicate must be inert.
  const state = newFeedState();
  const convert = (ev: BaseTimelineEvent) => convertEvent(ev, state);
  const wire = wireName("9");
  convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p1/live-h1-s1",
    a: "alice",
    b: "bob",
    session_id: wire,
    codec: "syrup",
  });
  convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s1",
    a: "bob",
    b: "alice",
    session_id: wire,
    codec: "syrup",
  });
  // The end the first observer did NOT report hangs up first.
  const closed = convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "ocapn.session-closed",
    session: "p2/live-h1-s1",
  });
  assertEquals(closed.filter((e) => e.kind === "session-closed").length, 1);
  assertEquals(
    state.sessionsOfScope.size,
    0,
    "the retired counterpart remained in its producer's session registry",
  );
  const duplicate = convert({
    v: 1,
    sim_t_ns: 2_100_000,
    kind: "ocapn.session-closed",
    session: "p1/live-h1-s1",
  });
  assertEquals(duplicate.length, 0);
});

Deno.test("a replacement wire opens after either endpoint closes the old one", () => {
  const convert = makeBaseEventConverter();
  const oldWire = wireName("9");
  const newWire = wireName("a");
  convert(opened(0, "p1/s1", "alice", "bob", oldWire, true));
  convert(opened(1, "p2/s1", "bob", "alice", oldWire, true));

  const closed = convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "ocapn.session-closed",
    session: "p2/s1",
  });
  assertEquals(closed.filter((e) => e.kind === "session-closed").length, 1);

  const reopened = convert(
    opened(3, "p1/s2", "alice", "bob", newWire, true),
  );
  const replacement = reopened.find((e) => e.kind === "session-opened");
  assert(replacement !== undefined, "the replacement wire was not drawn");
  assertEquals(expectKind(replacement, "session-opened").sessionId, newWire);
  const corroborated = convert(
    opened(4, "p2/s2", "bob", "alice", newWire, true),
  );
  assertEquals(
    corroborated.filter((e) => e.kind === "session-opened").length,
    0,
  );
});

Deno.test("withdrawing a claim reveals the name underneath", () => {
  // A member leaving a room keeps its connection to the room server, so the
  // session stays; what changed is that the room no longer knows the
  // connection by a nickname. Withdrawing the claim has to show that, and
  // freezing the last nick anyone said would not.
  //
  // The name underneath is the peer's own designator, so the end has to be
  // attached to a peer for there to be anything under the nick at all: the
  // room accepts a dialer it cannot name, the dialer's own producer speaks for
  // that end, and only then is there a peer for a nickname to sit on top of.
  const convert = makeBaseEventConverter();
  const wire = wireName("7");
  convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p1/live-h1-s1",
    a: "rooms",
    b: "127.0.0.1:0",
    provenance: "unauthenticated",
    session_id: wire,
    codec: "syrup",
  });
  convert({
    v: 1,
    sim_t_ns: 500_000,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s1",
    a: "tab-key",
    b: "rooms",
    provenance: "authenticated-transport",
    session_id: wire,
    codec: "syrup",
  });
  const named = convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-meta",
    session: "p1/live-h1-s1",
    meta: { label: "nick2" },
  });
  const renamed = expectKind(
    named.find((e) => e.kind === "peer-updated" && e.label !== undefined),
    "peer-updated",
  );
  assertEquals(renamed.peerId, "tab-key");
  assertEquals(renamed.label, "nick2");
  const withdrawn = convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "ocapn.session-meta",
    session: "p1/live-h1-s1",
    meta: { label: null },
  });
  assertEquals(withdrawn.length, 1);
  // The designator it joined under, not the nick it last answered to.
  assertEquals(expectKind(withdrawn[0], "peer-updated").label, "tab-key");
});

Deno.test("a wire drawn before its far end could be named learns who is on it", () => {
  // The order that has no order-free answer. A member's own end of a direct
  // session opens FIRST on the accepting side, which cannot name the dialer:
  // a browser tab presents no address it can prove. So the picture draws that
  // end loose — and then the dialer reports the same wire, says who it is, and
  // it is a peer already on stage from its room session. There is nothing
  // derivable from the first observation that would have avoided this, so the
  // picture has to be able to learn.
  //
  // What it must NOT do is report the learning as something the network did.
  // One session opened and stayed open; nobody departed. So the session keeps
  // its identity — the wire name both ends derived — and its end moves onto
  // the peer that spoke for it. Nothing is superseded, because nothing was
  // ever drawn in that peer's place.
  const convert = makeBaseEventConverter();
  const roomWire = wireName("1");
  const dmWire = wireName("2");
  // Both members are on stage from their room sessions.
  for (
    const [scope, self] of [["p1", "alice-key"], ["p2", "bob-key"]] as const
  ) {
    convert({
      v: 1,
      sim_t_ns: 0,
      kind: "ocapn.session-opened",
      session: `${scope}/live-h1-s1`,
      a: self,
      b: "rooms",
      session_id: scope === "p1" ? roomWire : wireName("3"),
      codec: "syrup",
    });
  }
  // Bob accepts a direct session and cannot name who dialed.
  const accepted = convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s2",
    a: "bob-key",
    b: "127.0.0.1:0",
    provenance: "unauthenticated",
    session_id: dmWire,
    codec: "syrup",
  });
  assertEquals(
    accepted.filter((e) => e.kind === "peer-joined").length,
    0,
    "an end nobody could name drew nobody, and bob was already on stage",
  );
  const first = expectKind(
    accepted.find((e) => e.kind === "session-opened"),
    "session-opened",
  );
  // The claim rides the end that carries it, attached to no peer.
  assertEquals(first.b.peer, undefined);
  assertEquals(first.b.designator, "127.0.0.1:0");
  assertEquals(first.b.attributedBy, undefined);
  // Alice reports the same wire, and it is her.
  const dialed = convert({
    v: 1,
    sim_t_ns: 1_100_000,
    kind: "ocapn.session-opened",
    session: "p1/live-h1-s2",
    a: "alice-key",
    b: "bob-key",
    provenance: "authenticated-transport",
    session_id: dmWire,
    codec: "syrup",
  });
  // Nothing the network did: no close, no departure, no second edge, and no
  // new peer, because both ends were already there.
  for (const invented of ["session-closed", "peer-left", "session-opened"]) {
    assertEquals(
      dialed.filter((e) => e.kind === invented).length,
      0,
      `learning who dialed is not a ${invented}`,
    );
  }
  assertEquals(dialed.filter((e) => e.kind === "peer-joined").length, 0);
  // What it IS: the accepting end reported itself as `a`, so the end that
  // could not be named is `b`, and it is alice.
  const moved = expectKind(
    dialed.find((e) => e.kind === "session-endpoint-attributed"),
    "session-endpoint-attributed",
  );
  assertEquals(moved.sessionId, first.sessionId);
  assertEquals(moved.side, "b");
  assertEquals(moved.peerId, "alice-key");
});

Deno.test("the same direct session in the other order needs no redraw", () => {
  // The dialer reporting first names both ends outright, so nothing is drawn
  // that has to be taken back. Both orders end at the same picture.
  const convert = makeBaseEventConverter();
  const dmWire = wireName("4");
  for (
    const [scope, self] of [["p1", "alice-key"], ["p2", "bob-key"]] as const
  ) {
    convert({
      v: 1,
      sim_t_ns: 0,
      kind: "ocapn.session-opened",
      session: `${scope}/live-h1-s1`,
      a: self,
      b: "rooms",
      session_id: wireName(scope === "p1" ? "5" : "6"),
      codec: "syrup",
    });
  }
  const dialed = convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-opened",
    session: "p1/live-h1-s2",
    a: "alice-key",
    b: "bob-key",
    provenance: "authenticated-transport",
    session_id: dmWire,
    codec: "syrup",
  });
  assertEquals(dialed.filter((e) => e.kind === "peer-joined").length, 0);
  const opened = expectKind(
    dialed.find((e) => e.kind === "session-opened"),
    "session-opened",
  );
  assertEquals([opened.a.peer, opened.b.peer].sort(), ["alice-key", "bob-key"]);
  const accepted = convert({
    v: 1,
    sim_t_ns: 1_100_000,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s2",
    a: "bob-key",
    b: "127.0.0.1:0",
    provenance: "unauthenticated",
    session_id: dmWire,
    codec: "syrup",
  });
  assertEquals(accepted.length, 0);
});

Deno.test("a name claimed before an end attaches comes with it", () => {
  // The accepting end annotates the connection with the nick it knows the
  // dialer by, and it does so while that end is still loose — there is no peer
  // yet for the nick to sit on. The claim is about whoever turns out to be
  // there, so it waits on the end and transfers when the end attaches.
  // Dropping it would leave the conversation nameless for no reason.
  const convert = makeBaseEventConverter();
  const dmWire = wireName("8");
  convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p1/live-h1-s1",
    a: "alice-key",
    b: "rooms",
    session_id: wireName("a"),
    codec: "syrup",
  });
  convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s2",
    a: "bob-key",
    b: "127.0.0.1:0",
    provenance: "unauthenticated",
    session_id: dmWire,
    codec: "syrup",
  });
  const claimed = convert({
    v: 1,
    sim_t_ns: 1_500_000,
    kind: "ocapn.session-meta",
    session: "p2/live-h1-s2",
    meta: { label: "alice" },
  });
  assertEquals(
    claimed.length,
    0,
    "a nick for an end with no peer on it renames nobody yet",
  );
  const dialed = convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "ocapn.session-opened",
    session: "p1/live-h1-s2",
    a: "alice-key",
    b: "bob-key",
    provenance: "authenticated-transport",
    session_id: dmWire,
    codec: "syrup",
  });
  // The end attaches to alice, and the nick the accepting end had been holding
  // for it is what she answers to.
  const attached = expectKind(
    dialed.find((e) => e.kind === "session-endpoint-attributed"),
    "session-endpoint-attributed",
  );
  assertEquals(attached.peerId, "alice-key");
  const renamed = dialed.filter((e) => e.kind === "peer-updated" && e.label !== undefined).map((e) =>
    expectKind(e, "peer-updated")
  );
  assertEquals(renamed.map((e) => e.label), ["alice"]);
  assertEquals(renamed[0]?.peerId, "alice-key");
});

Deno.test("an end nobody could name attaches when its own producer speaks", () => {
  // What the stage needs to draw the difference between "someone is on the
  // other end of this wire" and "this is nick2". The accepting end cannot name
  // the dialer, so that end stays loose and carries its claim; when the
  // dialer's own producer reports the wire, the end attaches to it. The moment
  // lands on the SESSION's end, not on a peer, because no peer was invented to
  // have a moment.
  const convert = makeBaseEventConverter();
  const dmWire = wireName("b");
  const accepted = convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s1",
    a: "bob-key",
    b: "127.0.0.1:0",
    provenance: "unauthenticated",
    session_id: dmWire,
    codec: "syrup",
  });
  // Only the reporting host is drawn: it speaks for itself, and nothing
  // speaks for the end it accepted.
  assertEquals(
    accepted.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
    ["bob-key"],
  );
  const opened = expectKind(
    accepted.find((e) => e.kind === "session-opened"),
    "session-opened",
  );
  assertEquals(
    opened.a,
    sessionEndpoint({
      peer: "bob-key",
      designator: "bob-key",
      attributedBy: "self-reported",
    }),
  );
  assertEquals(opened.b, sessionEndpoint({ designator: "127.0.0.1:0" }));

  // The dialer reports the same wire, so the loose end is hers. She is drawn
  // here for the first time — under her own designator, never under the claim
  // the accepting end could not back.
  const dialed = convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-opened",
    session: "p1/live-h1-s1",
    a: "alice-key",
    b: "bob-key",
    provenance: "authenticated-transport",
    session_id: dmWire,
    codec: "syrup",
  });
  assertEquals(
    dialed.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
    ["alice-key"],
  );
  const attached = dialed.filter((e) => e.kind === "session-endpoint-attributed").map((e) =>
    expectKind(e, "session-endpoint-attributed")
  );
  assertEquals(attached.length, 1);
  assertEquals(attached[0]?.sessionId, opened.sessionId);
  assertEquals(attached[0]?.side, "b");
  assertEquals(attached[0]?.peerId, "alice-key");

  // Restating it is not a second moment: the end is already attached.
  const again = convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "ocapn.session-opened",
    session: "p1/live-h1-s2",
    a: "alice-key",
    b: "bob-key",
    provenance: "authenticated-transport",
    session_id: dmWire,
    codec: "syrup",
  });
  assertEquals(
    again.filter((e) => e.kind === "session-endpoint-attributed").length,
    0,
  );
});

/** The stage a run of records leaves behind: who is on it, and which
 * pairs of them a session joins. Two runs that agree here drew the
 * same picture, whatever they said along the way. */
function pictureOf(events: TimelineEvent[]): {
  peers: string[];
  edges: string[];
} {
  const labels = new Map<string, string>();
  const edges = new Map<string, [string, string]>();
  for (const ev of events) {
    switch (ev.kind) {
      case "peer-joined":
        labels.set(ev.peerId, ev.label ?? ev.peerId);
        break;
      case "peer-updated":
        if (ev.label !== undefined) labels.set(ev.peerId, ev.label);
        break;
      case "peer-left":
      case "peer-unobserved":
        labels.delete(ev.peerId);
        break;
      case "session-opened":
        edges.set(ev.sessionId, [
          endpointNodeId(ev.sessionId, "a", ev.a),
          endpointNodeId(ev.sessionId, "b", ev.b),
        ]);
        break;
      case "session-endpoint-attributed": {
        const edge = edges.get(ev.sessionId);
        if (edge !== undefined) edge[ev.side === "a" ? 0 : 1] = ev.peerId;
        break;
      }
      case "session-closed":
        edges.delete(ev.sessionId);
        break;
    }
  }
  return {
    peers: [...labels.entries()].map(([id, label]) => `${id}=${label}`).sort(),
    edges: [...edges.values()].map((e) => [...e].sort().join("–")).sort(),
  };
}

/** One producer's report of one session, as the endpoint carries it.
 *
 * `session` is the producer's own handle, scoped to it. `sessionId` is the
 * OCapN Session ID both ends of that session derive, which is what lets two
 * producers' reports be recognised as one session. */
function opened(
  seq: number,
  session: string,
  self: string,
  partner: string,
  sessionId: string,
  verified: boolean,
  /** `captp` is the negotiated CapTP profile, when a test turns on which
   * one it is, named by this viewer's own tag. A producer reports the
   * handshake's syntax, so the tag is put on the wire through
   * `CAPTP_VERSION_WIRE` rather than written out — one table, and no test
   * has to know it. Left off, the session runs the OCapN v1.0 interop
   * floor, which is what a producer reporting nothing means.
   *
   * `profile` is what the producer STATES it runs, and it is left off by
   * default because that is what the wire looks like when a producer says
   * nothing. A test that means "a pancake host is reporting this" says so,
   * the way a pancake binding says so on every record it publishes. */
  opts: { captp?: BuiltinCaptpVersion; profile?: PeerProfile } = {},
): BaseTimelineEvent {
  return {
    v: 1,
    sim_t_ns: seq * 1_000_000,
    kind: "ocapn.session-opened",
    session,
    a: self,
    b: partner,
    provenance: verified ? "authenticated-transport" : "unauthenticated",
    session_id: sessionId,
    codec: "syrup",
    ...(opts.profile !== undefined && { a_profile: opts.profile }),
    ...(opts.captp !== undefined &&
      { captp_version: CAPTP_VERSION_WIRE[opts.captp] }),
  };
}

/** A room with two members and a direct message between them. Every
 * wire is reported by BOTH of its ends, which is what the endpoint
 * forwards and what a snapshot replays; the accepting end cannot name
 * who dialed it, because a browser tab presents no address it can
 * prove.
 *
 * `accepted` is the order the endpoint's seq gives on a reconnect —
 * the end that could not name its partner first. `dialed` is the same
 * six reports with each wire's naming end first, which is the order
 * that needs no learning: everything is known before it is drawn. */
const ROOM_WIRE_1 = wireName("c");
const ROOM_WIRE_2 = wireName("d");
const DM_WIRE = wireName("e");

/** Every producer here is a pancake host and says so on every record, which
 * is what the bindings do and therefore what the endpoint actually carries. */
const SAYS_PANCAKE = { profile: PANCAKE_PROFILE } as const;

const accepting: BaseTimelineEvent[] = [
  opened(
    0,
    "p0/live-h1-s1",
    "rooms-key",
    "127.0.0.1:0",
    ROOM_WIRE_1,
    false,
    SAYS_PANCAKE,
  ),
  opened(
    2,
    "p0/live-h1-s2",
    "rooms-key",
    "127.0.0.1:0",
    ROOM_WIRE_2,
    false,
    SAYS_PANCAKE,
  ),
  opened(
    4,
    "p2/live-h1-s2",
    "tab2-key",
    "127.0.0.1:0",
    DM_WIRE,
    false,
    SAYS_PANCAKE,
  ),
];
const naming: BaseTimelineEvent[] = [
  opened(
    1,
    "p1/live-h1-s1",
    "tab1-key",
    "rooms-key",
    ROOM_WIRE_1,
    true,
    SAYS_PANCAKE,
  ),
  opened(
    3,
    "p2/live-h1-s1",
    "tab2-key",
    "rooms-key",
    ROOM_WIRE_2,
    true,
    SAYS_PANCAKE,
  ),
  opened(
    5,
    "p1/live-h1-s2",
    "tab1-key",
    "tab2-key",
    DM_WIRE,
    true,
    SAYS_PANCAKE,
  ),
];

function stampedNs(ev: BaseTimelineEvent): number {
  assert(typeof ev.sim_t_ns === "number", "fixture timestamp must be numeric");
  return ev.sim_t_ns;
}

/** Interleaved as the endpoint stamped them: accepting end, then the
 * end that can name it. */
const AS_STAMPED: BaseTimelineEvent[] = [...accepting, ...naming]
  .sort((x, y) => stampedNs(x) - stampedNs(y));

/** The same reports with each wire's naming end first — the order in
 * which nothing has to be learned. */
const NAMING_FIRST: BaseTimelineEvent[] = [...naming, ...accepting];

function runThrough(records: BaseTimelineEvent[]): TimelineEvent[] {
  const convert = makeBaseEventConverter();
  const out: TimelineEvent[] = [];
  for (const ev of records) out.push(...convert(ev));
  return out;
}

Deno.test("a replayed snapshot draws what a feed that never had to learn draws", () => {
  // Stop a recording and start another, and the viewer asks for the topology
  // again. The endpoint answers with every live session's open — and one wire
  // is TWO of those, because both its ends report it. Fed one at a time, that
  // re-runs the live learning sequence: an end drawn loose, then the moment it
  // attached. Live that sequence is honest, because the far end's report had
  // not arrived. On a snapshot it is not: both ends are in the batch before
  // anything is drawn, so there is no moment at which the viewer did not know.
  //
  // The bar is not "no blip" — an absent symptom would also be met by a
  // snapshot path that quietly drew something else. It is that the snapshot
  // lands on exactly the picture a feed draws when it is told the naming end
  // first and never has to learn anything. Same construction, same end state,
  // fewer events.
  const snapshot = makeBaseEventConverter();
  const resolved: TimelineEvent[] = [];
  for (const ev of AS_STAMPED) {
    resolved.push(...snapshot({ ...ev, replay: true }));
  }
  resolved.push(...snapshot({
    v: 1,
    sim_t_ns: 6_000_000,
    kind: "trace.replay-end",
  }));

  assertEquals(
    pictureOf(resolved),
    pictureOf(runThrough(NAMING_FIRST)),
    "a resolved snapshot draws exactly what a feed that never had to learn draws",
  );
  // Three peers and three sessions, so the comparison above is comparing
  // something rather than two empty pictures.
  assertEquals(pictureOf(resolved).peers.length, 3);
  assertEquals(pictureOf(resolved).edges.length, 3);

  // And it says nothing it did not do. These are the viewer's own knowledge
  // events; a batch that held both ends before it drew never learned.
  assertEquals(
    resolved.filter((e) => e.kind === "session-endpoint-attributed").length,
    0,
    "a resolved snapshot has no end attaching to report: it held both ends " +
      "before it drew anything",
  );
  assertEquals(
    resolved.filter((e) => e.kind === "session-opened" && e.b.peer === undefined)
      .length,
    0,
    "a resolved snapshot leaves no end loose: it knew both before it drew",
  );
});

Deno.test("a room whose every end publishes is a room of pancake peers", () => {
  // The case the user actually watches: a room server and two browser tabs,
  // each publishing its own trace, on the OCapN v1.0 floor. Every peer here
  // is some producer's own end, so every peer is known — reached through the
  // snapshot, where the batch holds both ends of each wire before it draws,
  // and through the live order, where the second end has to be learned.
  const snapshot = makeBaseEventConverter();
  const resolved: TimelineEvent[] = [];
  for (const ev of AS_STAMPED) {
    resolved.push(...snapshot({ ...ev, replay: true }));
  }
  resolved.push(...snapshot({
    v: 1,
    sim_t_ns: 6_000_000,
    kind: "trace.replay-end",
  }));

  const drawnAs = joinedProfiles(resolved);
  assertEquals(Object.keys(drawnAs).length, 3);
  assertEquals(
    Object.values(drawnAs).filter((p) => p !== "pancake"),
    [],
    "a snapshot holding every end's own report drew a peer it could not name",
  );

  // Live, the same three peers arrive one report at a time, so one of them is
  // drawn before its own producer has spoken. It is known by the end of the
  // sequence either way — through its join or through the moment it learned.
  const live = runThrough(AS_STAMPED);
  const liveJoined = joinedProfiles(live);
  const learned = new Set(
    live.flatMap((e) => e.kind === "peer-updated" && e.profile !== undefined ? [e.peerId] : []),
  );
  for (const [peer, joined] of Object.entries(liveJoined)) {
    assert(
      joined === "pancake" || learned.has(peer),
      `${peer} publishes its own trace and is still not known to be pancake`,
    );
  }
});

Deno.test("the same reports arriving live still learn, and say so", () => {
  // The contrast the test above rests on. Fed one at a time in the order the
  // endpoint stamped them, the very same reports DO make the viewer learn —
  // so the snapshot's silence is a property of the batch, not of the records.
  const live = runThrough(AS_STAMPED);
  assert(
    live.some((e) => e.kind === "session-endpoint-attributed"),
    "a live feed told the accepting end first has to learn who dialed",
  );
  assert(
    live.some((e) =>
      e.kind === "session-opened" && e.b.peer === undefined &&
      e.b.designator !== undefined
    ),
    "and it holds that end loose, carrying the claim, until it does",
  );
  // Same topology either way: three peers, three edges. What differs is only
  // that the live path had to be told the second half.
  assertEquals(pictureOf(live).edges.length, 3);
  assertEquals(pictureOf(live).peers.length, 3);
});

Deno.test("an empty snapshot, and a batch nobody closes, both land", () => {
  // Two shapes the boundary has to survive. A viewer connecting to an idle
  // endpoint gets the mark with nothing before it. And a producer predating
  // the mark sends a batch nobody closes — the first live record draws it,
  // because a held batch that never renders is worse than one drawn early.
  const idle = makeBaseEventConverter();
  assertEquals(
    idle({ v: 1, sim_t_ns: 0, kind: "trace.replay-end" }),
    [],
    "an empty batch draws nothing and does not throw",
  );
  // The endpoint is live afterwards, and behaves.
  const after = idle(
    opened(1, "p0/s1", "rooms-key", "tab1-key", ROOM_WIRE_1, true),
  );
  assertEquals(after.filter((e) => e.kind === "session-opened").length, 1);

  const unclosed = makeBaseEventConverter();
  assertEquals(
    unclosed({
      ...opened(0, "p0/s1", "rooms-key", "tab1-key", ROOM_WIRE_1, true),
      replay: true,
    }),
    [],
    "a replayed record waits for the end of its batch",
  );
  const flushed = unclosed(
    opened(1, "p1/s1", "tab1-key", "tab2-key", DM_WIRE, true),
  );
  // Both the held open and the live one are drawn, held one first.
  const opens = flushed.filter((e) => e.kind === "session-opened");
  assertEquals(
    opens.length,
    2,
    "the held batch is drawn before the live record",
  );
});

Deno.test("a producer restarting discards the batch it never finished", () => {
  // A batch describes the topology of ONE producer process. If that process
  // is replaced while its batch is still held, the sessions in it died with
  // it and its wire names may now belong to something else — so drawing it
  // into the new epoch would materialize exactly the ghosts the epoch change
  // exists to clear.
  const convert = makeBaseEventConverter();
  assertEquals(
    convert({
      ...opened(0, "p0/s1", "rooms-key", "tab1-key", ROOM_WIRE_1, true),
      epoch: 1,
      replay: true,
    }),
    [],
    "the batch is held",
  );
  // The endpoint restarted. Nothing of the old process survives.
  const afterRestart = convert({
    ...opened(1, "p0/s1", "rooms-key", "tab2-key", ROOM_WIRE_2, true),
    epoch: 2,
  });
  const opens = afterRestart.filter((e) => e.kind === "session-opened");
  assertEquals(opens.length, 1, "only the new epoch's session is drawn");
  assertEquals(
    afterRestart.filter((e) => e.kind === "peer-joined" && e.peerId === "tab1-key").length,
    0,
    "a peer from the dead process's batch was drawn into the new epoch",
  );
});

Deno.test("a feed that never ends its batch cannot grow it without limit", () => {
  // Everything on this feed is attacker-controlled until it is read: the
  // viewer dials the endpoint. A feed that marked records `replay` forever
  // would otherwise buffer for the connection's life. Past the bound the held
  // records are DRAWN rather than dropped — losing topology silently would be
  // worse than drawing it early and having to learn an end.
  const convert = makeBaseEventConverter();
  let drawn = 0;
  for (let i = 0; i < 9000; i += 1) {
    drawn += convert({
      ...opened(i, `p0/s${i}`, "rooms-key", `tab${i}-key`, wireName("f"), true),
      replay: true,
    }).length;
  }
  assert(drawn > 0, "a batch past the bound was never drawn");
});

Deno.test("a producer's later sessions hang off the node its end attached to", () => {
  // The defect that survived the first fix. A claim is scoped to ONE wire, so
  // nothing else may be filed under it — but a producer that spoke for a
  // wire-scoped row used to leave a pointer at it, and every later session it
  // opened was drawn against that row. When the row eventually merged away,
  // those other sessions were joined to a peer whose row had ended, so they
  // visibly closed the moment the picture improved. That is exactly the
  // falsehood this vocabulary exists to delete, surviving one hop out. Nothing
  // is filed under a claim now, which is what removes the class rather than
  // the instance.
  const convert = makeBaseEventConverter();
  const roomWire = wireName("e");
  const otherWire = wireName("f");
  // The room accepts a dialer it cannot name.
  convert(opened(0, "p0/s1", "rooms-key", "127.0.0.1:0", roomWire, false));
  // The dialer's own producer speaks for that end, and that is the first time
  // anything is drawn for it — under its own designator, never the claim.
  const spoke = convert(
    opened(1, "p1/s1", "tab1-key", "rooms-key", roomWire, true),
  );
  assertEquals(
    spoke.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
    ["tab1-key"],
  );
  const attached = expectKind(
    spoke.find((e) => e.kind === "session-endpoint-attributed"),
    "session-endpoint-attributed",
  );
  assertEquals(attached.peerId, "tab1-key");

  // That same producer now opens a second wire to someone else. Its own end
  // is the node the first wire's end attached to.
  const second = convert(
    opened(2, "p1/s2", "tab1-key", "other-key", otherWire, true),
  );
  assertEquals(
    expectKind(
      second.find((e) => e.kind === "session-opened"),
      "session-opened",
    ).a.peer,
    "tab1-key",
  );
  // A third producer reports the FIRST wire. Both its ends are known, so
  // there is nothing here to learn — and crucially nothing that could end the
  // node the second wire is drawn against.
  const third = convert(
    opened(3, "p2/s1", "other-key", "rooms-key", roomWire, true),
  );
  for (
    const invented of [
      "session-endpoint-attributed",
      "session-closed",
      "peer-left",
      "peer-unobserved",
    ]
  ) {
    assertEquals(
      third.filter((e) => e.kind === invented).length,
      0,
      `a wire whose ends are both known produced a ${invented}`,
    );
  }
  // The second wire still joins the two nodes it was drawn between.
  const picture = pictureOf([...spoke, ...second, ...third]);
  assert(
    picture.edges.includes(["other-key", "tab1-key"].sort().join("–")),
    "the later session lost the node it was drawn against",
  );
});

Deno.test("a producer leaving takes its view, not the conversation", () => {
  // The last leak of the defect this vocabulary exists for. A telemetry
  // socket dropping is a fact about the FEED. The conversation it was
  // reporting may have ended, or may be running happily with nobody
  // watching — from here those are indistinguishable, so saying
  // `session-closed` picks one and states it as protocol fact.
  const convert = makeBaseEventConverter();
  convert(opened(0, "p1/s1", "tab1-key", "rooms-key", wireName("g"), true));
  const gone = convert({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "trace.producer-left",
    scope: "p1",
  });
  const kinds = gone.map((e) => e.kind);
  assert(
    kinds.includes("session-unobserved"),
    "the session the departing producer was showing went out of view",
  );
  for (const invented of ["session-closed", "peer-left"]) {
    assertEquals(
      kinds.filter((k) => k === invented).length,
      0,
      `losing sight of a conversation is not a ${invented}`,
    );
  }
});

Deno.test("a wire another producer still watches survives one leaving", () => {
  // The refcount that makes the above safe: an end going dark is not the
  // conversation ending, and the peer still reporting it is still reporting
  // it. Only the LAST observer going takes the wire off stage.
  const convert = makeBaseEventConverter();
  const shared = wireName("h");
  convert(opened(0, "p0/s1", "rooms-key", "127.0.0.1:0", shared, false));
  convert(opened(1, "p1/s1", "tab1-key", "rooms-key", shared, true));
  const gone = convert({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "trace.producer-left",
    scope: "p1",
  });
  assertEquals(
    gone.filter((e) => e.kind === "session-unobserved" || e.kind === "session-closed").length,
    0,
    "a wire the room server still reports stayed on stage",
  );
});

Deno.test("a peer named by a designator records it as its identifier", () => {
  // A peer's public identifier is the durable name it answers to, as
  // against the name it is shown by. The live feed has that fact — it is
  // what `verified` proves, and it is the key the ledger files the row
  // under — and used to spend it on the label alone. A room then renamed
  // the peer to a nickname and the designator was gone from the picture,
  // which is the one fact that made this end attributable at all.
  const convert = makeBaseEventConverter();
  const wire = wireName("g");
  const joins = convert(
    opened(0, "p0/s1", "rooms-key", "tab1-key", wire, true),
  );
  const byId = new Map(
    joins.filter((e) => e.kind === "peer-joined").map((
      e,
    ) => [expectKind(e, "peer-joined").label, expectKind(e, "peer-joined")]),
  );
  for (const name of ["rooms-key", "tab1-key"]) {
    const joined = byId.get(name);
    assert(joined !== undefined, `${name} did not join`);
    assertEquals(
      joined.designator,
      name,
      `${name} joined without recording the designator it was filed under`,
    );
  }

  // A later rename states a NAME. The identifier is not a name, so it does
  // not move — that is the whole point of keeping the two apart.
  const renamed = convert({
    v: 1,
    kind: "rooms.member-named",
    session: "p0/s1",
    nick: "nick1",
    t: 5,
  } as unknown as BaseTimelineEvent);
  for (const ev of renamed) {
    assertEquals(
      (ev as { designator?: string }).designator,
      undefined,
      "a rename restated an identifier",
    );
  }
});

Deno.test("an unproven claim never becomes anyone's identifier", () => {
  // The other half: a name nothing backed is a claim about an end, not a
  // designator anyone answers to. It lives on the endpoint that carries it and
  // reaches no peer — recording it as an identifier would state the very fact
  // the loose end exists to say is missing.
  const convert = makeBaseEventConverter();
  const wire = wireName("h");
  const first = convert(
    opened(0, "p0/s1", "rooms-key", "127.0.0.1:0", wire, false),
  );
  const loose = expectKind(
    first.find((e) => e.kind === "session-opened"),
    "session-opened",
  );
  assertEquals(loose.b, sessionEndpoint({ designator: "127.0.0.1:0" }));
  assertEquals(
    first.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
    ["rooms-key"],
    "the claim drew a peer",
  );

  // Its own producer now speaks for it. The end attaches to that producer's
  // peer, and that peer arrives carrying the designator it answers to —
  // stated once, on the join that draws it, because the ledger only ever
  // draws a peer under a name somebody stated (`ensurePeer`).
  const spoke = convert(
    opened(1, "p1/s1", "tab1-key", "rooms-key", wire, true),
  );
  const named = spoke.filter((e) => (e as { designator?: string }).designator !== undefined);
  assertEquals(
    named.length,
    1,
    "the attached peer never stated its designator, or stated it twice",
  );
  assertEquals(expectKind(named[0], "peer-joined").designator, "tab1-key");

  // And a nickname arriving afterwards is a NAME. It must not carry an
  // identifier, because that is the fact a nickname would otherwise
  // erase — the whole reason the two are kept apart.
  const renamed = convert({
    v: 1,
    kind: "rooms.member-named",
    session: "p1/s1",
    nick: "nick1",
    t: 9,
  } as unknown as BaseTimelineEvent);
  for (const ev of renamed) {
    assertEquals(
      (ev as { designator?: string }).designator,
      undefined,
      "a nickname restated an identifier",
    );
  }

  // Over the whole run: the claim reached no peer at all, by any route. It is
  // neither anyone's identifier nor anyone's stage id nor anyone's name.
  for (const ev of [...first, ...spoke, ...renamed]) {
    const row = ev as { designator?: string; peerId?: string; label?: string };
    for (const field of [row.designator, row.peerId, row.label]) {
      assert(
        field !== "127.0.0.1:0",
        `${ev.kind} carried the unproven claim as a peer fact`,
      );
    }
  }
});

Deno.test("no end the feed draws is attributed to nobody", () => {
  // The endpoint model's one-way invariant, held over a whole feed rather than
  // one record: `attributedBy` present means `peer` present, because nothing
  // can attribute an end to nobody. The converse is what makes it one-way, and
  // it is deliberate — an authored scenario attaches a peer with no
  // measurement to report, and so does a feed whose producer named its partner
  // and stated no verdict about it (the test below holds that end of it). Every
  // producer here states a verdict, so every end this feed draws is either
  // attributed or loose.
  //
  // Its mirror is the fact the whole model exists for: an end with a
  // `designator` and no `attributedBy` carries no peer, so a claim nothing
  // backed can never quietly become an identity.
  const convert = makeBaseEventConverter();
  const roomWire = wireName("i");
  const dmWire = wireName("j");
  const seen: TimelineEvent[] = [];
  const feed = (ev: BaseTimelineEvent) => seen.push(...convert(ev));
  // A room accepts two tabs it cannot name, each tab then speaks for
  // itself, and the two tabs open a direct session to each other.
  feed(opened(0, "p0/s1", "rooms-key", "127.0.0.1:0", roomWire, false));
  feed(opened(1, "p1/s1", "tab1-key", "rooms-key", roomWire, true));
  feed(opened(2, "p2/s1", "tab2-key", "tab1-key", dmWire, true));
  feed(opened(3, "p1/s2", "tab1-key", "tab2-key", dmWire, true));

  let attributed = 0;
  let loose = 0;
  for (const ev of seen) {
    if (ev.kind !== "session-opened") continue;
    for (const [side, end] of [["a", ev.a], ["b", ev.b]] as const) {
      if (end.attributedBy !== undefined) {
        attributed += 1;
        assert(
          end.peer !== undefined,
          `${ev.sessionId} side ${side} was attributed by ` +
            `${end.attributedBy} and named no peer`,
        );
        continue;
      }
      loose += 1;
      assertEquals(
        end.peer,
        undefined,
        `${ev.sessionId} side ${side} drew a peer nothing attributed it to`,
      );
      assert(
        end.designator !== undefined,
        `${ev.sessionId} side ${side} is loose and carries no claim either`,
      );
    }
  }
  // Both arms ran, so neither passed over an empty set.
  assert(attributed > 0, "no end was attributed at all");
  assert(loose > 0, "no end was left loose at all");
});

/** What each peer was drawn as, by stage id. */
function joinedProfiles(evs: readonly TimelineEvent[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const ev of evs) {
    if (ev.kind === "peer-joined") out[ev.peerId] = ev.profile;
  }
  return out;
}

/** Every profile a `peer-updated` stated, in order, as `peer@t=profile`. */
function profileUpdates(evs: readonly TimelineEvent[]): string[] {
  const out: string[] = [];
  for (const ev of evs) {
    if (ev.kind === "peer-updated" && ev.profile !== undefined) {
      out.push(`${ev.peerId}@${ev.t}=${ev.profile}`);
    }
  }
  return out;
}

Deno.test("a producer's own end runs what it says it runs", () => {
  // A producer states its implementation beside the designator it calls
  // itself by, and that statement is the whole of what names its own end.
  // What is on the FAR end of an OCapN v1.0 session is a different question
  // the record does not answer, so that end stays unknown.
  const convert = makeBaseEventConverter();
  const out = convert(
    opened(0, "p0/s1", "rooms-key", "vat-key", "wire-1", true, {
      profile: PANCAKE_PROFILE,
    }),
  );
  assertEquals(joinedProfiles(out), {
    "rooms-key": PANCAKE_PROFILE,
    "vat-key": UNNAMED_PROFILE,
  });
});

Deno.test("a Goblins vat publishing its own trace draws as a Goblins vat", () => {
  // The `ocapn.*` kinds are a schema, not pancake's mark: the Goblins
  // conformance peer publishes the very same records. Its own end is drawn
  // as what it says it is, and the stage has to be able to say `goblins`
  // when a producer says `goblins` — the whole point of reading a statement
  // instead of guessing at one.
  const convert = makeBaseEventConverter();
  const out = convert(
    opened(0, "p0/s1", "vat-key", "rooms-key", "wire-1", true, {
      profile: GOBLINS_PROFILE,
    }),
  );
  assertEquals(joinedProfiles(out), {
    "vat-key": GOBLINS_PROFILE,
    "rooms-key": UNNAMED_PROFILE,
  });
});

Deno.test("a producer that states nothing draws its OWN end unknown", () => {
  // The defect this whole property exists to refuse, at the site it lived:
  // the viewer used to read "a record arrived" as "a pancake host sent it",
  // so every producer's own end was drawn pancake whatever it ran. A
  // producer that says nothing has said nothing about itself, and unknown
  // is the honest answer for a pancake producer and any other alike.
  const convert = makeBaseEventConverter();
  const out = convert(
    opened(0, "p0/s1", "rooms-key", "vat-key", "wire-1", true),
  );
  assertEquals(joinedProfiles(out), {
    "rooms-key": UNNAMED_PROFILE,
    "vat-key": UNNAMED_PROFILE,
  });
  // And nothing arrives later to fill it in either: a second session from
  // the same silent producer is one more record that said nothing.
  assertEquals(
    profileUpdates(
      convert(opened(500, "p0/s2", "rooms-key", "other-key", "wire-2", true)),
    ),
    [],
  );
});

Deno.test("an implementation this build has never heard of is drawn as itself", () => {
  // `PeerProfile` is any non-empty string on purpose, because OCapN is
  // implementation-plural and the set of implementations is not this
  // viewer's to close. A third implementation naming itself is drawn under
  // the name it gave, not folded into unknown.
  const convert = makeBaseEventConverter();
  const out = convert(
    opened(0, "p0/s1", "vat-key", "rooms-key", "wire-1", true, {
      profile: "some-other-captp",
    }),
  );
  assertEquals(joinedProfiles(out)["vat-key"], "some-other-captp");
});

Deno.test("a non-string implementation claim is ignored", () => {
  // The profile field is open-ended, but it is still a string field on a JSON
  // feed. A producer that sends a number has not named a future
  // implementation; it sent invalid data, so the peer stays unknown.
  const convert = makeBaseEventConverter();
  const out = convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p0/s1",
    a: "vat-key",
    b: "rooms-key",
    session_id: "wire-1",
    provenance: "authenticated-transport",
    codec: "syrup",
    a_profile: 1,
  });
  assertEquals(joinedProfiles(out)["vat-key"], UNNAMED_PROFILE);
});

Deno.test("a session on the pancake-private profile names both its ends", () => {
  // `pancake-next` travels only between pancake peers (ADR-0003), so one
  // producer reporting it has said what runs at each end. It is the one
  // implementation a feed concludes without being told, so it holds even
  // when the producer stated nothing about itself.
  const convert = makeBaseEventConverter();
  const out = convert(
    opened(0, "p0/s1", "rooms-key", "member-key", "wire-1", true, {
      captp: "next",
    }),
  );
  assertEquals(joinedProfiles(out), {
    "rooms-key": PANCAKE_PROFILE,
    "member-key": PANCAKE_PROFILE,
  });
});

Deno.test("the v1.0 floor names neither of its ends", () => {
  // The converse of the profile above, and the reason it is not read: two
  // pancake peers meeting on the OCapN interop floor speak `v1_0`, exactly
  // as a Goblins vat does. A session on it says nothing about either end,
  // so a feed that carries no statement draws two unknowns.
  const convert = makeBaseEventConverter();
  const out = convert(
    opened(0, "p0/s1", "rooms-key", "member-key", "wire-1", true, {
      captp: "v1_0",
    }),
  );
  assertEquals(joinedProfiles(out), {
    "rooms-key": UNNAMED_PROFILE,
    "member-key": UNNAMED_PROFILE,
  });
});

Deno.test("a partner nobody speaks for is never credited with an implementation", () => {
  // The defect this whole property guards against is the stage answering a
  // question the feed never asked. A v1.0 partner that publishes nothing has
  // to stay unknown for as long as the feed runs, however much traffic
  // crosses the session.
  const convert = makeBaseEventConverter();
  const out = [
    ...convert(opened(0, "p0/s1", "rooms-key", "vat-key", "wire-1", true)),
    ...convert({
      v: 1,
      sim_t_ns: 20_000_000,
      kind: "ocapn.message-decoded",
      session: "p0/s1",
      outbound: true,
      op: "op:deliver",
    }),
    ...convert({
      v: 1,
      sim_t_ns: 40_000_000,
      kind: "ocapn.session-closed",
      session: "p0/s1",
    }),
  ];
  assertEquals(joinedProfiles(out)["vat-key"], UNNAMED_PROFILE);
  assertEquals(profileUpdates(out), []);
});

Deno.test("a peer learns what it runs when it first speaks for itself", () => {
  // The rooms case: one host reports a member before that member has
  // published anything, so the member is drawn as somebody else's partner and
  // nothing yet says what it runs. When the member's own trace arrives it has
  // stated its implementation, and that lands as a moment on its trajectory —
  // the join keeps saying what was known then.
  const convert = makeBaseEventConverter();
  const first = convert(
    opened(0, "p0/s1", "rooms-key", "member-key", "wire-1", true, SAYS_PANCAKE),
  );
  assertEquals(joinedProfiles(first)["member-key"], UNNAMED_PROFILE);

  const later = convert(
    opened(
      750,
      "p1/s1",
      "member-key",
      "other-key",
      "wire-2",
      true,
      SAYS_PANCAKE,
    ),
  );
  assertEquals(profileUpdates(later), ["member-key@750=pancake"]);
  // Learning is not a re-join: the peer keeps the one lifetime it had.
  assertEquals(
    later.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
    ["other-key"],
  );
});

Deno.test("a named partner that then reports the same wire is known from there", () => {
  // A room server whose transport authenticated the member's durable name
  // draws that member straight away — named, but with nothing yet saying what
  // it runs. When the member publishes its own side of that same session it
  // states its implementation, and the second report of one wire is the only
  // thing that carries the statement. There is no new peer and no new edge
  // here, so the learning has nowhere else to land.
  const convert = makeBaseEventConverter();
  const first = convert(
    opened(
      0,
      "p0/s1",
      "rooms-key",
      "member-key",
      "shared-wire",
      true,
      SAYS_PANCAKE,
    ),
  );
  assertEquals(joinedProfiles(first)["member-key"], UNNAMED_PROFILE);

  const second = convert(
    opened(
      600,
      "p1/s1",
      "member-key",
      "rooms-key",
      "shared-wire",
      true,
      SAYS_PANCAKE,
    ),
  );
  assertEquals(second.filter((e) => e.kind === "peer-joined"), []);
  assertEquals(profileUpdates(second), ["member-key@600=pancake"]);
});

Deno.test("an end a second producer speaks for is drawn as what that producer says it runs", () => {
  // Two browser tabs in a room, the shape the endpoint actually carries.
  // Neither can name the other: a tab dials as an ephemeral client and has no
  // listening address to prove, so the first report leaves its far end loose.
  // The second producer says it is that end AND says what it runs, so the end
  // attaches to a peer that is known from the moment it is drawn — known
  // because of the second half of that sentence, never the first.
  const convert = makeBaseEventConverter();
  const first = convert(
    opened(0, "p0/s1", "tab-a", "claimed:0", "shared-wire", false, {
      profile: PANCAKE_PROFILE,
    }),
  );
  assertEquals(joinedProfiles(first), { "tab-a": PANCAKE_PROFILE });

  const second = convert(
    opened(400, "p1/s1", "tab-b", "claimed:0", "shared-wire", false, {
      profile: GOBLINS_PROFILE,
    }),
  );
  // Speaking for the loose end draws the peer, and it is drawn as what its
  // own producer said — a Goblins vat here, which the old rule could not
  // have reported however loudly the vat said it.
  assertEquals(joinedProfiles(second), { "tab-b": GOBLINS_PROFILE });
  // Both ends now sit on peers, and neither had to learn anything after.
  assertEquals(profileUpdates(second), []);
});

Deno.test("speaking for a loose end says who is there, never what is there", () => {
  // The same shape with the second producer silent. It still attaches to the
  // end nobody could name — that is a fact about identity — and the peer it
  // draws stays unknown, because attaching an end is not a statement about
  // what runs on it.
  const convert = makeBaseEventConverter();
  convert(opened(0, "p0/s1", "tab-a", "claimed:0", "shared-wire", false));
  const second = convert(
    opened(400, "p1/s1", "tab-b", "claimed:0", "shared-wire", false),
  );
  assertEquals(joinedProfiles(second), { "tab-b": UNNAMED_PROFILE });
  assertEquals(profileUpdates(second), []);
  // The end really did attach: this is the loose-end path, not a miss.
  assertEquals(
    second.filter((e) => e.kind === "session-endpoint-attributed").length,
    1,
  );
});

Deno.test("restating what a peer runs is not a moment on its trajectory", () => {
  // A producer reports every session it holds, and a busy host holds many.
  // Only the moment the viewer LEARNED belongs on the trajectory; the same
  // rule the ledger holds for a name it has already been told.
  const convert = makeBaseEventConverter();
  const out = [
    ...convert(
      opened(0, "p0/s1", "host-key", "peer-key", "wire-1", true, {
        captp: "next",
      }),
    ),
    ...convert(
      opened(900, "p0/s2", "host-key", "peer-key", "wire-2", true, {
        captp: "next",
      }),
    ),
  ];
  assertEquals(profileUpdates(out), []);
});

Deno.test("an end says what actually backed it, and nothing when nothing did", () => {
  // The stage may state only what the feed measured. Three producers report
  // three sessions and the far end of each is attached for a different reason,
  // so each end has to say a different thing.
  const convert = makeBaseEventConverter();
  const open = (
    session: string,
    partner: string,
    provenance: string | undefined,
  ) =>
    expectKind(
      convert({
        v: 1,
        sim_t_ns: 0,
        kind: "ocapn.session-opened",
        session,
        a: "rooms-key",
        b: partner,
        codec: "syrup",
        ...(provenance !== undefined ? { provenance } : {}),
      }).find((e) => e.kind === "session-opened"),
      "session-opened",
    );
  // A verdict the producer measured is carried across in its own words.
  assertEquals(
    open("p0/s1", "alice-key", "authenticated-transport").b.attributedBy,
    "authenticated-transport",
  );
  // A producer that named its partner and said nothing about proof measured
  // nothing. The end still attaches — somebody named it — but the viewer has
  // no attribution to offer, and inventing one would be the stage reporting a
  // measurement that never happened.
  const silent = open("p0/s2", "bob-key", undefined);
  assertEquals(silent.b.peer, "bob-key");
  assertEquals(
    silent.b.attributedBy,
    undefined,
    "a producer that stated no verdict had one attributed to it",
  );
  // A word out of a vocabulary this viewer does not know proved nothing
  // either, so the end stays loose with its claim on it.
  const unknown = open("p0/s3", "carol-key", "vouched-for-by-a-friend");
  assertEquals(unknown.b.peer, undefined);
  assertEquals(unknown.b.designator, "carol-key");
  assertEquals(unknown.b.attributedBy, undefined);
});

Deno.test("an end two producers agreed on says the viewer correlated it", () => {
  // The one attribution the viewer awards itself. A room cannot name the tab
  // that dialed it; the tab's own report of the same wire can, and a snapshot
  // holds both before anything is drawn. That is a correlation across two
  // self-reports rather than a proof, and the end says so in the weakest word
  // the vocabulary has.
  const convert = makeBaseEventConverter();
  const wire = wireName("k");
  const out: TimelineEvent[] = [];
  out.push(...convert({
    ...opened(0, "p0/s1", "rooms-key", "127.0.0.1:0", wire, false),
    replay: true,
  }));
  out.push(...convert({
    ...opened(1, "p1/s1", "tab-key", "rooms-key", wire, true),
    replay: true,
  }));
  out.push(...convert({ v: 1, sim_t_ns: 2_000_000, kind: "trace.replay-end" }));
  const room = expectKind(
    out.find((e) => e.kind === "session-opened"),
    "session-opened",
  );
  assertEquals(room.b.peer, "tab-key");
  assertEquals(room.b.attributedBy, "viewer-correlated");
});

Deno.test("the netlayer a session runs over reaches the stage", () => {
  // A designator is half a name: the same key reached over `iroh` and
  // over `keyed-relay` is two locators, so the producer reports the
  // transport beside it and the viewer has to carry it across. The
  // Inspector reads it off this observation, so dropping it here is
  // the whole difference between a session that names its netlayer
  // and one that says nothing about it.
  const convert = makeBaseEventConverter();
  const out = convert({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p0/s1",
    a: "alice-key",
    b: "bob-key",
    transport: "iroh",
    codec: "syrup",
  });
  const session = expectKind(out[2], "session-opened");
  assertEquals(session.transport, "iroh");
  // And it survives the schema, which is where a live document is
  // eventually read back from.
  assertEquals(Observation.parse(session).kind, "session-opened");
});

Deno.test("a producer that names no netlayer leaves the field off", () => {
  // The field is optional because a producer predating it reports
  // sessions and nothing else changed about them. Absent has to stay
  // absent rather than becoming an empty netlayer name: `""` is not a
  // transport, and a document carrying one would show a blank row
  // where the honest answer is no row.
  const convert = makeBaseEventConverter();
  const older = expectKind(
    convert({
      v: 1,
      sim_t_ns: 0,
      kind: "ocapn.session-opened",
      session: "p0/s1",
      a: "alice-key",
      b: "bob-key",
      codec: "syrup",
    })[2],
    "session-opened",
  );
  assert(
    !("transport" in older),
    "a producer that reported no transport minted no transport field",
  );
  assertEquals(Observation.parse(older).kind, "session-opened");
  // A producer that sends the field empty said the same thing.
  const empty = expectKind(
    convert({
      v: 1,
      sim_t_ns: 0,
      kind: "ocapn.session-opened",
      session: "p0/s2",
      a: "alice-key",
      b: "carol-key",
      transport: "",
      codec: "syrup",
    })[1],
    "session-opened",
  );
  assert(
    !("transport" in empty),
    "an empty transport is no transport, not a netlayer called ''",
  );
  const nonString = expectKind(
    convert({
      v: 1,
      sim_t_ns: 0,
      kind: "ocapn.session-opened",
      session: "p0/s3",
      a: "alice-key",
      b: "dave-key",
      transport: 1,
      codec: "syrup",
    })[1],
    "session-opened",
  );
  assert(
    !("transport" in nonString),
    "a non-string transport is invalid data, not a future netlayer",
  );
});

// ─────────────────────── dialing and its channels ───────────────────────

Deno.test("connect: an invalid sturdyref is reported, not thrown", () => {
  const feed = new LiveFeed("w");
  const seen: string[] = [];
  feed.onError((e) => seen.push(e.detail));
  feed.connect();
  assertEquals(seen.length, 1);
  assert(
    seen[0]!.includes('"w"'),
    `the report names the value; got ${seen[0]}`,
  );
  feed.disconnect();
});

Deno.test("startLiveMode: an invalid sturdyref still returns a live handle", () => {
  const seen: string[] = [];
  const handle = startLiveMode({
    sturdyref: "ws:/",
    onError: (e) => seen.push(e.detail),
  });
  assertEquals(seen.length, 1);
  assert(handle.engine.doc.id === "live");
  handle.dispose();
});

type ControlledPeer = {
  closeCount: number;
  finish: () => void;
};

function controlledFactory(): {
  factory: LivePeerFactory;
  peers: ControlledPeer[];
  records: Array<(line: string) => void>;
} {
  const peers: ControlledPeer[] = [];
  const records: Array<(line: string) => void> = [];
  const factory: LivePeerFactory = (_ref, onRecord) => {
    let finish!: () => void;
    const closed = new Promise<void>((resolve) => finish = resolve);
    const control: ControlledPeer = { closeCount: 0, finish };
    peers.push(control);
    records.push(onRecord);
    return Promise.resolve({
      closed,
      close: () => {
        control.closeCount += 1;
        finish();
      },
    });
  };
  return { factory, peers, records };
}

Deno.test("disconnect closes the exact peer once and a late close reaches nobody", async () => {
  const controlled = controlledFactory();
  const feed = new LiveFeed(
    "ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
    controlled.factory,
  );
  let connected: boolean | null = null;
  feed.onConnectionChange((v) => connected = v);
  feed.connect();
  await Promise.resolve();
  assertEquals(connected, true);
  feed.disconnect();
  assertEquals(controlled.peers[0]?.closeCount, 1);
  connected = null;
  controlled.peers[0]?.finish();
  await Promise.resolve();
  assertEquals(
    connected,
    null,
    "a disposed feed wrote its close into a live subscriber",
  );
});

Deno.test("onConnectionChange: the unsubscribe releases the slot", async () => {
  const controlled = controlledFactory();
  const feed = new LiveFeed(
    "ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
    controlled.factory,
  );
  let connected: boolean | null = null;
  const off = feed.onConnectionChange((v) => connected = v);
  feed.connect();
  off();
  await Promise.resolve();
  assertEquals(connected, null);
  feed.disconnect();
});

Deno.test("records arrive through the hosted inbox callback", async () => {
  const controlled = controlledFactory();
  const feed = new LiveFeed(
    "ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
    controlled.factory,
  );
  const seen: TimelineEvent[] = [];
  feed.subscribe((ev) => seen.push(ev));
  feed.connect();
  await Promise.resolve();
  controlled.records[0]?.(JSON.stringify({
    v: 1,
    sim_t_ns: 0,
    seq: 10,
    epoch: 1,
    kind: "ocapn.session-opened",
    session: "p0/s1",
    a: "rooms",
    b: "alice",
    codec: "syrup",
  }));
  assertEquals(seen.filter((ev) => ev.kind === "session-opened").length, 1);
  feed.disconnect();
});

Deno.test("old replay sequence numbers still form an authoritative snapshot", async () => {
  const controlled = controlledFactory();
  const feed = new LiveFeed(
    "ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
    controlled.factory,
  );
  const seen: TimelineEvent[] = [];
  feed.subscribe((ev) => seen.push(ev));
  feed.connect();
  await Promise.resolve();
  const open = {
    v: 1,
    sim_t_ns: 0,
    seq: 10,
    epoch: 1,
    kind: "ocapn.session-opened",
    session: "p0/s1",
    a: "rooms",
    b: "alice",
    codec: "syrup",
  };
  controlled.records[0]?.(JSON.stringify(open));
  controlled.records[0]?.(JSON.stringify({ ...open, replay: true }));
  controlled.records[0]?.(JSON.stringify({
    v: 1,
    sim_t_ns: 1_000_000,
    epoch: 1,
    kind: "trace.replay-end",
  }));
  assertEquals(
    seen.filter((ev) => ev.kind === "session-unobserved").length,
    0,
    "stale-sequence suppression discarded current snapshot state",
  );
  feed.disconnect();
});

Deno.test({
  name: "a dropped peer reconnects with a fresh session and inbox",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const controlled = controlledFactory();
    const feed = new LiveFeed(
      "ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
      controlled.factory,
    );
    const states: boolean[] = [];
    feed.onConnectionChange((connected) => states.push(connected));
    feed.connect();
    await Promise.resolve();
    controlled.peers[0]?.finish();
    await new Promise((resolve) => setTimeout(resolve, 550));
    await Promise.resolve();
    assertEquals(controlled.peers.length, 2);
    assert(controlled.records[0] !== controlled.records[1]);
    assertEquals(states, [true, false, true]);
    feed.disconnect();
    assertEquals(controlled.peers[1]?.closeCount, 1);
  },
});

const browserWasm = new URL(
  "../../../../zig-out/wasm/pancake_host.wasm",
  import.meta.url,
);
let browserWasmExists = true;
try {
  await Deno.stat(browserWasm);
} catch (error) {
  if (error instanceof Deno.errors.NotFound) browserWasmExists = false;
  else throw error;
}

Deno.test({
  name: "the lazy wasm browser peer enlivens, subscribes, and receives a live record",
  ignore: !browserWasmExists,
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const root = new URL("../../../../", import.meta.url);
    const hostScript = new URL(
      "../../../rooms/test/viz_browser_host.ts",
      import.meta.url,
    );
    const child = new Deno.Command(Deno.execPath(), {
      args: ["run", "-A", hostScript.pathname],
      cwd: root.pathname,
      stdout: "piped",
      stderr: "inherit",
    }).spawn();
    const reader = child.stdout.getReader();
    let wasmObjectUrl: string | null = null;
    let feed: LiveFeed | null = null;
    let publisher: WebSocket | null = null;
    try {
      const ready = await readJsonLine(reader) as {
        port: number;
        sturdyref: string;
      };
      const registry = globalThis as Record<symbol, unknown>;
      const adapterKey = Symbol.for("pancake.runtime.adapter");
      assertEquals(
        registry[adapterKey],
        undefined,
        "importing LiveFeed eagerly initialized the browser runtime",
      );

      const wasm = await Deno.readFile(browserWasm);
      wasmObjectUrl = URL.createObjectURL(
        new Blob([wasm], { type: "application/wasm" }),
      );
      (globalThis as { __OCV_PANCAKE_WASM_URL?: string })
        .__OCV_PANCAKE_WASM_URL = wasmObjectUrl;
      const webModuleName: string = "@pancake/web";
      (globalThis as {
        __OCV_PANCAKE_WEB_LOADER?: () => Promise<PancakeWebModule>;
      }).__OCV_PANCAKE_WEB_LOADER = () => import(webModuleName) as unknown as Promise<PancakeWebModule>;

      let connected!: () => void;
      const didConnect = new Promise<void>((resolve) => connected = resolve);
      feed = new LiveFeed(ready.sturdyref);
      let fail!: (cause: unknown) => void;
      const didFail = new Promise<never>((_, reject) => fail = reject);
      feed.onError((error) => fail(error.cause ?? new Error(error.detail)));
      feed.onConnectionChange((value) => {
        if (value) connected();
      });
      const received: TimelineEvent[] = [];
      let sawSession!: () => void;
      const didReceive = new Promise<void>((resolve) => sawSession = resolve);
      feed.subscribe((event) => {
        received.push(event);
        if (event.kind === "session-opened") sawSession();
      });
      feed.connect();
      await Promise.race([didConnect, didFail]);
      assert(
        registry[adapterKey] !== undefined,
        "Live mode did not initialize wasm",
      );

      publisher = new WebSocket(`ws://127.0.0.1:${ready.port}/publish`);
      await new Promise<void>((resolve, reject) => {
        publisher!.onopen = () => resolve();
        publisher!.onerror = () => reject(new Error("publisher did not open"));
      });
      publisher.send(JSON.stringify({
        v: 1,
        sim_t_ns: 0,
        kind: "ocapn.session-opened",
        session: "browser-proof-s1",
        a: "rooms",
        b: "alice",
        codec: "syrup",
      }));
      await Promise.race([didReceive, didFail]);
      assertEquals(
        received.filter((event) => event.kind === "session-opened").length,
        1,
      );
    } finally {
      publisher?.close();
      feed?.disconnect();
      delete (globalThis as { __OCV_PANCAKE_WASM_URL?: string })
        .__OCV_PANCAKE_WASM_URL;
      delete (globalThis as { __OCV_PANCAKE_WEB_LOADER?: unknown })
        .__OCV_PANCAKE_WEB_LOADER;
      if (wasmObjectUrl !== null) URL.revokeObjectURL(wasmObjectUrl);
      reader.releaseLock();
      try {
        child.kill("SIGTERM");
      } catch {
        // already exited
      }
      await child.status;
    }
  },
});

async function readJsonLine(
  reader: ReadableStreamDefaultReader<Uint8Array>,
): Promise<unknown> {
  const decoder = new TextDecoder();
  let buffered = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) {
      throw new Error("viz host exited before announcing its capability");
    }
    buffered += decoder.decode(value, { stream: true });
    const newline = buffered.indexOf("\n");
    if (newline >= 0) return JSON.parse(buffered.slice(0, newline));
  }
}

// ─────────────────────────── what a feed retains ────────────────────────

Deno.test("a feed gives back what a closed conversation cost it", () => {
  const state = newFeedState();
  const push = (ev: BaseTimelineEvent) => convertEvent(ev, state);
  const N = 8;
  for (let i = 0; i < N; i++) {
    push({
      v: 1,
      sim_t_ns: i * 1_000_000,
      kind: "ocapn.session-opened",
      session: `p0/s${i}`,
      a: "alice-key",
      b: `bob-key-${i}`,
      session_id: `wire-${i}`,
      codec: "syrup",
    });
    // The partner is named before anything can wear the name, so each
    // conversation also parks a loose claim on its wire.
    push({
      v: 1,
      sim_t_ns: i * 1_000_000 + 1,
      kind: "ocapn.session-meta",
      session: `p0/s${i}`,
      meta: { label: `nick-${i}` },
    });
  }
  assertEquals(state.sessionsOfScope.get("p0")?.size, N);
  for (let i = 0; i < N; i++) {
    push({
      v: 1,
      sim_t_ns: (N + i) * 1_000_000,
      kind: "ocapn.session-closed",
      session: `p0/s${i}`,
    });
  }
  assertEquals(
    state.sessionsOfScope.size,
    0,
    "a producer's set of watched sessions outlived the sessions",
  );
  assertEquals(
    state.ledger.wires.size,
    0,
    "a closed wire stayed on the ledger",
  );
});

Deno.test("a producer restarting takes its per-scope rows with it", () => {
  const state = newFeedState();
  const push = (ev: BaseTimelineEvent) => convertEvent(ev, state);
  push({
    v: 1,
    sim_t_ns: 0,
    epoch: 1,
    kind: "ocapn.session-opened",
    session: "p0/s1",
    a: "alice-key",
    b: "bob-key",
    session_id: "wire-1",
    codec: "syrup",
  });
  assertEquals(state.sessionsOfScope.size, 1);
  assertEquals(state.hostOfScope.size, 1);
  // A new process. Its predecessor's scopes will never be spoken for
  // again, so nothing about them may be kept.
  push({ v: 1, sim_t_ns: 1_000_000, epoch: 2, kind: "trace.replay-end" });
  assertEquals(state.sessionsOfScope.size, 0);
  assertEquals(state.hostOfScope.size, 0);
});

Deno.test("a feed that ends leaves the ledger holding nothing", () => {
  // The refcount statement, said once over the shape that exercises every
  // retain the ledger takes: a wire watched from both ends, a side nobody
  // could name that a second producer later speaks for, a name claimed for
  // that side before it attached, a message folded across both sightings, and
  // a peer that leaves and comes back. Each of those retains something, and
  // the only honest proof they all release is that the ledger is empty when
  // the conversations and the producers are gone.
  const state = newFeedState();
  const push = (ev: BaseTimelineEvent) => convertEvent(ev, state);
  const dm = wireName("8");

  // A room, a member's own producer, and a second member.
  push({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session: "p1/live-h1-s1",
    a: "rooms",
    b: "127.0.0.1:0",
    provenance: "unauthenticated",
    session_id: wireName("A"),
    codec: "syrup",
  });
  push({
    v: 1,
    sim_t_ns: 1_000_000,
    kind: "ocapn.session-meta",
    session: "p1/live-h1-s1",
    meta: { label: "carol" },
  });
  // The member's own producer speaks for the end the room could not name.
  push({
    v: 1,
    sim_t_ns: 2_000_000,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s1",
    a: "carol-key",
    b: "rooms",
    session_id: wireName("A"),
    codec: "syrup",
  });
  // A direct conversation, reported by both of its ends, carrying one message
  // both of them see.
  push({
    v: 1,
    sim_t_ns: 3_000_000,
    kind: "ocapn.session-opened",
    session: "p2/live-h1-s2",
    a: "carol-key",
    b: "dave-key",
    session_id: dm,
    codec: "syrup",
  });
  push({
    v: 1,
    sim_t_ns: 4_000_000,
    kind: "ocapn.session-opened",
    session: "p3/live-h1-s1",
    a: "dave-key",
    b: "carol-key",
    session_id: dm,
    codec: "syrup",
  });
  for (const session of ["p2/live-h1-s2", "p3/live-h1-s1"]) {
    push({
      v: 1,
      sim_t_ns: 5_000_000,
      kind: "ocapn.message-decoded",
      session,
      outbound: session.startsWith("p2"),
      op: "dm",
      digest: "aabbccddeeff00112233445566778899",
    });
  }
  // Three conversations are live and three parties are drawn: the room, the
  // member whose own producer spoke for the end the room could not name, and
  // the member it is talking to directly. A claim nobody proved drew nobody,
  // so there is no fourth.
  assertEquals(
    [...state.ledger.peers.keys()].sort(),
    ["carol-key", "dave-key", "rooms"],
    "the ledger is holding somebody it should not be",
  );

  // Everything closes, and every producer goes.
  for (
    const session of [
      "p1/live-h1-s1",
      "p2/live-h1-s1",
      "p2/live-h1-s2",
      "p3/live-h1-s1",
    ]
  ) {
    push({
      v: 1,
      sim_t_ns: 6_000_000,
      kind: "ocapn.session-closed",
      session,
    });
  }
  for (const scope of ["p1", "p2", "p3"]) {
    push({ v: 1, sim_t_ns: 7_000_000, kind: "trace.producer-left", scope });
  }

  assertEquals(state.ledger.wires.size, 0, "a wire outlived its last observer");
  assertEquals(
    [...state.ledger.peers.keys()],
    [],
    "a peer outlived every wire touching it and its own producer",
  );
  assertEquals(state.sessionsOfScope.size, 0);
  assertEquals(state.hostOfScope.size, 0);
});
