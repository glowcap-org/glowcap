import { type With, World } from "miniplex";
import type { CaptpVersion, Codec, PeerProfile, SessionState } from "../schema/topology.ts";
import type { SessionSide } from "../schema/session-end.ts";

/**
 * ECS world. The world *is* the graph — no parallel data structure.
 * Systems read and mutate it through queries; the renderer projects
 * it to sprites. Components are small and composable so new concerns
 * (selection, highlighting) drop in as new keys.
 */

export type Vec2 = { x: number; y: number };

/** Components an entity may carry. Queries narrow by presence. */
export type Components = {
  /** Peer entity. Mutually exclusive with `session`. */
  peer?: {
    id: string;
    label: string;
    profile: PeerProfile;
    /** The durable name this peer answers to on the wire, as against
     *  the name it is shown by. It is what a session end's claim can
     *  match, so a claim naming a peer with none can never find it. */
    designator?: string;
  };

  /** One end of a session that nothing has attributed to a peer.
   *
   *  It is drawn, and so it is an entity: the force layout needs a position
   *  at both ends of every edge, and a reader needs something to select in
   *  order to ask what this end claims. It is deliberately NOT a `peer`
   *  component — a claim nothing proved is not a peer, and anything that
   *  walks peers must not pick it up. It lives and dies with its session. */
  endpoint?: {
    id: string;
    sessionId: string;
    side: SessionSide;
    /** What this end claims to be. Nothing backed the claim, or the end
     *  would be attached and this entity would not exist. */
    designator?: string;
  };

  /** Session edge. Mutually exclusive with `peer`. */
  session?: {
    id: string;
    codec: Codec;
    captpVersion: CaptpVersion;
    state: SessionState;
  };

  /** Session endpoints by peer id. */
  endpoints?: { a: string; b: string };

  /** Transient message-in-flight. */
  messageInFlight?: {
    id: string;
    sessionId: string;
    from: string;
    to: string;
    sentT: number;
    arrivalT: number;
    label?: string;
  };

  /**
   * Rendered position, written each tick by KeyframeLayoutSystem
   * (peers) or MessageFlightSystem (in-flight messages). Pure
   * function of `t` and the world; no integration history.
   */
  position?: Vec2;
};

export type GameWorld = World<Components>;

export function createWorld(): GameWorld {
  return new World<Components>();
}

/** Entity shapes the renderer consumes — the same `With<>` shapes
 * the queries below yield. Exported from this layer (not redeclared
 * in the renderer) so any caller that iterates an engine query
 * gets the canonical element type. */
export type PeerEntity = With<Components, "peer" | "position">;
export type EndpointEntity = With<Components, "endpoint" | "position">;
export type SessionEntity = With<Components, "session" | "endpoints">;
export type MessageEntity = With<Components, "messageInFlight" | "position">;

/** Centralized queries shared by systems and the renderer. */
export function queries(world: GameWorld) {
  return {
    peers: world.with("peer", "position"),
    endpoints: world.with("endpoint", "position"),
    sessions: world.with("session", "endpoints"),
    messagesInFlight: world.with("messageInFlight", "position"),
  };
}
export type Queries = ReturnType<typeof queries>;

/** Find a peer by id. Linear scan; fine at our scale (tens of peers). */
export function findPeer(world: GameWorld, id: string) {
  for (const e of world.with("peer")) {
    if (e.peer.id === id) return e;
  }
  return undefined;
}

/** The loose-end entity with this id, if it is drawn. */
export function findEndpoint(world: GameWorld, id: string) {
  for (const e of world.with("endpoint")) {
    if (e.endpoint.id === id) return e;
  }
  return undefined;
}

/** The entity a session's end sits at, whichever kind it is.
 *
 * A line has to reach something at both ends, and one of them may be a claim
 * nobody has attributed rather than a peer. Geometry and hit-testing ask this
 * rather than `findPeer`, so a loose end is a place on the stage instead of a
 * missing lookup that silently drops the whole edge. */
export function findNode(world: GameWorld, id: string) {
  const peer = findPeer(world, id);
  if (peer !== undefined) return peer;
  return findEndpoint(world, id);
}

export function findSession(world: GameWorld, id: string) {
  for (const e of world.with("session", "endpoints")) {
    if (e.session.id === id) return e;
  }
  return undefined;
}
