import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "../timeline.ts";
import { extractClipboardPayload } from "./extract.ts";
import { cascadePaste } from "./paste.ts";
import { primaryObservations } from "../temporal/recording-access.ts";

function twoPeerOneSession(): TimelineDocument {
  return TimelineDocument.parse({
    id: "doc-1",
    duration: 1000,
    events: [
      {
        id: "e1",
        t: 0,
        kind: "peer-joined",
        peerId: "alice",
        profile: "agent",
      },
      { id: "e2", t: 0, kind: "peer-joined", peerId: "bob", profile: "agent" },
      {
        id: "e3",
        t: 10,
        kind: "session-opened",
        sessionId: "s1",
        a: { peer: "alice" },
        b: { peer: "bob" },
        codec: "capnp",
        captpVersion: "v1_0",
      },
    ],
  });
}

// ─── extractClipboardPayload ─────────────────────────────────────

Deno.test("extract: peer-only selection captures peer + its events", () => {
  const doc = twoPeerOneSession();
  const payload = extractClipboardPayload(doc, {
    peers: new Set(["alice"]),
  });
  assert(payload.entities.peers?.alice);
  assertEquals(payload.entities.sessions, undefined);
  // peer-joined + session-opened (because session-opened.a references alice).
  const kinds = payload.events.map((e) => e.kind).sort();
  assertEquals(kinds, ["peer-joined", "session-opened"]);
  // bob and s1 are external refs (referenced by session-opened but not selected).
  const ext = payload.externalRefs.map((r) => `${r.kind}:${r.id}`).sort();
  assertEquals(ext, ["peer:bob", "session:s1"]);
  assertEquals(payload.minT, 0);
});

Deno.test("extract: session-only selection drags both endpoint peers as external", () => {
  const doc = twoPeerOneSession();
  const payload = extractClipboardPayload(doc, {
    sessions: new Set(["s1"]),
  });
  assert(payload.entities.sessions?.s1);
  assertEquals(payload.entities.peers, undefined);
  // session-opened is the only event referencing s1.
  assertEquals(payload.events.map((e) => e.kind), ["session-opened"]);
  // alice + bob are external.
  const ext = payload.externalRefs.map((r) => `${r.kind}:${r.id}`).sort();
  assertEquals(ext, ["peer:alice", "peer:bob"]);
});

Deno.test("extract: whole-doc selection has no external refs", () => {
  const doc = twoPeerOneSession();
  const payload = extractClipboardPayload(doc, {
    peers: new Set(["alice", "bob"]),
    sessions: new Set(["s1"]),
  });
  assertEquals(payload.externalRefs, []);
  assertEquals(payload.events.length, 3);
});

// ─── cascadePaste ────────────────────────────────────────────────

Deno.test("paste: copying peer alice from one doc to another mints a non-colliding peer", () => {
  const source = twoPeerOneSession();
  const payload = extractClipboardPayload(source, {
    peers: new Set(["alice"]),
  });
  // Strip externals so the payload pastes cleanly.
  const sanitized = {
    ...payload,
    events: payload.events.filter((e) => e.kind === "peer-joined"),
    externalRefs: [],
  };

  const target = TimelineDocument.parse({
    id: "doc-target",
    duration: 100,
    events: [],
  });
  const r = cascadePaste(target, sanitized, 0);
  assert(r.ok);
  assertEquals(r.value.remap.peer.get("alice"), "alice"); // no collision
  assert(r.value.doc.entities?.peers?.alice);
});

Deno.test("paste: collision suffixes through -copy, -copy-2, ...", () => {
  const source = twoPeerOneSession();
  const payload = extractClipboardPayload(source, {
    peers: new Set(["alice"]),
  });
  const sanitized = {
    ...payload,
    events: payload.events.filter((e) => e.kind === "peer-joined"),
    externalRefs: [],
  };

  // Target already has `alice` and `alice-copy`.
  const target = TimelineDocument.parse({
    id: "doc-target",
    duration: 100,
    events: [
      {
        id: "x1",
        t: 0,
        kind: "peer-joined",
        peerId: "alice",
        profile: "agent",
      },
      {
        id: "x2",
        t: 0,
        kind: "peer-joined",
        peerId: "alice-copy",
        profile: "agent",
      },
    ],
  });
  const r = cascadePaste(target, sanitized, 0);
  assert(r.ok);
  assertEquals(r.value.remap.peer.get("alice"), "alice-copy-2");
  assert(r.value.doc.entities?.peers?.["alice-copy-2"]);
  // Original alice and alice-copy preserved.
  assert(r.value.doc.entities?.peers?.alice);
  assert(r.value.doc.entities?.peers?.["alice-copy"]);
});

Deno.test("paste: external ref missing in target → validation error", () => {
  const source = twoPeerOneSession();
  // Select s1 only; alice/bob become external.
  const payload = extractClipboardPayload(source, {
    sessions: new Set(["s1"]),
  });

  // Target has no peers at all.
  const target = TimelineDocument.parse({
    id: "doc-target",
    duration: 100,
    events: [],
  });
  const r = cascadePaste(target, payload, 0);
  assert(!r.ok);
  assertEquals(r.error.code, "validation");
  assert(r.error.detail.includes("alice"));
  assert(r.error.detail.includes("bob"));
});

Deno.test("paste: external ref resolves when target already has the entity", () => {
  const source = twoPeerOneSession();
  const payload = extractClipboardPayload(source, {
    sessions: new Set(["s1"]),
  });

  // Target has alice + bob (so s1's endpoints resolve to existing peers).
  const target = TimelineDocument.parse({
    id: "doc-target",
    duration: 100,
    events: [
      {
        id: "x1",
        t: 0,
        kind: "peer-joined",
        peerId: "alice",
        profile: "agent",
      },
      { id: "x2", t: 0, kind: "peer-joined", peerId: "bob", profile: "agent" },
    ],
  });
  const r = cascadePaste(target, payload, 0);
  assert(r.ok);
  // Session inherits the existing peers — its endpoints are NOT remapped.
  assertEquals(r.value.doc.entities?.sessions?.s1?.a?.peer, "alice");
  assertEquals(r.value.doc.entities?.sessions?.s1?.b?.peer, "bob");
});

Deno.test("paste: time offset shifts pasted events to playhead", () => {
  const source = twoPeerOneSession();
  // Select session — pulls the session-opened event at t=10.
  const payload = extractClipboardPayload(source, {
    sessions: new Set(["s1"]),
  });
  assertEquals(payload.minT, 10);

  const target = TimelineDocument.parse({
    id: "doc-target",
    duration: 1000,
    events: [
      {
        id: "x1",
        t: 0,
        kind: "peer-joined",
        peerId: "alice",
        profile: "agent",
      },
      { id: "x2", t: 0, kind: "peer-joined", peerId: "bob", profile: "agent" },
    ],
  });

  // Paste at playhead t=500. Session-opened should land at 500 (was 10,
  // offset by 500-10=490).
  const r = cascadePaste(target, payload, 500);
  assert(r.ok);
  const opened = primaryObservations(r.value.doc).find((e) =>
    e.kind === "session-opened"
  );
  assertEquals(opened?.t, 500);
});

Deno.test("paste: round-trip preserves the doc when copying everything", () => {
  const source = twoPeerOneSession();
  const payload = extractClipboardPayload(source, {
    peers: new Set(["alice", "bob"]),
    sessions: new Set(["s1"]),
  });

  // Paste into an empty target at t=0.
  const target = TimelineDocument.parse({
    id: "doc-empty",
    duration: 1000,
    events: [],
  });
  const r = cascadePaste(target, payload, 0);
  assert(r.ok);
  const result = r.value.doc;

  // All three entities present with the same shapes.
  assertEquals(result.entities?.peers?.alice?.profile, "agent");
  assertEquals(result.entities?.peers?.bob?.profile, "agent");
  assertEquals(result.entities?.sessions?.s1?.a?.peer, "alice");
  assertEquals(result.entities?.sessions?.s1?.b?.peer, "bob");

  // Three pasted events; the session-opened was at t=10, offset by
  // 0-0=0 (minT is 0 because peer-joined events at t=0 dominate).
  assertEquals(primaryObservations(result).length, 3);
});

Deno.test("paste: every pasted event id is one nothing else answers to", () => {
  const source = twoPeerOneSession();
  const payload = extractClipboardPayload(source, {
    peers: new Set(["alice"]),
  });
  const sanitized = {
    ...payload,
    events: payload.events.filter((e) => e.kind === "peer-joined"),
    externalRefs: [],
  };
  const target = TimelineDocument.parse({
    id: "doc-target",
    duration: 100,
    events: [
      {
        id: "x1",
        t: 0,
        kind: "peer-joined",
        peerId: "carol",
        profile: "agent",
      },
    ],
  });
  // Pasting the SAME clipboard twice is the case that matters, and it
  // is one keypress away: an unconditional `-copy` suffix answers the
  // second paste with the id the first one already took. Ids are how
  // `moveEvent` and the focus halo address an event, so two events
  // wearing one id means dragging the second retimes the first.
  const first = cascadePaste(target, sanitized, 0);
  assert(first.ok);
  const second = cascadePaste(first.value.doc, sanitized, 0);
  assert(second.ok);
  const ids = primaryObservations(second.value.doc).map((e) => e.id);
  assertEquals(
    new Set(ids).size,
    ids.length,
    `two events share an id: ${ids.join(", ")}`,
  );
  // The target's own event is untouched, and each paste landed one
  // peer-joined of its own.
  assertEquals(ids.length, 3);
  assert(ids.includes("x1"));
});
