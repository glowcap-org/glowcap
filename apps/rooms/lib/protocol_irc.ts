// The bridge half of the wire contract in `protocol.ts`: the facts a bridged
// room states about the bridge behind it, and the seat lifecycle those facts
// ride on. It sits beside the core contract as `protocol_handover.ts` does,
// because its speakers have their own tree: the bridge client and the surfaces
// that draw a seat. The operator gateway speaks the generic bridge verbs in
// `bridge/gateway.ts`, so its verbs are not named here.

/** What a bridged room says about the bridge behind it, on the same tail its
 * other standing facts ride: the prefix its foreign members' names carry, and
 * the badge and sentence for one of them.
 *
 * Said once per room and not once per member, because it is true of the bridge
 * and of nobody in particular: every foreign member of one bridge is foreign
 * in the same way. A room that is not bridged says nothing and a reader sees
 * an ordinary roster. */
export const BRIDGE = "bridge";
/** Ask a membership for the form its bridge wants drawn right now, or null
 * when the bridge asks for nothing.
 *
 * A form is declared for the state it is in, so this is asked when a reader
 * opens the surface and is not pushed on every change. A bridge that has moved
 * on answers differently the next time somebody looks.
 *
 * The answer is JSON checked against `BridgeFormSchema`, which is how every
 * other structured value crosses this wire. */
export const BRIDGE_FORM = "bridgeForm";

/** Submit one of that form's actions with what the reader typed.
 *
 * Takes the action's id and the answers as JSON. The bridge decides whether
 * they are any good. A form says what a field is called and whether it is
 * required, and says nothing about what makes a password valid on somebody
 * else's service. */
export const SUBMIT_BRIDGE_FORM = "submitBridgeForm";

/** A bridged room's current projection of one Rooms member onto the service it
 * bridges. The member name, the seat's phase, the name they go by over there,
 * the service, and the bridge's badge and sentence follow the display text.
 *
 * Named for the seat and not for IRC because a second bridge fills the same
 * shape. The words IRC writes into it make it read as IRC. */
export const SEAT = "seat";
/** The server-owned lifecycle of one Rooms member's projection onto a bridged
 * service. Kept beside the wire token so a bridge, the parser, and the interface
 * cannot grow different phase vocabularies.
 *
 * These are link states and not words. A bridge writes what its badge says,
 * and does not get to invent a fifth thing a member can be. */
export type SeatPhase = "rooms" | "connecting" | "linked" | "failed";
