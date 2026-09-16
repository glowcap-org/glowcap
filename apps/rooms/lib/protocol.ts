// The wire contract shared by the rooms server and every rooms client, in every
// language. It is deliberately plain: the directory's published name, the
// method verbs the directory, a room, and an inbox answer to, and, when the
// process is started that way, one extra Host publication whose swiss is the
// inspect capability. There is no schema negotiation and no RPC framework,
// just object-capability messages over OCapN. Three families whose speakers
// are their own trees live beside this file: handover in
// `protocol_handover.ts`, IRC bridging in `protocol_irc.ts`, and the operator
// surface in `protocol_operator.ts`.
//
// The directory is the server's ordinary published capability. A client fetches it by
// name and eventual-sends it `open` or `enter`, each of which returns a room
// entrance capability. The entrance identifies the room and can answer queries,
// but it is not a membership or a promise that the live room is allocated. The
// client sends the entrance `subscribe`, which reconstitutes the live room when
// no live instance exists, then sends membership verbs such as `post` to the
// seat that call answers with. When subscribing, the client supplies a
// capability to its own `inbox` actor; the live room keeps that capability and
// calls the client back with `notify` whenever anyone posts. That callback —
// the room holding a live capability to the client and invoking it — is the
// shape everything here builds on, and a method returning a fresh room
// capability is the move that makes "rooms" plural.

/** The name the server publishes the directory under and clients fetch it by. */
export { DIRECTORY } from "./protocol_data.ts";

/** What the operator inspect object answers.
 *
 * It is not a directory method. The directory stays what every member fetches;
 * inspect is a second Host publication under an unguessable swiss, minted only
 * when the process is started with `--diagnostics`. Holding that swiss is the
 * capability: a client fetches it the same way it fetches `directory`, then
 * sends `snapshot` and gets the names this directory currently holds, as
 * `[kind, name, note]` rows. It does not return live room references.
 *
 * Because its holder is the Rooms operator, the rows include every room the
 * directory holds, private ones by their label with their occupants: a private
 * room's privacy is absence from the user-facing `list` and `watch`, not from
 * the operator who runs the process. */
export { SNAPSHOT } from "./protocol_data.ts";

/** Directory methods a client sends. `open(name, private?)` creates a room and
 * returns its entrance, erroring if a public name is taken; `enter(name)`
 * returns an entrance for the existing room, erroring if there is no such room.
 * `list()` and `watch(inbox)` retain the Goblins-compatible
 * `[name, count|null]` records.
 * `listPublications()` and `watchPublications(inbox)` are the rooms extension:
 * they add `[id, kind, origin, proof]`, and the exact `id` is accepted by
 * `enterPublication(id)`. Keeping this choice in the directory verb avoids
 * coupling an application record shape to CapTP transport negotiation.
 *
 * `open(name, true, recoveryKey)` makes a private room. The boolean is the
 * whole of what private means here, while the opaque key makes a lost request
 * safely repeatable. Such a room is in no list, has no deltas,
 * and cannot be entered by name — because none of those is how you reach one.
 * You reach one by holding a reference somebody handed you,
 * which is the rule a posted line's `edit` and a room's `setTopic` already
 * follow, applied to the room itself. So there is no member list to be added
 * to, no check to pass, and nothing to ask the server about anybody's right to
 * be here.
 *
 * Its name is a label rather than an address: two readers may each keep a
 * private room called the same thing without either learning of the other,
 * which is also why `open` cannot answer "that name is taken" for one. That
 * answer is itself the leak.
 *
 * An ordinary private `open` answers only a room entrance reference. Managed
 * open also supplies the authority that makes its entry durable. A durable
 * session may instead use `openPrivateLink`, which commits the opaque recovery
 * key and answers its sturdyref as one idempotent directory act, with no
 * temporary reference to strand if the answer is lost. */
export { OPEN } from "./protocol_data.ts";
/** Rooms-native creation with explicit management authority. Baseline `open`
 * remains the room-only operation. This first answers a room entrance
 * reference and one-use bootstrap reference; `roomAuthorities` on the
 * bootstrap returns the durable room-entry and manager sturdyrefs as strings. */
export { OPEN_MANAGED, ROOM_AUTHORITIES } from "./protocol_data.ts";
/** Persist and return one private-room sturdyref from an opaque recovery key.
 * This is one directory act so a lost answer never strands a live room between
 * creation and link publication. */
export { OPEN_PRIVATE_LINK } from "./protocol_data.ts";
export { ENTER } from "./protocol_data.ts";
/** Enter the exact public-room generation named by a list/watch record. */
export { ENTER_PUBLICATION } from "./protocol_data.ts";
export { LIST, LIST_PUBLICATIONS, WATCH, WATCH_PUBLICATIONS } from "./protocol_data.ts";
export type RoomRecordShape = "baseline" | "publication";
/** The directory's preferred durable location, derived from live listeners. */
export { ADVERTISED_LOCATION } from "./protocol_data.ts";

/** The opt-in directory-peering capability and the exact lease it returns.
 * `publishDurableRoom(name, room)` adds one source-session-owned foreign room;
 * `revoke()` removes only that exact publication generation. */
export { PUBLISH_DURABLE_ROOM } from "./protocol_data.ts";
/** Wait until the publication's handed room has resolved to a live object. */
export { PUBLICATION_READY, REVOKE } from "./protocol_data.ts";

/** Mint the stable sturdyref for one existing room: `link(name)`. The Host
 * answers the complete link, composing its durable entrance publication with
 * the location it authors for this exact session. Redeeming the link answers
 * an entrance; the first successful subscription reconstitutes the live room
 * after it has emptied or the server has restarted. */
export { LINK } from "./protocol_data.ts";

/** Room and membership methods a client sends. `subscribe(nick, inboxCap,
 * voucher?)` returns `[seat, kind, topic, files]`. The client sends
 * `post(text)`, `typing(on)`, and `leave()` to that seat. A post broadcasts
 * to every subscriber; typing is ephemeral and never stored or echoed;
 * leaving drops this membership without closing the connection.
 *
 * The last two slots are facets the room hands over or withholds, and a
 * client draws its controls from holding them rather than from anything the
 * room says about itself. `topic` is the authority to set what the room is
 * about, handed to a participant in a room that lets members do that. `files`
 * is the authority to stage files against the room's storage and publish
 * them (`ATTACH`, `POST_FILES`), handed to a participant in a room that can
 * hold bytes at all; a room bridged to a service with no way to carry a file
 * answers null there, and a client that holds nothing draws no attach control.
 * An observer seat holds neither. What a member can *do* is what they hold;
 * what the room *keeps* of a message that no capability stands for, it states
 * instead (`CARRIES`).
 *
 * The voucher is the third argument only a subscribe arriving on the wrong
 * connection needs: proof, minted by the name capability (`VOUCHER`), that the
 * caller is the held name's own holder. Without one, a name held elsewhere is
 * refused as it always was. */
export { POST, SUBSCRIBE } from "./protocol_data.ts";
/** Methods on the reference `post` answers with: the line it just made.
 *
 * Holding that reference is the authority to change or withdraw that one line,
 * so neither verb asks who is calling. Nothing checks ownership because nothing
 * has to — a member without the reference cannot form the request, which is the
 * same shape `attach` already uses for a file.
 *
 * It also means the authority can be handed on. A member can give their line's
 * reference to somebody they want able to take it down, and a room can keep its
 * own copy to give whoever it wants moderating, without either party growing a
 * concept of a moderator. */
export { EDIT, WITHDRAW } from "./protocol_data.ts";
/** Replace the files on a line already posted: `refile(caption, ...keep)`.
 *
 * `keep` is the indices of this line's current files, in the order the poster
 * wants them kept, and the connection's own newly-staged uploads (the same
 * `attach` staging a first post uses) are appended after them. So removing a
 * file names every index but that one, adding files stages them and names all
 * the current indices, and replacing is both at once. A kept file is not
 * re-uploaded — it is already the room's to hold, named by position.
 *
 * `edit` stays text-only on purpose, so a caption change leaves the files
 * alone; `refile` is the one verb that changes the set. Refiling a line down
 * to no files and no caption withdraws it, because an empty line is nothing. */
export { REFILE } from "./protocol_data.ts";

/** The tags a room puts at the third argument of a line it sends. See the note
 * below for the whole set and why an unknown one is skipped rather than
 * refused. */
export { LINE } from "./protocol_data.ts";
/** Ask a room what it kept of its own conversation. A server that keeps no
 * history refuses the optional verb, distinct from an enabled room answering
 * with an empty retained tail. */
export { EDITED, HISTORY, WITHDRAWN } from "./protocol_data.ts";
/** The tag a room puts on a line whose file set changed: `refiled`, id, then
 * the complete new run of file records. The client replaces that line's whole
 * set from the records. Native rooms reuse each live blob reference on the
 * receiving connection, so retaining a file does not require downloading it
 * again. A client that predates this skips the tag and keeps
 * showing the files it already had, which is stale but never wrong. */
export { LEAVE, LINE_BYTES, REFILED, TOPIC, TYPING } from "./protocol_data.ts";
/** What the room carries of a message beyond its text and files, stated at
 * arrival as `notify("room", "", "carries", ...features)`, before the roster,
 * so a client holds it by the time joining returns.
 *
 * This is description, not authority, which is why it is a fact the room
 * states rather than a facet it hands over: nothing a member holds could say
 * whether the room keeps the link previews a line names (`previews`) or
 * relays the typing signal (`typing`). A room bridged to IRC does neither and
 * says so; a native room also advertises `retained` for correlated delivery
 * and upload reuse. The vocabulary is positive and additive:
 * a feature named is carried, one not named is not, and one a client does not
 * know is skipped. A room that never states the fact has not said it lacks
 * anything, and a client keeps every control it has. */
export { CARRIES } from "./protocol_data.ts";
/** Displayed features; `retained` is negotiated by the Rust membership client. */
export const ROOM_FEATURES = ["previews", "typing"] as const;
export type RoomFeature = typeof ROOM_FEATURES[number];

/* A client that received `retained` may send `postRetained(text, previews,
 * request)` to its seat or `postFilesRetained(caption, previews, request)` to
 * its files facet. `previews` is false for none or the encoded selection, and
 * `request` is a unique membership-local integer from 0 through 2^53 - 1.
 * These verbs reject before committing and answer with ordinary line authority.
 *
 * On the subscribing connection, the ordered callback is
 * `receipt(request, lineId, from, canonicalText, previews, ...fileRecords)`.
 * False `canonicalText` means use the retained request text; a string replaces
 * it, including the server's default file caption. False `previews` means none.
 * Rejection sends `receiptRejected(request)` to that same inbox, independently
 * of the call's broken answer. It releases text even if awaiting was cancelled.
 * The caller retains text until either inbox completion or membership
 * close. Cancellation and uncertain delivery do not release it. Other members
 * receive ordinary complete notifications. A call delegated to another
 * connection also leaves the subscribing member's complete notification intact.
 *
 * `attachRetained` takes the same arguments as `attach` and returns
 * `[uploadCapability, readCapability]`. A client can associate an immutable
 * local upload capture with that read capability, making it available only
 * after the upload is acknowledged. The server uses that same live reference
 * when notifying this connection. Receipt vocabulary and validation are owned
 * by `rust/application/src/room/receipt.rs`.
 */

/** Arrival tags: whether this occupancy is a directory name. Additive; an older
 * client skips them. `/join` of a locator seats from this, not from a method
 * asked before subscribe. */
export { LISTED, UNLISTED } from "./protocol_data.ts";
/** Both the verb and the tag, the way `leave` is: `away(reason)` says this
 * membership has stepped away and `away("")` says it is back, and the room
 * states the same word about a member. Nothing is handed over for it, because a
 * member's own standing is theirs to state and the room already knows which
 * membership is calling. */
export { AWAY } from "./protocol_data.ts";
/** The steward's one verb: ask a member, by nick, to leave. A steward is
 * handed out by the room manager's `giveSteward` (`protocol_operator.ts`) or
 * by the operator capability, never asked of the room by a nickname. */
export { KICK } from "./protocol_data.ts";
/** Ask a steward which room publication it governs. The answer is the room's
 * public identity digest, never its bearer swiss number, so a client can prove
 * a handed-over steward belongs to the room without gaining room authority. */
export { GOVERNS, MANAGED_ROOM_IDENTITY } from "./protocol_data.ts";

/** What this room calls itself: `called()`.
 *
 * A sturdyref does not carry a name — that is what makes a private room's link
 * unguessable from its label. The live room still has one: a public room's
 * directory name, or a private room's label while anybody is in it. Empty when
 * a private room was reconstituted from a link and has no label left to give.
 * `/join` of a locator with nothing after it asks this rather than inventing
 * a name. */
export { CALLED } from "./protocol_data.ts";

/** Direct question: `private()`. Answers `"private"` or `"listed"`. Join does
 * not ask this — listed-ness arrives on subscribe as `LISTED` / `UNLISTED`. */
export { PRIVATE } from "./protocol_data.ts";
/** Exact room admission policy: `access()` answers `public`, `invite-only`, or
 * `private`. `private()` remains the coarse compatibility question. */
export { ROOM_POLICY, ROOM_POLICY_CHANGED } from "./protocol_data.ts";
/** A live seat answers whether it is an observer or participant. */
export { MEMBERSHIP_KIND } from "./protocol_data.ts";
/** Mint one consumable entrance from a participant membership. */
export { MINT_INVITATION } from "./protocol_data.ts";
/** Claim a one-shot entrance with a retry receipt chosen by the claimant. */
export { CLAIM_INVITATION } from "./protocol_data.ts";

/** The method on the topic reference in `subscribe`'s answer: what this room is
 * about. Participant answers carry this reference in their third slot;
 * observer answers carry null.
 *
 * Same shape as a line's reference, one level up. Holding it is the authority
 * to set the topic, so the room asks nobody whether they may — and because it
 * is a reference rather than a rank, a member can hand it to somebody who is
 * not even here, which is how a room lets a bot keep its own topic without
 * learning what a bot is. */
export { SET_TOPIC } from "./protocol_data.ts";

/** Ask a room or its manager for the current durable entry link: `link()`.
 *
 * An ordinary room reference returns only a link that already exists. The
 * separate room manager capability may create or reissue one. What comes back
 * is a complete sturdyref, and whoever holds that string can redeem it into
 * the room's entrance over any channel, including after everybody has left.
 * The link retains admission authority and stable room identity, not a live
 * room allocation or membership.
 *
 * A private room mints one from its own unguessable name rather than its
 * label, so the link says nothing about what the room is called and the label
 * says nothing about the link. The directory's `link` verb asks for the same
 * existing link by public name, which is why it answers nothing for a private
 * room and never conveys management authority. */

export { HAND_ARCHIVE, HAND_ROOM, OFFER_ARCHIVE, OFFER_ROOM } from "./protocol_handover.ts";

// What rides after a room line's display text, at the third argument. This is
// the whole set the `LINE` tag above points at, and it documents no one
// declaration, so it is a standing note rather than a doc comment.
//
// A subscriber that does not know a tag skips it. The room can therefore say
// more over time without requiring every client to be rebuilt first: a client
// meeting a tag it cannot interpret still draws the line.
//
//   `"line"`, id            an ordinary line, and the id this room knows it by
//   `"line"`, id, …files    a line carrying that id and a run of file records
//   `"edited"`, id          that line now reads as this notify's text
//   `"refiled"`, id, …files that line's files are now exactly this run
//   `"withdrawn"`, id       that line is taken back
//   `"roster"`, …names      who is here, on arrival
//   `"join"` / `"leave"`, nick
//   `"typing"`, nick, on
//   `"away"`, nick, reason  that member has stepped away; empty reason is back
//   `"topic"`, text         what the room is about; empty means taken down
//   `"line-bytes"`, n       the longest line this room will carry
//
// An id names a line within one live room generation. Current subscribers use
// it to apply edits and withdrawals; when retention is enabled the room uses
// the same id to update or remove its kept copy before answering later history
// requests.

/** Directory introduction methods (three-party handoff, gifter side).
 *
 * `register(nick, locator, inboxCap, allocationMode?, reconnectVoucher?)` claims a name and answers
 * `notify("registered", grantedNick, registrationId)`. Calls without a mode retain the original
 * exact-name contract. `"automatic"` treats `nick` as a base and atomically grants its first free
 * conventional spelling, such as `guest-2`; `"exact"` never changes the requested spelling. The
 * opaque registration ID identifies this exact
 * live registration without granting authority. The locator is for the directory's own checks
 * (and nick identity); after ADR-0109, gift exporter location comes from the
 * member's signed hello, not from stamping this argument. A second `register` for the same nick replaces
 * the prior intro when it comes from the connection holding it. A new connection
 * may replace that exact live claim with a single-use voucher minted by the old
 * name capability; another caller is refused `nick-taken` while the holder remains open.
 * `introduce(nick, registrationId)` returns the inbox that registration offered for
 * *this* caller (see
 * `offerInbox`) as a `desc:handoff-give`: the caller redeems by dialing the
 * member *directly*, and is refused `introduction-pending` until there is one. A
 * caller that has not registered cannot be introduced at all: the directory reads
 * the asker's name off its registration, never from the message.
 *
 * `locator` is a claim, and how far the directory can stand behind it depends on
 * the registering connection. Keyed — `keyed-tcp`, `iroh`, `webrtc`,
 * `keyed-relay`, `noise-relay` — and the handshake has verified the partner holds the key its
 * designator names, so a locator naming a different designator is refused
 * `not-your-locator`. Unkeyed and there is nothing to check it against, so the
 * directory repeats a claim it cannot vouch for: everyone it introduces will
 * dial what the registrant asked them to. The transport a member reaches the
 * directory over is not the one others reach the member over — a browser peer
 * arrives over relayed TCP while being reachable at a webrtc or noise-relay
 * designator —
 * so this is not a property of the member's own transport, and keying the
 * directory's connections is what would close it. */
export { REGISTER } from "./protocol_data.ts";
/** The one method on the name capability `register` answers with: `voucher()`.
 *
 * A registered name is held by a connection, and the capability is the
 * holding, detached from it: presenting proof minted by this capability is
 * being that member, on any connection. The proof is data — single-use
 * unguessable bytes, the gift-id move — because a reference cannot be
 * recognised by its minter after crossing sessions, while bytes can. A voucher
 * redeems in `subscribe` or a replacement `register` while the registration
 * stands and dies with it, so the name's lifetime is still the connection's;
 * nothing durable is minted here. */
export { INTRODUCE, VOUCHER } from "./protocol_data.ts";

/** Offer the directory an inbox to introduce one registered peer to:
 * `offerInbox(forNick, forRegistrationId, inbox)`.
 *
 * This is where a direct message gets its sender. The member minted this inbox
 * for one peer, and the directory hands it to that peer alone, so the inbox a
 * message arrives on is who sent it and no message has to name anybody.
 *
 * The inbox must answer on a connection this member has not seen yet: a peer
 * reaches it by redeeming the introduction, which dials this endpoint and opens a
 * fresh session. Publish it host-wide, then offer the position that name holds on
 * the directory's own connection; an object published on one session has no name
 * the redeeming connection can reach.
 *
 * An offer is filed under the offering connection's own registration, so a member
 * decides who may reach *it* and nothing else; an unregistered caller is refused.
 * Offering again for the same peer replaces the previous inbox.
 *
 * The directory asks for one it needs with `notify("mintInboxFor", peer, registrationId)` on the
 * member's register inbox. A member may also offer unasked; a client watching
 * the roster does so as members appear.
 *
 * Inbox ownership is keyed by registration ID. A reused nickname therefore
 * receives new authority rather than inheriting the prior holder's inbox. */
export { OFFER_INBOX } from "./protocol_data.ts";

/** WebRTC signaling, carried by the directory (ADR-0089).
 *
 * A member reachable at a `webrtc` locator has no socket to dial: the channel
 * to it opens through an offer, answer, and candidate exchange, and the
 * directory both parties already reach is what carries that exchange. The
 * directory routes opaque strings between the two and parses none of them,
 * the same byte-transparency a room holds for chat lines.
 *
 * `offerSignaling(inbox)` files the calling member's one signaling inbox,
 * replacing any prior one; an unregistered caller is refused. The directory
 * routes an incoming offer or candidate for that member's `webrtc` designator
 * to this inbox as `offer(id, sdp)` / `candidate(id, ice)`, where `id` names
 * the exchange.
 *
 * `signalOffer(toDesignator, sdp, reply)` starts one exchange: the directory
 * mints an exchange id, remembers `reply` (a capability the caller hosts on
 * this same directory session), and forwards the offer. Every message back to
 * the caller rides `reply`: `accepted(id)` after admission, `answer(sdp)` once,
 * then `candidate(ice)` as the far peer trickles. Behaviors are synchronous,
 * so nothing here returns a value; the whole exchange is eventual sends.
 *
 * `signalAnswer(id, sdp)` is the answering member's reply, accepted only from
 * the connection whose registration owns the exchange's target.
 *
 * Both sides use the admitted id for `signalCandidate(id, ice)`; the directory
 * resolves the direction from the calling session.
 * `signalDone(id)` retires that exact exchange after channel bring-up or
 * failure, so a late retirement cannot close a newer dial to the same peer. */
export { OFFER_SIGNALING, SIGNAL_ANSWER, SIGNAL_CANDIDATE, SIGNAL_DONE, SIGNAL_OFFER } from "./protocol_data.ts";

/** The verbs a signaling inbox and a signaling reply capability answer:
 * `offer(id, sdp)` and `candidate(id, ice)` on the member's filed inbox;
 * `accepted(id)`, `answer(sdp)`, `candidate(ice)`, and `reject(reason)` on the
 * offerer's `reply`. */
export { SIG_ACCEPTED, SIG_ANSWER, SIG_CANDIDATE, SIG_OFFER, SIG_REJECT } from "./protocol_data.ts";

/** Media in room messages. An attachment is uploaded to the room, and the room
 * hands every member a live reference to the blob it hosts. Direct messages
 * use the same trailing file records, but their sender hosts each blob on the
 * direct session and needs no room upload.
 *
 * A file is staged into a message rather than posted on its own, the way a
 * person writes one: pick the files, write the line, send it once.
 *
 * Both verbs go to the **files facet** `subscribe` answered with, never to
 * the seat: holding that facet is the authority to put files in this room,
 * and a room that cannot hold bytes answers null there instead of refusing
 * later. `attach(name, mime, size, width, height)` on it returns an **upload
 * capability** for one file, held only by the member that asked for it, and
 * holding it is the authority to fill or throw away that file. The uploader
 * calls `discard()` if the writer changes its mind before sending.
 *
 * `postFiles(caption)` on the facet publishes them: every upload this
 * connection has staged, oldest first, as one message. The member's own
 * staged set is the room's pending set for that connection, so nothing has to
 * be named twice, and a message may carry up to `MAX_MESSAGE_FILES`. It
 * answers with the same line reference `post` does, so a file line can be
 * captioned again with `edit`, have its files changed with `refile`, or be
 * taken back with `withdraw` — the whole line, its files with it.
 *
 * Once that one publication settles, the sender calls `write(chunk)` on each
 * upload capability as many times as its file needs. Writes within one file
 * remain ordered; separate file capabilities progress concurrently. A blob
 * read beyond the bytes received so far waits for that file alone. An upload
 * that goes quiet past `UPLOAD_IDLE_MS` or loses its sender breaks its parked
 * readers, without disturbing completed siblings in the same message.
 *
 * `width` and `height` are the picture's own size in pixels, zero for
 * anything that is not one or whose size the sender did not measure. They buy
 * one thing: a reader can leave the right space for a picture before its
 * bytes arrive, so a log full of images settles instead of jumping as each
 * one loads. Nothing depends on them being true — a wrong pair costs a
 * reflow, not a wrong file.
 *
 * The room hosts the bytes rather than relaying a reference to the sender's
 * own blob. That is what lets a picture stay viewable after the person who
 * posted it closes their tab, and it is what lets a browser member — which
 * nothing on the network can dial — post one at all. The cost is named: a
 * room holds `MAX_ROOM_ATTACHMENT_BYTES` of media and drops its oldest file
 * to make room, so a reference to a dropped file breaks rather than lying.
 *
 * Every member then hears `notify(from, caption, "line", id, ...records)`,
 * where each record is `"file", name, mime, size, blob, width, height` and
 * `blob` is a reference to the room's own object. The `"line"`, id pair is the
 * same one a text line carries, so a file line is named and can be edited,
 * refiled, or withdrawn; the records follow it. One message carries as many
 * records as it had files, one after another. A client that predates
 * attachments reads the first two arguments and shows the caption, skipping the
 * tag and the records the way it already skips a presence change, so the shape
 * is additive on the wire. */
export { ATTACH, POST_FILES } from "./protocol_data.ts";

/** Upload-capability verbs: `write(chunk)` appends bytes to the file being
 * uploaded after publication, and `discard()` throws it away — what removing
 * a file from a half-written message does. */
export { DISCARD, WRITE } from "./protocol_data.ts";

/** The one verb a blob capability answers: `read(offset, maxLen)` returns the
 * bytes at `offset`, at most `min(maxLen, BLOB_CHUNK)` of them, and an empty
 * slice at the end. The offset is the reader's own cursor, so two readers of
 * one file never share state and a reader pulls the file in bounded chunks.
 *
 * A read past the arrived prefix waits until that file advances. Completion
 * answers the terminal empty slice; failure breaks the wait. */
export { READ } from "./protocol_data.ts";

/** The verb a member's exported inbox answers:
 * `dm(text, reply?, ...fileRecords)`.
 *
 * There is no sender argument; the inbox is the sender (see `offerInbox`). The
 * call travels on the caller's own direct connection to the member, never through
 * the room.
 *
 * `reply` is an optional capability the sender hosts on this same direct
 * connection: a `dm(text)` inbox the member answers over the arriving connection
 * (`currentSession()`), so the two talk both ways without the member ever dialing
 * the sender. That matters when the sender is a browser that cannot be dialed. A
 * sender that wants no replies omits it. When `reply` is absent, file records
 * start directly after `text`. Each record is the same
 * `"file", name, mime, size, blob, width, height` suffix a room notification
 * carries. The blob is hosted by the sender on this direct session, so files
 * follow the DM over any transport without involving the room. The sender
 * retains a bounded set of unfetched sources and expires the oldest when that
 * process-wide ceiling fills.
 *
 * `dm` answers a line handle, the direct sibling of the reference a room's
 * `post` answers, minted by the receiver on the arriving connection. Holding it
 * is the authority to change or take back that one line, so the sender edits its
 * own message after the fact. `edit(text)` changes the caption; `withdraw()`
 * takes the line back, its files with it; `refile(caption, ...keep, ...records)`
 * changes the files, where the `keep` indices name the receiver's own held
 * files — nothing re-uploaded, because the receiver already holds them — and any
 * `records` after them are freshly sender-hosted new files. The durable owner is
 * the receiver here, where for a room it was the room, and so is the bounding: a
 * direct line has no server, so the receiver refuses what the room would — an
 * edit or caption past the line cap, an index the line does not have or names
 * twice, and a kept-plus-added set past `MAX_MESSAGE_FILES`. The final bound
 * stops a line's files compounding across refiles. A peer may answer nothing and
 * grant no line-changing authority, exactly as a room may. */
export { DM } from "./protocol_data.ts";

/** Establish the reply half of a direct line without inventing a chat message.
 * A peer that cannot dial the requester's advertised carrier may dial in the
 * other direction and hand this capability over; later messages and typing use
 * that direct route with the directory out of their path. */
export { DIRECT_READY } from "./protocol_data.ts";

/** Directory register-inbox notice that another member requested a direct
 * introduction. A target may answer by opening the reciprocal route. */
export { DIRECT_REQUESTED, REQUEST_DIRECT } from "./protocol_data.ts";
/** Resolve a nickname to the directory-issued identity of its current live
 * registration. The registration ID is comparison data, not bearer authority. */
export { MEMBER_REGISTRATION } from "./protocol_data.ts";

/** The one callback verb, on whatever inbox a client hands over.
 *
 * A room calls `notify(from, text)` with each posted line. The directory calls
 * `notify(event, name, count, registrationId?)` on a watcher for every change to its live state:
 * a room `"opened"` / `"closed"` / `"count"` (where `name` is the room and
 * `count` its members), and a member becoming `"registered"` / `"unregistered"`
 * for direct messages (where `name` is the member's nick, `count` is 1 or 0,
 * and `registrationId` identifies that registration).
 * A member's own register inbox also hears `notify("registered", nick, registrationId)`, the
 * signal that its name is granted. It hears
 * `notify("mintInboxFor", peer, registrationId)` when someone has asked to be introduced and
 * the member has offered no inbox for them yet: mint one and `offerInbox` it.
 * It hears `notify("directRequested", peer, registrationId)` whenever that peer requests an
 * introduction, so a target with the compatible carrier can establish the
 * reciprocal route before any user message is sent.
 * It hears `notify("introducible", peer, registrationId)` when a peer it was waiting on has
 * offered an inbox, so an `introduce` that was refused `introduction-pending`
 * is worth retrying.
 *
 * That notice can arrive before the refusal it belongs to, and a client which
 * parks the line rather than handing the refusal back to its caller has to
 * expect it. One `introduce` makes the room do two things: ask the member for an
 * inbox, and refuse the asker as pending. A member that offers quickly gets
 * `introducible` to the asker first, where it finds nothing waiting yet, and
 * there is no second notice to come. So a parking client remembers a notice that
 * arrived early and lets the refusal ask again at once. `lib/room/client.ts` keeps
 * that memo, and so does the Goblins vat's `conformance/goblins-peer/racket/
 * rooms-dm.rkt`; a client that surfaces the refusal instead needs neither.
 *
 * A room also pushes application-state signals on this same inbox. Keeping
 * these as additive `notify` tails means a baseline Rooms client that accepts
 * `notify(from, text, . rest)` remains compatible while a newer client can act
 * on the structured fact:
 *
 * `notify("room", "", "typing", nick, on)`: `nick` is the member who started or
 * stopped typing and `on` is a boolean. It carries no line text and is never
 * stored.
 *
 * `notify("room", reason, "membershipEnded")` says this inbox's membership is
 * over. The reason remains useful line text to an older client.
 *
 * `notify("room", "", "roomAuthorityChanged", kind, token, claimable)`
 * invalidates the exact room or steward generation. It is intentionally blank
 * line text, like the existing listed-status notification. */
export { NOTIFY } from "./protocol_data.ts";
/** `notify` tag: this room no longer holds the membership behind the inbox. */
export { MEMBERSHIP_ENDED } from "./protocol_data.ts";
/** `notify` tag: invalidate the room link alone or it and its moderator. */
export { ROOM_AUTHORITY_CHANGED } from "./protocol_data.ts";
