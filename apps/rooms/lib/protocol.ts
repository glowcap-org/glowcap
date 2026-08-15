// The wire contract shared by the rooms server and every rooms client, in every
// language. It is deliberately tiny: two capability names and the method verbs
// the directory, a room, and an inbox answer to. There is no schema negotiation
// and no RPC framework — just object-capability messages over OCapN.
//
// The directory is the server's one published capability. A client fetches it by
// name and eventual-sends it `open` or `enter`, each of which *returns a room
// capability* — a live reference to that specific room. The client then
// eventual-sends the room `subscribe` and `post`. When subscribing, the client
// hands the room a capability to its own `inbox` actor; the room keeps that
// capability and calls the client back with `notify` whenever anyone posts. That
// callback — the room holding a live capability to the client and invoking it —
// is the whole point of the demo, and a method returning a fresh room capability
// is the move that makes "rooms" plural.

/** The name the server publishes the directory under and clients fetch it by. */
export const DIRECTORY = "directory";

/** Directory methods a client sends. `open(name)` creates a room and returns a
 * reference to it, erroring if the name is taken; `enter(name)` returns the
 * existing room, erroring if there is no such room. `list()` returns the live
 * rooms — the ones with people in them — as `[name, count]` pairs; `watch(inbox)`
 * hands the directory an inbox capability, returns that same snapshot, and then
 * calls the inbox back with each change. */
export const OPEN = "open";
export const ENTER = "enter";
export const LIST = "list";
export const WATCH = "watch";

/** Mint the stable sturdyref for one existing room: `link(name)`. The answer is
 * the opaque swissnum, not a second spelling of the peer locator; the caller
 * composes it with the exact locator it used to reach this directory. */
export const LINK = "link";

/** The wire format every rooms peer speaks.
 *
 * Both ends of an OCapN session must name the same codec, and pancake's
 * negotiation exists for peers that do not know each other: it settles a
 * mutual preference from two offers. A closed fleet has no such problem —
 * every rooms peer is a pancake peer, written here, so the room simply
 * agrees on pancake's native word-aligned format rather than the Syrup
 * interop floor. A peer that speaks Syrup (a Goblins vat) is not a rooms
 * peer; it reaches pancake through the OCapN interop surface instead.
 */
export const CODEC = "capnp" as const;

/** The CapTP profile every rooms peer speaks.
 *
 * It travels with `CODEC`, not beside it by coincidence: ADR-0003 names
 * `next` + Cap'n Proto as the pancake-to-pancake pair (what
 * `engine.negotiation.Offer.native` prefers), and `v1_0` + Syrup as the
 * interop floor a Goblins vat and the upstream suite speak. Picking the
 * native codec while staying on the floor version would be half a
 * decision. */
export const CAPTP_VERSION = "next" as const;

/** Room methods a client sends. `subscribe(nick, inboxCap)` returns a welcome
 * line; `post(text)` broadcasts to every subscriber; `typing(on)` broadcasts an
 * ephemeral "I am typing" flag to the other members and is never stored or
 * echoed; `leave()` drops this membership (so a client can switch rooms on one
 * connection) without closing the connection. */
export const SUBSCRIBE = "subscribe";
export const POST = "post";
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
export const EDIT = "edit";
export const WITHDRAW = "withdraw";

/** The tags a room puts at the third argument of a line it sends. See the note
 * below for the whole set and why an unknown one is skipped rather than
 * refused. */
export const LINE = "line";
export const EDITED = "edited";
export const WITHDRAWN = "withdrawn";
export const TYPING = "typing";
export const LEAVE = "leave";
export const TOPIC = "topic";
export const LINE_BYTES = "line-bytes";
/** Both the verb and the tag, the way `leave` is: `away(reason)` says this
 * membership has stepped away and `away("")` says it is back, and the room
 * states the same word about a member. Nothing is handed over for it, because a
 * member's own standing is theirs to state and the room already knows which
 * membership is calling. */
export const AWAY = "away";

/** The method on the reference `subscribe` answers with: what this room is
 * about.
 *
 * Same shape as a line's reference, one level up. Holding it is the authority
 * to set the topic, so the room asks nobody whether they may — and because it
 * is a reference rather than a rank, a member can hand it to somebody who is
 * not even here, which is how a room lets a bot keep its own topic without
 * learning what a bot is. */
export const SET_TOPIC = "setTopic";

/** What rides after a room line's display text, at the third argument.
 *
 * A subscriber that does not know a tag skips it, which is what lets the room
 * say more over time without every client being rebuilt first: an older client
 * meeting a line it cannot interpret still draws the line.
 *
 *   `"line"`, id            an ordinary line, and the id this room knows it by
 *   `"edited"`, id          that line now reads as this notify's text
 *   `"withdrawn"`, id       that line is taken back
 *   `"roster"`, …names      who is here, on arrival
 *   `"join"` / `"leave"`, nick
 *   `"typing"`, nick, on
 *   `"away"`, nick, reason  that member has stepped away; empty reason is back
 *   `"topic"`, text         what the room is about; empty means taken down
 *   `"line-bytes"`, n       the longest line this room will carry
 *
 * An id names a line within one room for as long as that room lives. The room
 * keeps no history, so an id refers to something only its current subscribers
 * hold — which is why an edit reaches whoever was here and nobody who arrives
 * later, the same way the line itself did. */

/** Directory introduction methods (three-party handoff, gifter side).
 *
 * `register(nick, locator, inboxCap)` claims a name and answers
 * `notify("registered", nick)`. The locator is for the directory's own checks
 * (and nick identity); after ADR-0109, gift exporter location comes from the
 * member's signed hello, not from stamping this argument. A second `register` for the same nick replaces
 * the prior intro when it comes from the connection holding it, and is refused
 * `nick-taken` when it comes from another while that connection is open — a
 * registration is a claim on a name, and only its holder or its ending frees it.
 * `introduce(nick)` returns the inbox that member offered for *this* caller (see
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
 * arrives over relayed TCP while being reachable at a webrtc or keyed-relay
 * designator —
 * so this is not a property of the member's own transport, and keying the
 * directory's connections is what would close it. */
export const REGISTER = "register";
export const INTRODUCE = "introduce";

/** Offer the directory an inbox to introduce one named peer to:
 * `offerInbox(forNick, inbox)`.
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
 * The directory asks for one it needs with `notify("mintInboxFor", peer)` on the
 * member's register inbox. A member may also offer unasked, which is what a client
 * watching the roster does as members appear.
 *
 * Nicks match case-insensitively, so key your own inbox table the same way. */
export const OFFER_INBOX = "offerInbox";

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
export const OFFER_SIGNALING = "offerSignaling";
export const SIGNAL_OFFER = "signalOffer";
export const SIGNAL_ANSWER = "signalAnswer";
export const SIGNAL_CANDIDATE = "signalCandidate";
export const SIGNAL_DONE = "signalDone";

/** The verbs a signaling inbox and a signaling reply capability answer:
 * `offer(id, sdp)` and `candidate(id, ice)` on the member's filed inbox;
 * `accepted(id)`, `answer(sdp)`, `candidate(ice)`, and `reject(reason)` on the
 * offerer's `reply`. */
export const SIG_OFFER = "offer";
export const SIG_ACCEPTED = "accepted";
export const SIG_ANSWER = "answer";
export const SIG_CANDIDATE = "candidate";
export const SIG_REJECT = "reject";

/** Media in room messages. An attachment is uploaded to the room, and the room
 * hands every member a live reference to the blob it hosts. Direct messages
 * use the same trailing file records, but their sender hosts each blob on the
 * direct session and needs no room upload.
 *
 * A file is staged into a message rather than posted on its own, the way a
 * person writes one: pick the files, write the line, send it once.
 *
 * `attach(name, mime, size, width, height)` on a room returns an **upload
 * capability** for one file, held only by the member that asked for it, and
 * holding it is the authority to fill or throw away that file. The uploader
 * calls `discard()` if the writer changes its mind before sending.
 *
 * `postFiles(caption)` on the room publishes them: every upload this
 * connection has staged, oldest first, as one message. The member's own
 * staged set is the room's pending set for that connection, so nothing has to
 * be named twice, and a message may carry up to `MAX_MESSAGE_FILES`.
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
 * Every member then hears `notify(from, caption, ...records)`, where each
 * record is `"file", name, mime, size, blob, width, height` and `blob` is a
 * reference to the room's own object. One message carries as many records as
 * it had files, one after another. A client that predates attachments reads
 * the first two arguments and shows the caption, so the change is additive on
 * the wire. */
export const ATTACH = "attach";
export const POST_FILES = "postFiles";

/** Upload-capability verbs: `write(chunk)` appends bytes to the file being
 * uploaded after publication, and `discard()` throws it away — what removing
 * a file from a half-written message does. */
export const WRITE = "write";
export const DISCARD = "discard";

/** The one verb a blob capability answers: `read(offset, maxLen)` returns the
 * bytes at `offset`, at most `min(maxLen, BLOB_CHUNK)` of them, and an empty
 * slice at the end. The offset is the reader's own cursor, so two readers of
 * one file never share state and a reader pulls the file in bounded chunks.
 *
 * A read past the arrived prefix waits until that file advances. Completion
 * answers the terminal empty slice; failure breaks the wait. */
export const READ = "read";

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
 * process-wide ceiling fills. */
export const DM = "dm";

/** The one callback verb, on whatever inbox a client hands over.
 *
 * A room calls `notify(from, text)` with each posted line. The directory calls
 * `notify(event, name, count)` on a watcher for every change to its live state:
 * a room `"opened"` / `"closed"` / `"count"` (where `name` is the room and
 * `count` its members), and a member becoming `"registered"` / `"unregistered"`
 * for direct messages (where `name` is the member's nick and `count` is 1 or 0).
 * A member's own register inbox also hears `notify("registered", nick)`, the
 * signal that its name is granted. It hears
 * `notify("mintInboxFor", peer)` when someone has asked to be introduced and
 * the member has offered no inbox for them yet: mint one and `offerInbox` it.
 * It hears `notify("introducible", peer)` when a peer it was waiting on has
 * offered an inbox, so an `introduce` that was refused `introduction-pending`
 * is worth retrying.
 *
 * That notice can arrive before the refusal it belongs to, and a client which
 * parks the line rather than handing the refusal back to its caller has to
 * expect it. One `introduce` makes the room do two things: ask the member for an
 * inbox, and refuse the asker as pending. A member that offers quickly gets
 * `introducible` to the asker first, where it finds nothing waiting yet, and
 * there is no second notice to come. So a parking client remembers a notice that
 * arrived early and lets the refusal ask again at once. `room_client.ts` keeps
 * that memo, and so does the Goblins vat's `conformance/goblins-peer/racket/
 * rooms-dm.rkt`; a client that surfaces the refusal instead needs neither.
 *
 * A room also pushes an ephemeral typing signal on this same inbox as
 * `notify("room", "", "typing", nick, on)`: `nick` is the member who started or
 * stopped typing and `on` is a boolean. It carries no line text and is never
 * stored, so a client that does not care simply skips any `notify` whose third
 * argument is `"typing"`. */
export const NOTIFY = "notify";
