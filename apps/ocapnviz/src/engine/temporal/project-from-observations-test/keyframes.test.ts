/**
 * Keyframe tracks projected from observations, including that the
 * second run over the same stream is the same document.
 */

import { assertEquals } from "@std/assert";
import { attachedEndpoint } from "../../../schema/session-end.ts";
import type { TimelineDocument } from "../../timeline.ts";
import { projectFromObservations } from "../project-from-observations.ts";
import { emptyDoc, withEvents } from "./harness.ts";

Deno.test("project: session-state-changed observations → keyframes.state track", () => {
  const doc: TimelineDocument = withEvents({
    ...emptyDoc(),
    entities: {
      sessions: {
        s1: {
          a: attachedEndpoint("alice"),
          b: attachedEndpoint("bob"),
          codec: "capnp",
          captpVersion: "v1_0",
        },
      },
    },
  }, [
    {
      id: "e1",
      kind: "session-state-changed",
      t: 10,
      sessionId: "s1",
      state: "open",
    },
    {
      id: "e2",
      kind: "session-state-changed",
      t: 15,
      sessionId: "s1",
      state: "draining",
    },
  ]);
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.sessions?.s1?.keyframes?.state, [
    { t: 10, value: "open" },
    { t: 15, value: "draining" },
  ]);
});

Deno.test("project: reads from recording.sources", () => {
  const doc: TimelineDocument = {
    ...emptyDoc(),
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
    entities: { peers: { alice: { profile: "pancake" } } },
  };
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.peers?.alice?.timing, {
    start: { value: 5, explicit: true },
    duration: { value: 0, explicit: false },
    derived: true,
  });
});

Deno.test("project: keyframes projection is idempotent", () => {
  const doc: TimelineDocument = withEvents({
    ...emptyDoc(),
    entities: {
      sessions: {
        s1: {
          a: attachedEndpoint("alice"),
          b: attachedEndpoint("bob"),
          codec: "capnp",
          captpVersion: "v1_0",
        },
      },
    },
  }, [{
    id: "e1",
    kind: "session-state-changed",
    t: 10,
    sessionId: "s1",
    state: "open",
  }]);
  const once = projectFromObservations(doc);
  const twice = projectFromObservations(once);
  assertEquals(twice, once);
});
