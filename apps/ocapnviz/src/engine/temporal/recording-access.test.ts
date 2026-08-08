import { assert, assertEquals } from "@std/assert";
import type { TimelineDocument } from "../timeline.ts";
import { TimelineDocument as Doc } from "../timeline.ts";
import {
  observationsOf,
  primaryObservations,
  sourcesOf,
} from "./recording-access.ts";

function emptyDoc(): TimelineDocument {
  return Doc.parse({
    id: "test",
    duration: 100,
  });
}

Deno.test("observationsOf: empty doc returns empty list", () => {
  assertEquals(observationsOf(emptyDoc()), []);
});

Deno.test("observationsOf: flat input events project into recording on parse", () => {
  const doc = Doc.parse({
    id: "test",
    duration: 100,
    events: [{
      id: "e1",
      kind: "peer-joined",
      t: 5,
      peerId: "alice",
      profile: "pancake",
    }],
  });
  const obs = observationsOf(doc);
  assertEquals(obs.length, 1);
  assertEquals(obs[0]!.kind, "peer-joined");
});

Deno.test("observationsOf: recording wins when both events and recording supplied", () => {
  const doc = Doc.parse({
    id: "test",
    duration: 100,
    // Flat-input event ignored when recording is present.
    events: [{
      id: "old",
      kind: "peer-joined",
      t: 99,
      peerId: "ignored",
      profile: "pancake",
    }],
    recording: {
      sources: [{
        id: "live",
        meta: { kind: "pancake-host" },
        observations: [{
          id: "n1",
          kind: "peer-joined",
          t: 5,
          peerId: "alice",
          profile: "pancake",
        }],
      }],
    },
  });
  const obs = observationsOf(doc);
  assertEquals(obs.length, 1);
  assertEquals(obs[0]!.id, "n1");
});

Deno.test("observationsOf: multi-source flattens in source-declaration order", () => {
  const doc = Doc.parse({
    id: "test",
    duration: 100,
    recording: {
      sources: [
        {
          id: "live",
          meta: { kind: "pancake-host" },
          observations: [
            {
              id: "a",
              kind: "peer-joined",
              t: 1,
              peerId: "alice",
              profile: "pancake",
            },
            { id: "b", kind: "peer-left", t: 10, peerId: "alice" },
          ],
        },
        {
          id: "enterprise",
          meta: { kind: "griddle" },
          observations: [{
            id: "c",
            kind: "peer-joined",
            t: 2,
            peerId: "bob",
            profile: "pancake",
          }],
        },
      ],
    },
  });
  const obs = observationsOf(doc);
  assertEquals(obs.map((o) => o.id), ["a", "b", "c"]);
});

Deno.test("sourcesOf: flat input events project into a single 'input' source", () => {
  const doc = Doc.parse({
    id: "test",
    duration: 100,
    events: [{
      id: "e1",
      kind: "peer-joined",
      t: 5,
      peerId: "alice",
      profile: "pancake",
    }],
  });
  const sources = sourcesOf(doc);
  assertEquals(sources.length, 1);
  assertEquals(sources[0]!.id, "input");
  assertEquals(sources[0]!.meta.kind, "input");
  assertEquals(sources[0]!.observations.length, 1);
});

Deno.test("sourcesOf: recording layer surfaces verbatim", () => {
  const doc = Doc.parse({
    id: "test",
    duration: 100,
    recording: {
      sources: [
        { id: "live", meta: { kind: "pancake-host" }, observations: [] },
        {
          id: "enterprise",
          meta: { kind: "griddle", version: "0.3.1" },
          observations: [],
        },
      ],
    },
  });
  const sources = sourcesOf(doc);
  assertEquals(sources.length, 2);
  assertEquals(sources[1]!.meta.version, "0.3.1");
});

Deno.test("primaryObservations: lazy-creates a primary source on empty doc", () => {
  const doc = emptyDoc();
  assertEquals(doc.recording, undefined);
  const obs = primaryObservations(doc);
  assertEquals(obs.length, 0);
  // After the call, the doc gained a primary source.
  assertEquals(doc.recording?.sources.length, 1);
  assertEquals(doc.recording?.sources[0]?.id, "primary");
});

Deno.test("observationsOf: the same document answers with the same list", () => {
  // The property the render path rests on. A reader that caches on what it
  // got back has to be able to tell "nothing changed" from "everything did,
  // rebuild"; handing out a fresh array per call makes every frame look like
  // a change, and the timeline's lane stack rebuilt 60 times a second for a
  // document nobody was touching.
  const doc = Doc.parse({
    id: "test",
    duration: 100,
    events: [{
      id: "e1",
      kind: "peer-joined",
      t: 5,
      peerId: "alice",
      profile: "pancake",
    }],
  });
  assert(
    observationsOf(doc) === observationsOf(doc),
    "an untouched document handed back two different lists",
  );
  assert(
    observationsOf(emptyDoc()) === observationsOf(emptyDoc()),
    "two empty documents disagreed about what nothing looks like",
  );
});

Deno.test("observationsOf: appending to a source is a new list", () => {
  // The other half: sameness is only worth anything if difference still
  // reads as difference. A live feed appends to the array it already has, so
  // identity alone would never notice it.
  const doc = Doc.parse({ id: "test", duration: 100, events: [] });
  const before = observationsOf(doc);
  primaryObservations(doc).push({
    id: "e1",
    kind: "peer-joined",
    t: 5,
    peerId: "alice",
    profile: "pancake",
  });
  const after = observationsOf(doc);
  assertEquals(before.length, 0);
  assertEquals(after.length, 1);
});

Deno.test("observationsOf: several sources flatten once, and again when one grows", () => {
  const doc = Doc.parse({
    id: "test",
    duration: 100,
    recording: {
      sources: [
        {
          id: "a",
          meta: { kind: "pancake-host" },
          observations: [{
            id: "e1",
            kind: "peer-joined",
            t: 1,
            peerId: "alice",
            profile: "pancake",
          }],
        },
        {
          id: "b",
          meta: { kind: "pancake-host" },
          observations: [{
            id: "e2",
            kind: "peer-joined",
            t: 2,
            peerId: "bob",
            profile: "pancake",
          }],
        },
      ],
    },
  });
  const first = observationsOf(doc);
  assertEquals(first.length, 2);
  assert(
    first === observationsOf(doc),
    "an untouched multi-source document flattened twice",
  );
  doc.recording!.sources[1]!.observations.push({
    id: "e3",
    kind: "peer-joined",
    t: 3,
    peerId: "carol",
    profile: "pancake",
  });
  const grown = observationsOf(doc);
  assertEquals(grown.length, 3);
  assertEquals(grown.map((o) => o.id), ["e1", "e2", "e3"]);
});
