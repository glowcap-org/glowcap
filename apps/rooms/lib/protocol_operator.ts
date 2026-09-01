// The administration half of the wire contract in `protocol.ts`: what the
// operator listeners publication answers, and the Rooms operator's stewardship
// and inventory verbs. Split beside the core contract the way
// `protocol_handover.ts` is, because its speakers are their own tree: the
// operator behaviors on the server, the operator clients, and the ops panes.
// The room manager answers several of the same verb strings on its own object,
// so it imports them from here rather than spelling them again.

/** What the operator listeners object answers, when the process is started with
 * `--admin-listeners`.
 *
 * Like inspect, it is not a directory method: it is a second Host publication
 * under an unguessable swiss, and holding that swiss is the whole of the
 * authority to administer this server's listeners. `list` (the same verb name
 * the directory uses, on a different object) answers the live listeners as
 * `[id, transport, locator, serving]` rows, where `serving` marks the listener
 * whose locator this server announced — the one the web relay dials. `up(
 * transport, port?)` brings a listener up on `tcp`, `iroh`, or `onion` and
 * answers its row; only a `tcp` listener takes a port, and the native runtime
 * holds one live listener per transport at a time. `down(id)` stops that
 * listener admitting connections; sessions it already accepted stay live. An
 * `up` for a transport this process cannot realize, a second `up` on a
 * transport already up, and a `down` on the serving listener all refuse with
 * the typed codes in `errors.ts`. */

export const UP = "up";
export const DOWN = "down";

/** The Rooms operator's stewardship verbs. `giveSteward(name)` returns the
 * current durable authority for one server-owned room, minting it when none
 * has been issued. `revokeSteward(name)` rotates that authority: copied links
 * and already-live references from the old generation both stop governing. */
export const GIVE_STEWARD = "giveSteward";
export const GIVE_MANAGER = "giveManager";
export const REVOKE_STEWARD = "revokeSteward";
/** Rooms-operator inventory and mutations. Targets are server-issued
 * session ids or durable room names, never diagnostic display strings. */
export const OPERATOR_SNAPSHOT = "operatorSnapshot";
export const OPERATOR_RETIRE_MATCHING = "operatorRetireMatching";
export const OPERATOR_WATCH = "watch";
export const OPERATOR_UNWATCH = "unwatch";
export const OPERATOR_CHANGED = "changed";
export const REVOKE_ROOM_LINK = "revokeRoomLink";
/** Release a managed public room's registered name and retire its entry,
 * moderator, and manager authority together. Current memberships remain until
 * they leave; the name is available again once the live room empties. */
export const UNREGISTER_ROOM = "unregisterRoom";
/** Change one managed room's discovery and admission policy without rotating
 * its room, moderator, or manager authority. */
export const SET_ROOM_POLICY = "setRoomPolicy";
/** Retire the exact current room-link or moderator generation identified by
 * its opaque publication token. Unlike a room name, this remains unambiguous
 * for private rooms and cannot let a delayed action revoke a replacement. */
export const REVOKE_ROOM_AUTHORITY = "revokeRoomAuthority";
export const REVOKE_NICK = "revokeNick";
export const DISCONNECT_SESSION = "disconnectSession";
export const REMOVE_OPERATOR_ROOM = "removeOperatorRoom";
export const RELEASE_OPERATOR_REFERENCE = "releaseOperatorReference";
export const CLEAR_OPERATOR_TROUBLE = "clearOperatorTrouble";
export const RESET_OPERATOR_SCOPE = "resetOperatorScope";
