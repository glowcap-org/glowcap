// What a feed retains, and what closing a conversation gives back.

import { assertEquals } from "@std/assert";
import { convertEvent, newFeedState } from "../feed.ts";
import { type BaseTimelineEvent } from "../record.ts";
import { wireName } from "./fixtures.ts";

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
