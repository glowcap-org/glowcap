// Direct-inbox handover verbs: live capabilities and their durable data twins.

/** Hand somebody the room itself, over the direct line you already have with
 * them: `handRoom(label, room)` on their direct-message inbox.
 *
 * The second argument is the live reference. It crosses as a third-party
 * handoff — the sender's runtime deposits the gift and the receiver's redeems
 * it during delivery — so what arrives is a working reference to the room,
 * with nothing asked of the room or the directory about who may be handed
 * what. The label is only what the sender calls it.
 *
 * This is the invitation. It costs the server nothing durable, which its
 * data-shaped sibling below cannot say, and it lives exactly as long as live
 * references live: the offer dies with the sessions under it, and taking it up
 * later than that means asking for another. */
export const HAND_ROOM = "handRoom";

/** Hand somebody a scoped archive facet over the direct line already joining
 * the two members: `handArchive(directory, kind, conversation, archive)`.
 *
 * `kind` is `direct`, `room`, or `standing`. `conversation` is that kind's
 * archive coordinate, or `null` only for directory-wide standing. `archive` is
 * a live read-only capability. The pipe is the DM; the facet scope is not
 * required to be that DM. The reference crosses through ordinary third-party
 * handoff; the room and directory carry none of the history or the authority. */
export const HAND_ARCHIVE = "handArchive";

/** The durable sibling: `offerRoom(label, link)` on the same inbox, both
 * arguments strings.
 *
 * The link is a sturdyref the room minted for whoever holds it (`LINK`), so
 * this offer survives every connection under it and can be passed on as text.
 * The price is the mint: a durable name is server state that outlives the
 * room, so this is for an invitation that must outlive the sessions carrying
 * it, not the ordinary hand-over. */
export const OFFER_ROOM = "offerRoom";

/** The archive sibling of `offerRoom`: `offerArchive(directory, kind,
 * conversation, sturdyref)` on the same inbox, all data.
 *
 * The sturdyref is a Host publication the archive peer minted for an exact
 * filter. Only that peer can revoke it. A live `handArchive` occurrence is a
 * different object and dies with its session. */
export const OFFER_ARCHIVE = "offerArchive";
