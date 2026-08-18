/**
 * Timing spans synthesized from observations: a join, a leave, a
 * flight, an open, a close — and a re-run that must not rewrite
 * what it already wrote.
 */

import { assertEquals } from "@std/assert";
import { attachedEndpoint } from "../../../schema/session-end.ts";
import type { TimelineDocument } from "../../timeline.ts";
import { projectFromObservations } from "../project-from-observations.ts";
import { emptyDoc, withEvents } from "./harness.ts";

Deno.test("migrate: doc without entities is untouched", () => {
  const doc: TimelineDocument = { ...emptyDoc(), entities: undefined };
  assertEquals(projectFromObservations(doc), doc);
});

Deno.test("migrate: peer with no events → both implicit", () => {
  const doc: TimelineDocument = {
    ...emptyDoc(),
    entities: {
      peers: {
        alice: { profile: "pancake" },
      },
    },
  };
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.peers?.alice?.timing, {
    start: { value: 0, explicit: false },
    duration: { value: 0, explicit: false },
    derived: true,
  });
});

Deno.test("migrate: peer with joined event → explicit start", () => {
  const doc: TimelineDocument = withEvents({
    ...emptyDoc(),
    entities: {
      peers: { alice: { profile: "pancake" } },
    },
  }, [
    {
      id: "e1",
      kind: "peer-joined",
      t: 5,
      peerId: "alice",
      profile: "pancake",
    },
  ]);
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.peers?.alice?.timing, {
    start: { value: 5, explicit: true },
    duration: { value: 0, explicit: false },
    derived: true,
  });
});

Deno.test("migrate: peer with joined + left → explicit start, explicit duration", () => {
  const doc: TimelineDocument = withEvents({
    ...emptyDoc(),
    entities: { peers: { alice: { profile: "pancake" } } },
  }, [
    {
      id: "e1",
      kind: "peer-joined",
      t: 5,
      peerId: "alice",
      profile: "pancake",
    },
    { id: "e2", kind: "peer-left", t: 30, peerId: "alice" },
  ]);
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.peers?.alice?.timing, {
    start: { value: 5, explicit: true },
    duration: { value: 25, explicit: true },
    derived: true,
  });
});

Deno.test("migrate: message without flightMs → default 500ms duration", () => {
  const doc: TimelineDocument = {
    ...emptyDoc(),
    entities: {
      messages: {
        m1: { sessionId: "s1", from: "alice", to: "bob" },
      },
    },
  };
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.messages?.m1?.timing, {
    start: { value: 0, explicit: false },
    duration: { value: 500, explicit: true },
    derived: true,
  });
});

Deno.test("project: message-sent observation arrivalT-t → duration", () => {
  const doc: TimelineDocument = withEvents({
    ...emptyDoc(),
    entities: {
      messages: {
        m1: { sessionId: "s1", from: "alice", to: "bob" },
      },
    },
  }, [{
    id: "e1",
    kind: "message-sent",
    t: 10,
    messageId: "m1",
    sessionId: "s1",
    from: "alice",
    to: "bob",
    arrivalT: 210,
  }]);
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.messages?.m1?.timing, {
    start: { value: 10, explicit: true },
    duration: { value: 200, explicit: true },
    derived: true,
  });
});

Deno.test("migrate: message with sent event → explicit start", () => {
  const doc: TimelineDocument = withEvents({
    ...emptyDoc(),
    entities: {
      messages: { m1: { sessionId: "s1", from: "alice", to: "bob" } },
    },
  }, [{
    id: "e1",
    kind: "message-sent",
    t: 10,
    messageId: "m1",
    sessionId: "s1",
    from: "alice",
    to: "bob",
    arrivalT: 11,
  }]);
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.messages?.m1?.timing, {
    start: { value: 10, explicit: true },
    // arrivalT − t = 1 ms flight; observation supersedes the default.
    duration: { value: 1, explicit: true },
    derived: true,
  });
});

Deno.test("migrate: session with open + close → explicit start + duration", () => {
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
      kind: "session-opened",
      t: 2,
      sessionId: "s1",
      a: attachedEndpoint("alice"),
      b: attachedEndpoint("bob"),
      codec: "capnp",
      captpVersion: "v1_0",
    },
    { id: "e2", kind: "session-closed", t: 20, sessionId: "s1" },
  ]);
  const out = projectFromObservations(doc);
  assertEquals(out.entities?.sessions?.s1?.timing, {
    start: { value: 2, explicit: true },
    duration: { value: 18, explicit: true },
    derived: true,
  });
});

Deno.test("migrate: existing timing is preserved (idempotent)", () => {
  const doc: TimelineDocument = {
    ...emptyDoc(),
    entities: {
      peers: {
        alice: {
          profile: "pancake",
          timing: {
            start: { value: 99, explicit: true },
            duration: { value: 11, explicit: true },
          },
        },
      },
    },
  };
  const out = projectFromObservations(doc);
  // identity-equal reference because nothing was touched
  assertEquals(out, doc);
});

Deno.test("migrate: re-running over a migrated doc is a no-op", () => {
  const doc: TimelineDocument = {
    ...emptyDoc(),
    entities: { peers: { alice: { profile: "pancake" } } },
  };
  const once = projectFromObservations(doc);
  const twice = projectFromObservations(once);
  assertEquals(twice, once);
});
