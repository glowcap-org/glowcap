// The two-ends-of-a-wire picture a live feed draws, and the room of
// reports that produce it. Tests that ask "did these two runs leave
// the same stage?" read `pictureOf`; tests that need a named pair of
// producers reporting one session use `opened` and `wireName`.

import { assert } from "@std/assert";
import { makeBaseEventConverter } from "../feed.ts";
import { type BaseTimelineEvent } from "../record.ts";
import type { TimelineEvent } from "../../timeline.ts";
import {
  type BuiltinCaptpVersion,
  CAPTP_VERSION_WIRE,
  PANCAKE_PROFILE,
  type PeerProfile,
} from "../../../schema/topology.ts";
import { endpointNodeId } from "../../../schema/session-end.ts";

/** The wire name both peers of a session derive. Any 64 hex digits will do
 * here; what matters is that both producers report the SAME one. */
export function wireName(seed: string): string {
  return seed.repeat(64).slice(0, 64);
}

/** The stage a run of records leaves behind: who is on it, and which
 * pairs of them a session joins. Two runs that agree here drew the
 * same picture, whatever they said along the way. */
export function pictureOf(events: TimelineEvent[]): {
  peers: string[];
  edges: string[];
} {
  const labels = new Map<string, string>();
  const edges = new Map<string, [string, string]>();
  for (const ev of events) {
    switch (ev.kind) {
      case "peer-joined":
        labels.set(ev.peerId, ev.label ?? ev.peerId);
        break;
      case "peer-updated":
        if (ev.label !== undefined) labels.set(ev.peerId, ev.label);
        break;
      case "peer-left":
      case "peer-unobserved":
        labels.delete(ev.peerId);
        break;
      case "session-opened":
        edges.set(ev.sessionId, [
          endpointNodeId(ev.sessionId, "a", ev.a),
          endpointNodeId(ev.sessionId, "b", ev.b),
        ]);
        break;
      case "session-endpoint-attributed": {
        const edge = edges.get(ev.sessionId);
        if (edge !== undefined) edge[ev.side === "a" ? 0 : 1] = ev.peerId;
        break;
      }
      case "session-closed":
        edges.delete(ev.sessionId);
        break;
    }
  }
  return {
    peers: [...labels.entries()].map(([id, label]) => `${id}=${label}`).sort(),
    edges: [...edges.values()].map((e) => [...e].sort().join("–")).sort(),
  };
}

/** One producer's report of one session, as the endpoint carries it.
 *
 * `session` is the producer's own handle, scoped to it. `sessionId` is the
 * OCapN Session ID both ends of that session derive, which is what lets two
 * producers' reports be recognised as one session. */
export function opened(
  seq: number,
  session: string,
  self: string,
  partner: string,
  sessionId: string,
  verified: boolean,
  /** `captp` is the negotiated CapTP profile, when a test turns on which
   * one it is, named by this viewer's own tag. A producer reports the
   * handshake's syntax, so the tag is put on the wire through
   * `CAPTP_VERSION_WIRE` rather than written out — one table, and no test
   * has to know it. Left off, the session runs the OCapN v1.0 interop
   * floor, which is what a producer reporting nothing means.
   *
   * `profile` is what the producer STATES it runs, and it is left off by
   * default because that is what the wire looks like when a producer says
   * nothing. A test that means "a pancake host is reporting this" says so,
   * the way a pancake binding says so on every record it publishes. */
  opts: { captp?: BuiltinCaptpVersion; profile?: PeerProfile } = {},
): BaseTimelineEvent {
  return {
    v: 1,
    sim_t_ns: seq * 1_000_000,
    kind: "ocapn.session-opened",
    session,
    a: self,
    b: partner,
    provenance: verified ? "authenticated-transport" : "unauthenticated",
    session_id: sessionId,
    codec: "syrup",
    ...(opts.profile !== undefined && { a_profile: opts.profile }),
    ...(opts.captp !== undefined &&
      { captp_version: CAPTP_VERSION_WIRE[opts.captp] }),
  };
}

/** A room with two members and a direct message between them. Every
 * wire is reported by BOTH of its ends, which is what the endpoint
 * forwards and what a snapshot replays; the accepting end cannot name
 * who dialed it, because a browser tab presents no address it can
 * prove.
 *
 * `accepted` is the order the endpoint's seq gives on a reconnect —
 * the end that could not name its partner first. `dialed` is the same
 * six reports with each wire's naming end first, which is the order
 * that needs no learning: everything is known before it is drawn. */
export const ROOM_WIRE_1 = wireName("c");
export const ROOM_WIRE_2 = wireName("d");
export const DM_WIRE = wireName("e");

/** Every producer here is a pancake host and says so on every record, which
 * is what the bindings do and therefore what the endpoint actually carries. */
export const SAYS_PANCAKE = { profile: PANCAKE_PROFILE } as const;

const accepting: BaseTimelineEvent[] = [
  opened(
    0,
    "p0/live-h1-s1",
    "rooms-key",
    "127.0.0.1:0",
    ROOM_WIRE_1,
    false,
    SAYS_PANCAKE,
  ),
  opened(
    2,
    "p0/live-h1-s2",
    "rooms-key",
    "127.0.0.1:0",
    ROOM_WIRE_2,
    false,
    SAYS_PANCAKE,
  ),
  opened(
    4,
    "p2/live-h1-s2",
    "tab2-key",
    "127.0.0.1:0",
    DM_WIRE,
    false,
    SAYS_PANCAKE,
  ),
];
const naming: BaseTimelineEvent[] = [
  opened(
    1,
    "p1/live-h1-s1",
    "tab1-key",
    "rooms-key",
    ROOM_WIRE_1,
    true,
    SAYS_PANCAKE,
  ),
  opened(
    3,
    "p2/live-h1-s1",
    "tab2-key",
    "rooms-key",
    ROOM_WIRE_2,
    true,
    SAYS_PANCAKE,
  ),
  opened(
    5,
    "p1/live-h1-s2",
    "tab1-key",
    "tab2-key",
    DM_WIRE,
    true,
    SAYS_PANCAKE,
  ),
];

function stampedNs(ev: BaseTimelineEvent): number {
  assert(typeof ev.sim_t_ns === "number", "fixture timestamp must be numeric");
  return ev.sim_t_ns;
}

/** Interleaved as the endpoint stamped them: accepting end, then the
 * end that can name it. */
export const AS_STAMPED: BaseTimelineEvent[] = [...accepting, ...naming]
  .sort((x, y) => stampedNs(x) - stampedNs(y));

/** The same reports with each wire's naming end first — the order in
 * which nothing has to be learned. */
export const NAMING_FIRST: BaseTimelineEvent[] = [...naming, ...accepting];

export function runThrough(records: BaseTimelineEvent[]): TimelineEvent[] {
  const convert = makeBaseEventConverter();
  const out: TimelineEvent[] = [];
  for (const ev of records) out.push(...convert(ev));
  return out;
}

/** What each peer was drawn as, by stage id. */
export function joinedProfiles(evs: readonly TimelineEvent[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const ev of evs) {
    if (ev.kind === "peer-joined") out[ev.peerId] = ev.profile;
  }
  return out;
}
