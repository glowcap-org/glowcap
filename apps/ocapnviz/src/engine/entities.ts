/**
 * `doc.entities` mutation helpers — define / patch / remove the
 * per-category identity entries, plus the eternal-start injector
 * that adds entities-only (no creation-event) peers and sessions
 * to the ECS world.
 *
 * Pure-ish: each function mutates the passed-in doc (and `world`
 * for the eternal injector) in place; no engine internals, no
 * subscription side effects. Engine methods that previously held
 * these as private fields are now one-line delegates.
 */

import type { MessageDefinition, PeerDefinition, SessionDefinition, TimelineDocument } from "./timeline.ts";
import type { CaptpVersion, Codec, PeerProfile, SessionState, Transport } from "../schema/topology.ts";

/** Write peer identity to `doc.entities.peers[peerId]`. Called when
 * a peer is created or its identity is edited, so the entities-map
 * stays in sync with event payloads. */
export function definePeer(
  doc: TimelineDocument,
  peerId: string,
  def: PeerDefinition,
): void {
  const next: NonNullable<TimelineDocument["entities"]> = {
    ...(doc.entities ?? {}),
  };
  next.peers = { ...(next.peers ?? {}), [peerId]: { ...def } };
  doc.entities = next;
}

/** Patch a subset of a peer's `entities.peers[peerId]` entry. No-op
 * when the peer isn't defined. Empty string for `designator`
 * drops the field (matches the event-payload mutation semantic);
 * `label` stores whatever the patch says, including "". */
export function patchPeerDefinition(
  doc: TimelineDocument,
  peerId: string,
  patch: {
    label?: string;
    profile?: PeerProfile;
    designator?: string;
    position?: { x: number; y: number };
  },
): void {
  const prev = doc.entities?.peers?.[peerId];
  if (!prev) return;
  const next: PeerDefinition = { ...prev };
  if (patch.label !== undefined) next.label = patch.label;
  if (patch.profile !== undefined) next.profile = patch.profile;
  if (patch.designator !== undefined) {
    if (patch.designator === "") delete next.designator;
    else next.designator = patch.designator;
  }
  if (patch.position !== undefined) next.position = patch.position;
  doc.entities = {
    ...doc.entities,
    peers: { ...doc.entities!.peers, [peerId]: next },
  };
}

/** Write session identity to `doc.entities.sessions[id]`. */
export function defineSession(
  doc: TimelineDocument,
  sessionId: string,
  def: SessionDefinition,
): void {
  const next: NonNullable<TimelineDocument["entities"]> = {
    ...(doc.entities ?? {}),
  };
  next.sessions = { ...(next.sessions ?? {}), [sessionId]: { ...def } };
  doc.entities = next;
}

/** Patch a subset of a session's `entities.sessions[id]` entry. */
export function patchSessionDefinition(
  doc: TimelineDocument,
  sessionId: string,
  patch: {
    codec?: Codec;
    captpVersion?: CaptpVersion;
    initialState?: SessionState;
    /** The netlayer the session runs over; `null` stops stating one,
     *  the same reading a peer's emptied designator takes above. A
     *  session whose transport nothing states is an ordinary state of
     *  the document, so the field goes away rather than taking a
     *  stand-in value. */
    transport?: Transport | null;
  },
): void {
  const prev = doc.entities?.sessions?.[sessionId];
  if (!prev) return;
  const { transport, ...rest } = patch;
  const next: SessionDefinition = { ...prev, ...rest };
  if (transport === null || transport === "") delete next.transport;
  else if (transport !== undefined) next.transport = transport;
  doc.entities = {
    ...doc.entities,
    sessions: { ...doc.entities!.sessions, [sessionId]: next },
  };
}

/** Write message identity to `doc.entities.messages[id]`. */
export function defineMessage(
  doc: TimelineDocument,
  messageId: string,
  def: MessageDefinition,
): void {
  const next: NonNullable<TimelineDocument["entities"]> = {
    ...(doc.entities ?? {}),
  };
  next.messages = { ...(next.messages ?? {}), [messageId]: { ...def } };
  doc.entities = next;
}

/** Patch a subset of a message's `entities.messages[id]` entry. */
export function patchMessageDefinition(
  doc: TimelineDocument,
  messageId: string,
  patch: {
    label?: string;
    sessionId?: string;
    from?: string;
    to?: string;
  },
): void {
  const prev = doc.entities?.messages?.[messageId];
  if (!prev) return;
  const next: MessageDefinition = { ...prev };
  if (patch.label !== undefined) {
    if (patch.label === "") delete next.label;
    else next.label = patch.label;
  }
  if (patch.sessionId !== undefined) next.sessionId = patch.sessionId;
  if (patch.from !== undefined) next.from = patch.from;
  if (patch.to !== undefined) next.to = patch.to;
  doc.entities = {
    ...doc.entities,
    messages: { ...doc.entities!.messages, [messageId]: next },
  };
}

// `applyEternalEntities` is retired. The reconciler-based world
// materialization (engine/systems/world-materializer.ts) walks all
// entities at each seek and adds the ones whose effective range
// contains t — the "eternal-start" case (entity defined but never
// 'born' via an event) is handled uniformly with every other span.
