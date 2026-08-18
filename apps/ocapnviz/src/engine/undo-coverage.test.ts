/**
 * Every authoring action is one undo step.
 *
 * An author changing the composition — a label, an id, an end's claim,
 * a moment in a trajectory, a pin, a row's order — must be able to take
 * it back. Nothing here is about how the composition is VIEWED (zoom,
 * pan, the playhead, which panes are open); those are not edits and
 * carry no history.
 *
 * The table below holds one case per `BuilderIntent` kind, and it is
 * typed `Record<BuilderIntent["kind"], Case>`, so a new intent that
 * arrives without a case fails to compile. That is the point of the
 * file: the coverage claim is held by the type checker rather than by
 * whoever remembers to add a test.
 *
 * Each case asserts the whole round trip against the WHOLE document,
 * not against `DocSnapshot`. A mutation that lands in a doc field the
 * snapshot does not carry would round-trip perfectly against the
 * snapshot and still be lost on undo; comparing documents is what
 * catches that.
 */

import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "./timeline.ts";
import { Engine } from "./engine.ts";
import type { BuilderIntent } from "./intents.ts";
import { attachedEndpoint } from "../schema/session-end.ts";

function engineTest(name: string, fn: () => void): void {
  Deno.test({ name, sanitizeOps: false, sanitizeResources: false, fn });
}

/** Peers `a`/`b` carry a session with a state change on it; `s2` has one
 *  end nothing has attributed, so the endpoint intents have something to
 *  edit. `m1` gives the message intents a subject. */
const source = {
  id: "undo-coverage",
  duration: 10000,
  events: [
    { id: "e1", t: 0, kind: "peer-joined", peerId: "a", profile: "pancake" },
    { id: "e2", t: 0, kind: "peer-joined", peerId: "b", profile: "goblins" },
    { id: "e3", t: 0, kind: "peer-joined", peerId: "c", profile: "pancake" },
    {
      id: "e4",
      t: 0,
      kind: "session-opened",
      sessionId: "s1",
      a: { peer: "a" },
      b: { peer: "b" },
      codec: "syrup",
      captpVersion: "v1_0",
      initialState: "open",
    },
    {
      id: "e8",
      t: 0,
      kind: "session-opened",
      sessionId: "s2",
      a: { peer: "c" },
      b: { designator: "127.0.0.1:9000" },
      codec: "syrup",
      captpVersion: "v1_0",
      initialState: "open",
    },
    {
      id: "e5",
      t: 1000,
      kind: "message-sent",
      messageId: "m1",
      sessionId: "s1",
      from: "a",
      to: "b",
      arrivalT: 1500,
    },
    { id: "e6", t: 1500, kind: "message-delivered", messageId: "m1" },
    {
      id: "e7",
      t: 2000,
      kind: "session-state-changed",
      sessionId: "s1",
      state: "draining",
    },
  ],
};

function freshEngine(): Engine {
  return new Engine(TimelineDocument.parse(structuredClone(source)));
}

/** The whole document as comparable text. Deliberately not
 *  `takeSnapshot` — see this file's header. */
function docText(e: Engine): string {
  return JSON.stringify(e.doc);
}

type Case = {
  /** Built against a live engine so a case can read minted ids. */
  intent: (e: Engine) => BuilderIntent;
  /** Run before the intent when the case needs a playhead or a prior
   *  edit to have something to act on. */
  setUp?: (e: Engine) => void;
};

const CASES: Record<BuilderIntent["kind"], Case> = {
  "add-peer": {
    intent: () => ({
      kind: "add-peer",
      profile: "pancake",
      position: { x: 10, y: 20 },
    }),
  },
  "reposition-peer": {
    intent: () => ({
      kind: "reposition-peer",
      peerId: "a",
      position: { x: 111, y: 222 },
    }),
  },
  "clear-peer-position": {
    setUp: (e) =>
      void e.dispatch({
        kind: "reposition-peer",
        peerId: "a",
        position: { x: 111, y: 222 },
      }),
    intent: () => ({ kind: "clear-peer-position", peerId: "a" }),
  },
  "reposition-endpoint": {
    intent: () => ({
      kind: "reposition-endpoint",
      endpointId: "s2::b",
      position: { x: 33, y: 44 },
    }),
  },
  "clear-endpoint-position": {
    setUp: (e) =>
      void e.dispatch({
        kind: "reposition-endpoint",
        endpointId: "s2::b",
        position: { x: 33, y: 44 },
      }),
    intent: () => ({ kind: "clear-endpoint-position", endpointId: "s2::b" }),
  },
  "update-peer": {
    intent: () => ({
      kind: "update-peer",
      peerId: "a",
      patch: { label: "Alice renamed", designator: "did:example:alice" },
    }),
  },
  "open-session": {
    intent: () => ({
      kind: "open-session",
      a: attachedEndpoint("a"),
      b: attachedEndpoint("c"),
      codec: "syrup",
      captpVersion: "v1_0",
    }),
  },
  "send-message": {
    setUp: (e) => e.seekTo(500),
    intent: () => ({
      kind: "send-message",
      sessionId: "s1",
      from: "a",
      to: "b",
      label: "op:deliver",
    }),
  },
  "delete-peer": { intent: () => ({ kind: "delete-peer", peerId: "c" }) },
  "delete-session": {
    intent: () => ({ kind: "delete-session", sessionId: "s2" }),
  },
  "delete-message": {
    intent: () => ({ kind: "delete-message", messageId: "m1" }),
  },
  "update-session": {
    intent: () => ({
      kind: "update-session",
      sessionId: "s1",
      patch: { codec: "capnp", transport: "iroh" },
    }),
  },
  "update-message": {
    intent: () => ({
      kind: "update-message",
      messageId: "m1",
      patch: { label: "op:abort" },
    }),
  },
  "move-entity-span": {
    intent: () => ({
      kind: "move-entity-span",
      move: { kind: "translate", ref: { kind: "peer", id: "a" }, newT: 300 },
    }),
  },
  "move-event": {
    intent: () => ({
      kind: "move-event",
      move: { kind: "translate", eventId: "e7", newT: 2500 },
    }),
  },
  "set-peer-end": {
    intent: () => ({ kind: "set-peer-end", peerId: "a", t: 4000 }),
  },
  "set-peer-duration": {
    intent: () => ({ kind: "set-peer-duration", peerId: "a", duration: 3000 }),
  },
  "clear-peer-end": {
    setUp: (e) => void e.dispatch({ kind: "set-peer-end", peerId: "a", t: 4000 }),
    intent: () => ({ kind: "clear-peer-end", peerId: "a" }),
  },
  "set-peer-start": {
    intent: () => ({ kind: "set-peer-start", peerId: "a", t: 250 }),
  },
  "clear-peer-start": {
    intent: () => ({ kind: "clear-peer-start", peerId: "a" }),
  },
  "set-session-end": {
    intent: () => ({ kind: "set-session-end", sessionId: "s1", t: 6000 }),
  },
  "set-session-duration": {
    intent: () => ({
      kind: "set-session-duration",
      sessionId: "s1",
      duration: 5000,
    }),
  },
  "clear-session-end": {
    setUp: (e) => void e.dispatch({ kind: "set-session-end", sessionId: "s1", t: 6000 }),
    intent: () => ({ kind: "clear-session-end", sessionId: "s1" }),
  },
  "set-session-start": {
    intent: () => ({ kind: "set-session-start", sessionId: "s1", t: 400 }),
  },
  "clear-session-start": {
    setUp: (e) => void e.dispatch({ kind: "set-session-start", sessionId: "s1", t: 400 }),
    intent: () => ({ kind: "clear-session-start", sessionId: "s1" }),
  },
  "set-session-keyframe": {
    intent: () => ({
      kind: "set-session-keyframe",
      sessionId: "s1",
      property: "state",
      t: 3000,
      value: "closed",
    }),
  },
  "remove-session-keyframe": {
    intent: () => ({
      kind: "remove-session-keyframe",
      sessionId: "s1",
      property: "state",
      t: 2000,
    }),
  },
  "set-session-initial-state": {
    intent: () => ({
      kind: "set-session-initial-state",
      sessionId: "s1",
      state: "negotiating",
    }),
  },
  "update-session-endpoint": {
    intent: () => ({
      kind: "update-session-endpoint",
      sessionId: "s2",
      side: "b",
      patch: { designator: "10.0.0.1:7000" },
    }),
  },
  "set-peer-update": {
    intent: () => ({
      kind: "set-peer-update",
      peerId: "a",
      t: 3000,
      property: "label",
      value: "later name",
    }),
  },
  "remove-peer-update": {
    setUp: (e) =>
      void e.dispatch({
        kind: "set-peer-update",
        peerId: "a",
        t: 3000,
        property: "label",
        value: "later name",
      }),
    intent: () => ({
      kind: "remove-peer-update",
      peerId: "a",
      t: 3000,
      property: "label",
    }),
  },
  "set-message-start": {
    intent: () => ({ kind: "set-message-start", messageId: "m1", t: 1200 }),
  },
  "clear-message-start": {
    intent: () => ({ kind: "clear-message-start", messageId: "m1" }),
  },
  "set-message-end": {
    intent: () => ({ kind: "set-message-end", messageId: "m1", t: 1800 }),
  },
  "set-message-duration": {
    intent: () => ({
      kind: "set-message-duration",
      messageId: "m1",
      duration: 700,
    }),
  },
  "reorder-row": {
    intent: () => ({
      kind: "reorder-row",
      category: "peers",
      order: ["b", "a", "c"],
    }),
  },
  "set-row-vis-mode": {
    intent: () => ({
      kind: "set-row-vis-mode",
      category: "peers",
      id: "a",
      mode: "both",
    }),
  },
  "set-category-vis-mode": {
    intent: () => ({
      kind: "set-category-vis-mode",
      category: "peers",
      mode: "label",
    }),
  },
  "set-all-vis-mode": {
    intent: () => ({ kind: "set-all-vis-mode", mode: "body" }),
  },
  "rename-peer": {
    intent: () => ({ kind: "rename-peer", oldId: "a", newId: "alice" }),
  },
  "rename-session": {
    intent: () => ({ kind: "rename-session", oldId: "s1", newId: "sess-one" }),
  },
  "rename-message": {
    intent: () => ({ kind: "rename-message", oldId: "m1", newId: "msg-one" }),
  },
};

for (const [kind, spec] of Object.entries(CASES)) {
  engineTest(`undo round-trips "${kind}"`, () => {
    const e = freshEngine();
    spec.setUp?.(e);
    // The set-up's own history is not what this case is measuring.
    const before = docText(e);
    const undoDepthBefore = e.canUndo;

    e.dispatch(spec.intent(e));

    const after = docText(e);
    assert(
      after !== before,
      `"${kind}" changed nothing, so this case proves nothing about undo`,
    );
    assert(e.canUndo, `"${kind}" mutated the document without recording undo`);
    assert(
      e.nextUndoLabel !== undefined && e.nextUndoLabel.length > 0,
      `"${kind}" recorded undo with no label to show the user`,
    );

    e.undo();
    assertEquals(docText(e), before, `undo did not restore "${kind}"`);

    e.redo();
    assertEquals(docText(e), after, `redo did not re-apply "${kind}"`);

    // And back out again, so the case leaves no doubt that the entry
    // it pushed is the only one it pushed.
    e.undo();
    assertEquals(docText(e), before, `second undo did not restore "${kind}"`);
    assertEquals(
      e.canUndo,
      undoDepthBefore,
      `"${kind}" pushed more than one history entry`,
    );
  });
}
