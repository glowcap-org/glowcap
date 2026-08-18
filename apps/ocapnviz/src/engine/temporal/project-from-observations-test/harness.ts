/**
 * Fixtures for projecting a document from its observation stream:
 * an empty doc, and a recording source wrapping a list of events.
 */

import type { TimelineDocument, TimelineEvent } from "../../timeline.ts";

export const emptyDoc = (): TimelineDocument => ({
  id: "test",
  duration: 100,
  rowOrder: {},
  rowHidden: {},
  rowLabelHidden: {},
  rowBodyHidden: {},
  entities: {},
});

/** Synthesize a recording source on `doc` carrying `events`.
 *  Observation streams live under `recording.sources` post-parse;
 *  these tests construct docs by hand so they wrap events here. */
export function withEvents(
  doc: TimelineDocument,
  events: TimelineEvent[],
): TimelineDocument {
  return {
    ...doc,
    recording: {
      sources: [{
        id: "fixture",
        meta: { kind: "fixture" },
        observations: events,
      }],
    },
  };
}

/** A doc holding one peer that joined at t=5 under its locator. */
export function joinedPeerDoc(): TimelineDocument {
  return withEvents({ ...emptyDoc(), entities: {} }, [
    {
      id: "e1",
      kind: "peer-joined",
      t: 5,
      peerId: "127.0.0.1:0",
      profile: "pancake",
      label: "127.0.0.1:0",
    },
  ]);
}
