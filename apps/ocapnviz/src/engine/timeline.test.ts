import { assert, assertEquals } from "@std/assert";
import { observationsInRange, TimelineDocument } from "./timeline.ts";
import { observationsOf } from "./temporal/recording-access.ts";

const goodDoc = TimelineDocument.parse({
  id: "test",
  duration: 5000,
  events: [
    { id: "e1", t: 0, kind: "peer-joined", peerId: "a", profile: "pancake" },
    { id: "e2", t: 1000, kind: "peer-joined", peerId: "b", profile: "goblins" },
    {
      id: "e3",
      t: 2000,
      kind: "session-opened",
      sessionId: "s1",
      a: { peer: "a" },
      b: { peer: "b" },
      codec: "syrup",
      captpVersion: "v1_0",
    },
  ],
});

Deno.test("TimelineDocument accepts a well-formed document", () => {
  // Post-parse, observations live in recording.sources, projected
  // by the schema's .transform from the input `events: [...]`.
  assertEquals(observationsOf(goodDoc).length, 3);
});

Deno.test(
  "TimelineDocument parse transform populates entities from observation payloads",
  () => {
    // Identity from `peer-joined`, `session-opened`, `message-sent`
    // events flows into `doc.entities.{peers, sessions, messages}`
    // automatically so callers can read identity from one source
    // post-parse instead of falling back to event payloads.
    const doc = TimelineDocument.parse({
      id: "test",
      duration: 5000,
      events: [
        {
          id: "e1",
          t: 0,
          kind: "peer-joined",
          peerId: "alice",
          profile: "pancake",
          label: "Alice",
        },
        {
          id: "e2",
          t: 0,
          kind: "peer-joined",
          peerId: "bob",
          profile: "goblins",
        },
        {
          id: "e3",
          t: 100,
          kind: "session-opened",
          sessionId: "s1",
          a: { peer: "alice" },
          b: { peer: "bob" },
          codec: "capnp",
          captpVersion: "v1_0",
          initialState: "open",
        },
        {
          id: "e4",
          t: 200,
          kind: "message-sent",
          messageId: "m1",
          sessionId: "s1",
          from: "alice",
          to: "bob",
          arrivalT: 250,
          label: "hello",
        },
      ],
    });
    assertEquals(doc.entities?.peers?.alice?.profile, "pancake");
    assertEquals(doc.entities?.peers?.alice?.label, "Alice");
    assertEquals(doc.entities?.peers?.bob?.profile, "goblins");
    assertEquals(doc.entities?.sessions?.s1?.a?.peer, "alice");
    assertEquals(doc.entities?.sessions?.s1?.codec, "capnp");
    assertEquals(doc.entities?.messages?.m1?.from, "alice");
    // flightMs is no longer a separate field on MessageDefinition;
    // flight time lives in timing.duration after projection.
    assertEquals(doc.entities?.messages?.m1?.label, "hello");
  },
);

Deno.test(
  "TimelineDocument parse transform leaves entities entries authored by hand alone",
  () => {
    // Explicit `entities` entries win over event-payload values
    // — the transform only fills GAPS, never overwrites. Allows
    // the user to author a different identity (label, profile)
    // in entities even if an observation still carries the old.
    const doc = TimelineDocument.parse({
      id: "test",
      duration: 5000,
      events: [
        {
          id: "e1",
          t: 0,
          kind: "peer-joined",
          peerId: "alice",
          profile: "pancake",
          label: "Alice from event",
        },
      ],
      entities: {
        peers: {
          alice: { profile: "goblins", label: "Alice from entities" },
        },
      },
    });
    assertEquals(doc.entities?.peers?.alice?.profile, "goblins");
    assertEquals(doc.entities?.peers?.alice?.label, "Alice from entities");
  },
);

Deno.test(
  "TimelineDocument parse leaves entities undefined for doc with no event payloads",
  () => {
    const doc = TimelineDocument.parse({
      id: "test",
      duration: 0,
      events: [],
    });
    assertEquals(doc.entities, undefined);
  },
);

Deno.test("TimelineDocument rejects out-of-order events", () => {
  const result = TimelineDocument.safeParse({
    id: "bad",
    duration: 5000,
    events: [
      {
        id: "e1",
        t: 2000,
        kind: "peer-joined",
        peerId: "a",
        profile: "pancake",
      },
      {
        id: "e2",
        t: 1000,
        kind: "peer-joined",
        peerId: "b",
        profile: "pancake",
      },
    ],
  });
  assertEquals(result.success, false);
  if (!result.success) {
    assert(
      result.error.issues.some((i) => i.message.includes("sorted by t")),
    );
  }
});

Deno.test("TimelineDocument rejects events beyond duration", () => {
  const result = TimelineDocument.safeParse({
    id: "bad",
    duration: 1000,
    events: [
      {
        id: "e1",
        t: 2000,
        kind: "peer-joined",
        peerId: "a",
        profile: "pancake",
      },
    ],
  });
  assertEquals(result.success, false);
});

Deno.test("TimelineDocument rejects duplicate event ids", () => {
  const result = TimelineDocument.safeParse({
    id: "bad",
    duration: 5000,
    events: [
      { id: "e1", t: 0, kind: "peer-joined", peerId: "a", profile: "pancake" },
      {
        id: "e1",
        t: 1000,
        kind: "peer-joined",
        peerId: "b",
        profile: "pancake",
      },
    ],
  });
  assertEquals(result.success, false);
});

Deno.test("TimelineDocument validates event-kind discriminant", () => {
  const result = TimelineDocument.safeParse({
    id: "bad",
    duration: 5000,
    events: [
      { id: "e1", t: 0, kind: "ghost-arrived" },
    ],
  });
  assertEquals(result.success, false);
});

Deno.test("observationsInRange returns half-open slice", () => {
  const all = observationsInRange(goodDoc, 0, 5000);
  assertEquals(all.length, 3);

  const middle = observationsInRange(goodDoc, 500, 2000);
  assertEquals(middle.map((e) => e.id), ["e2"]);

  const before = observationsInRange(goodDoc, 0, 1);
  assertEquals(before.map((e) => e.id), ["e1"]);

  const after = observationsInRange(goodDoc, 3000, 5000);
  assertEquals(after.length, 0);
});

Deno.test("observationsInRange treats fromT inclusive, toT exclusive", () => {
  const exactly = observationsInRange(goodDoc, 1000, 2000);
  assertEquals(exactly.map((e) => e.id), ["e2"]);
});

// rowOrder + rowHidden are additive optional per-category fields
// for the Flash-grade timeline (PR 1). Fixtures predating them
// must continue to parse identically.

Deno.test("TimelineDocument accepts rowOrder (additive optional field)", () => {
  const parsed = TimelineDocument.parse({
    id: "t",
    duration: 1000,
    events: [],
    rowOrder: {
      peers: ["alice", "carol", "bob"],
    },
  });
  assertEquals(parsed.rowOrder?.peers, ["alice", "carol", "bob"]);
  // Categories omitted from the literal are undefined, not [].
  assertEquals(parsed.rowOrder?.sessions, undefined);
});

Deno.test("TimelineDocument accepts rowHidden (additive optional field)", () => {
  const parsed = TimelineDocument.parse({
    id: "t",
    duration: 1000,
    events: [],
    rowHidden: { messages: ["msg-1"] },
  });
  assertEquals(parsed.rowHidden?.messages, ["msg-1"]);
});

Deno.test("TimelineDocument: absent rowOrder / rowHidden stays absent", () => {
  // Pre-PR-1 fixtures don't have these fields. Parser leaves them
  // undefined; it doesn't auto-fill with empty objects (which
  // would clutter round-trips).
  const parsed = TimelineDocument.parse({
    id: "t",
    duration: 1000,
    events: [],
  });
  assertEquals(parsed.rowOrder, undefined);
  assertEquals(parsed.rowHidden, undefined);
});

Deno.test("TimelineDocument: events is optional in input — recording-only docs parse", () => {
  // A recording-only doc carries observations in `recording.sources`
  // and shouldn't have to ship an empty `events: []` alongside.
  // Post-parse, observations live only in the recording layer.
  const parsed = TimelineDocument.parse({
    id: "t",
    duration: 1000,
    recording: {
      sources: [{
        id: "primary",
        meta: { kind: "authored" },
        observations: [],
      }],
    },
  });
  assertEquals(parsed.recording?.sources.length, 1);
  assertEquals(observationsOf(parsed).length, 0);
});

Deno.test("TimelineDocument: input events project into recording.sources[0]", () => {
  // Flat input shape — events at the doc root — gets projected
  // into `recording.sources[0]` by the schema's .transform, and
  // the events field is stripped from the runtime shape.
  const parsed = TimelineDocument.parse({
    id: "t",
    duration: 1000,
    events: [
      {
        id: "e1",
        t: 0,
        kind: "peer-joined",
        peerId: "alice",
        profile: "pancake",
      },
    ],
  });
  assertEquals(parsed.recording?.sources.length, 1);
  assertEquals(parsed.recording?.sources[0]?.id, "input");
  assertEquals(observationsOf(parsed).length, 1);
});
