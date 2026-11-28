// Room presence and advertised room features.

/** What the room carries of a message beyond its text and files, stated at
 * arrival as `notify("room", "", "carries", ...features)`, before the roster,
 * so a client holds it by the time joining returns.
 *
 * This is description, not authority, so the room states it instead of
 * handing over a facet. Nothing a member holds could say whether the room
 * keeps the link previews a line names (`previews`) or relays the typing
 * signal (`typing`). A room bridged to IRC does neither and says so. A native room also advertises
 * `profiles` for member introductions and `retained` for delivery and upload reuse.
 * The vocabulary is positive and additive: a feature named is carried, one not
 * named is not, and one a client does not know is skipped. A room that never
 * states the fact has not said it lacks anything, and a client keeps every
 * control for existing features. Publishing a profile requires explicit support. */
export { CARRIES } from "./protocol_data.ts";
/** Displayed features. `retained` is negotiated by the Rust membership client. */
export const ROOM_FEATURES = ["previews", "typing", "profiles"] as const;
export type RoomFeature = typeof ROOM_FEATURES[number];

/** Both the verb and the tag, like `leave`. `away(reason)` says this
 * membership has stepped away and `away("")` says it is back, and the room
 * states the same word about a member. No facet is handed over, because a
 * member's standing is theirs to state and the room knows which membership is
 * calling. */
export { AWAY } from "./protocol_data.ts";

/** On an exact participant seat, setProfile(kind, about) publishes its
 * introduction to current room members. Both empty strings clear it. */
export { PROFILE, PROFILES, SET_PROFILE } from "./protocol_data.ts";
