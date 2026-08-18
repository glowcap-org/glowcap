// The wire contract shared by the rooms server and every rooms client, in every
// language. It is deliberately tiny: the directory's published name, the method
// verbs the directory, a room, and an inbox answer to, and — when the process is
// started that way — one extra Host publication whose swiss is the inspect
// capability. There is no schema negotiation and no RPC framework — just
// object-capability messages over OCapN.
//
// The directory is the server's ordinary published capability. A client fetches it by
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

/** What the operator inspect object answers.
 *
 * It is not a directory method. The directory stays what every member fetches;
 * inspect is a second Host publication under an unguessable swiss, minted only
 * when the process is started with `--diagnostics`. Holding that swiss is the
 * capability: a client fetches it the same way it fetches `directory`, then
 * sends `snapshot` and gets the names this directory currently holds, as
 * `[kind, name, note]` rows. It does not return live room references. */
export const SNAPSHOT = "snapshot";

/** Directory methods a client sends. `open(name, private?)` creates a room and
 * returns a reference to it, erroring if a public name is taken; `enter(name)`
 * returns the existing room, erroring if there is no such room. `list()` returns
 * the live rooms — the ones with people in them — as `[name, count]` pairs;
 * `watch(inbox)` hands the directory an inbox capability, returns that same
 * snapshot, and then calls the inbox back with each change.
 *
 * `open(name, true)` makes a private room, and that second argument is the
 * whole of what private means here. Such a room is in no list, has no deltas,
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
 * A private room has no sturdyref yet, and that is this directory's shape
 * rather than anything about privacy: `link` is a directory verb that takes a
 * room's name, and a private room has no name in that table. A sturdyref is an
 * unguessable authority like any other, so a mint on the room itself — asked
 * for by somebody already holding it — would be exactly as safe as the
 * reference they asked with. */
export const OPEN = "open";
export const ENTER = "enter";
export const LIST = "list";
export const WATCH = "watch";

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

/** Room methods a client sends. `subscribe(nick, inboxCap, voucher?)` returns
 * a welcome line; `post(text)` broadcasts to every subscriber; `typing(on)`
 * broadcasts an ephemeral "I am typing" flag to the other members and is never
 * stored or echoed; `leave()` drops this membership (so a client can switch
 * rooms on one connection) without closing the connection.
 *
 * The voucher is the third argument only a subscribe arriving on the wrong
 * connection needs: proof, minted by the name capability (`VOUCHER`), that the
 * caller is the held name's own holder. Without one, a name held elsewhere is
 * refused as it always was. */
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
export const REFILE = "refile";

/** The tags a room puts at the third argument of a line it sends. See the note
 * below for the whole set and why an unknown one is skipped rather than
 * refused. */
export const LINE = "line";
export const EDITED = "edited";
export const WITHDRAWN = "withdrawn";
/** The tag a room puts on a line whose file set changed: `refiled`, id, then
 * the complete new run of file records. The client replaces that line's whole
 * set from the records, so a kept file arrives again (with a fresh blob) rather
 * than being named to keep. A client that predates this skips the tag and keeps
 * showing the files it already had, which is stale but never wrong. */
export const REFILED = "refiled";
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

/** A durable authority to this room, asked for with the reference: `link()`.
 *
 * Holding the room is the whole of the right to mint one, the same way holding
 * it is the right to say something in it. What comes back is a swissnum the
 * caller composes with the address it reached this room at, and whoever holds
 * that string can redeem it into the room — over any channel, at any later
 * time, including after everybody has left.
 *
 * A private room mints one from its own unguessable name rather than its
 * label, so the link says nothing about what the room is called and the label
 * says nothing about the link. The directory's `link` verb is the same mint
 * asked for by *name*, which is why it answers nothing for a private room. */

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

/** The durable sibling: `offerRoom(label, link)` on the same inbox, both
 * arguments strings.
 *
 * The link is a sturdyref the room minted for whoever holds it (`LINK`), so
 * this offer survives every connection under it and can be passed on as text.
 * The price is the mint: a durable name is server state that outlives the
 * room, so this is for an invitation that must outlive the sessions carrying
 * it, not the ordinary hand-over. */
export const OFFER_ROOM = "offerRoom";

/** What rides after a room line's display text, at the third argument.
 *
 * A subscriber that does not know a tag skips it, which is what lets the room
 * say more over time without every client being rebuilt first: a client
 * meeting a tag it cannot interpret still draws the line.
 *
 *   `"line"`, id            an ordinary line, and the id this room knows it by
 *   `"line"`, id, …files    a line carrying that id and a run of file records
 *   `"edited"`, id          that line now reads as this notify's text
 *   `"refiled"`, id, …files that line's files are now exactly this run
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
/** The one method on the name capability `register` answers with: `voucher()`.
 *
 * A registered name is held by a connection, and the capability is the
 * holding, detached from it: presenting proof minted by this capability is
 * being that member, on any connection. The proof is data — single-use
 * unguessable bytes, the gift-id move — because a reference cannot be
 * recognised by its minter after crossing sessions, while bytes can. A voucher
 * redeems in `subscribe` while the registration stands and dies with it, so
 * the name's lifetime is still the connection's; nothing durable is minted
 * here. */
export const VOUCHER = "voucher";
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
 * twice, and a kept-plus-added set past `MAX_MESSAGE_FILES`, which is what stops
 * a line's files compounding across refiles. A peer may answer nothing and
 * grant no line-changing authority, exactly as a room may. */
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
