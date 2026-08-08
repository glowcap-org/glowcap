/**
 * Branded id types for the cascade subsystem.
 *
 * `PeerId` / `SessionId` / `MessageId` are nominally distinct from each
 * other and from plain `string`, so that the type checker can prevent
 * (a) passing a session id where a peer id is required, and (b) using
 * a raw `string` as an id without an explicit acknowledgement at the
 * brand boundary. Branded values are structurally still strings, so
 * they pass freely into APIs that take `string` (DOM keys, JSON
 * serializers, etc.) — the asymmetry is intentional.
 *
 * Cast helpers (`asPeerId`, `asSessionId`, `asMessageId`) are the
 * authoritative boundary. Use them at the points where an id enters
 * the system from outside the type discipline: zod-parsed wire data,
 * test fixtures, DOM input, id-minting code, and back-channel APIs
 * (`globalThis.__ocv.*`). Inside the engine, ids should already be
 * branded and flow through without further casts.
 *
 * See `docs/schema-driven-transactions.md` for the broader design.
 */

declare const PeerIdBrand: unique symbol;
declare const SessionIdBrand: unique symbol;
declare const MessageIdBrand: unique symbol;

export type PeerId = string & { readonly [PeerIdBrand]: void };
export type SessionId = string & { readonly [SessionIdBrand]: void };
export type MessageId = string & { readonly [MessageIdBrand]: void };

/** Cast a raw string to a `PeerId`. Use only at the brand boundary. */
export function asPeerId(s: string): PeerId {
  return s as PeerId;
}

/** Cast a raw string to a `SessionId`. Use only at the brand boundary. */
export function asSessionId(s: string): SessionId {
  return s as SessionId;
}

/** Cast a raw string to a `MessageId`. Use only at the brand boundary. */
export function asMessageId(s: string): MessageId {
  return s as MessageId;
}

/** The three entity kinds the cascade subsystem operates over. */
export type EntityKind = "peer" | "session" | "message";

/** Branded id for an entity of the given kind. */
export type EntityId<K extends EntityKind> = K extends "peer" ? PeerId
  : K extends "session" ? SessionId
  : K extends "message" ? MessageId
  : never;

/** Brand-aware cast keyed by entity kind. Convenient for generic code
 * that produces ids of a kind known only at runtime. */
export function asEntityId<K extends EntityKind>(
  _kind: K,
  s: string,
): EntityId<K> {
  return s as EntityId<K>;
}
