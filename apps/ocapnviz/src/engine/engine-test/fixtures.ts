import { TimelineDocument } from "../timeline.ts";

/** Two peers, one session, one message — the ordinary playback document. */
export const doc = TimelineDocument.parse({
  id: "test",
  duration: 5000,
  events: [
    { id: "e1", t: 0, kind: "peer-joined", peerId: "a", profile: "pancake" },
    { id: "e2", t: 0, kind: "peer-joined", peerId: "b", profile: "goblins" },
    {
      id: "e3",
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
      id: "e4",
      t: 1000,
      kind: "message-sent",
      messageId: "m1",
      sessionId: "s1",
      from: "a",
      to: "b",
      arrivalT: 1500,
    },
    {
      id: "e5",
      t: 1500,
      kind: "message-delivered",
      messageId: "m1",
    },
    {
      id: "e6",
      t: 2000,
      kind: "session-state-changed",
      sessionId: "s1",
      state: "draining",
    },
  ],
});

/**
 * Empty authored-mode doc — a builder starting point with no
 * force layout in play. Tests below build up state from here so
 * the "before" state of each undo round-trip is explicit and easy
 * to verify.
 */
export const emptyAuthoredDoc = () =>
  TimelineDocument.parse({
    id: "builder-test",
    duration: 60_000,
    layoutMode: "authored",
    events: [],
  });
