import { assertEquals } from "@std/assert";
import { TimelineEvent } from "../timeline.ts";
import { ENTITY_EDGES, EVENT_EDGES } from "./edges.ts";

Deno.test("EVENT_EDGES covers every TimelineEvent kind", () => {
  // The mapped type forces this at compile time; this test makes the
  // contract visible to anyone reading test output, and catches a
  // regression where someone introduces a `Partial` cast that
  // silences the compile error.
  const declared = new Set(Object.keys(EVENT_EDGES));
  const variants = TimelineEvent.options.map((o) => o.shape.kind.value);
  for (const v of variants) {
    if (!declared.has(v)) {
      throw new Error(`EVENT_EDGES missing kind "${v}"`);
    }
  }
  assertEquals(declared.size, variants.length);
});

Deno.test("EVENT_EDGES.session-opened references both peer endpoints", () => {
  const edges = EVENT_EDGES["session-opened"];
  const fields = edges.map((e) => `${e.field}:${e.target}`).sort();
  assertEquals(fields, ["a:peer", "b:peer", "sessionId:session"]);
});

Deno.test("EVENT_EDGES.message-sent references session + both endpoints", () => {
  const edges = EVENT_EDGES["message-sent"];
  const fields = edges.map((e) => `${e.field}:${e.target}`).sort();
  assertEquals(
    fields,
    ["from:peer", "messageId:message", "sessionId:session", "to:peer"],
  );
});

Deno.test("ENTITY_EDGES: peer has no outgoing refs", () => {
  assertEquals(ENTITY_EDGES.peer.length, 0);
});

Deno.test("ENTITY_EDGES.session points at its two peer endpoints", () => {
  const fields = ENTITY_EDGES.session.map((e) => `${e.field}:${e.target}`)
    .sort();
  assertEquals(fields, ["a:peer", "b:peer"]);
});

Deno.test("ENTITY_EDGES.message points at its session and both endpoints", () => {
  const fields = ENTITY_EDGES.message.map((e) => `${e.field}:${e.target}`)
    .sort();
  assertEquals(fields, ["from:peer", "sessionId:session", "to:peer"]);
});
