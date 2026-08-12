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
export const TYPING = "typing";
export const LEAVE = "leave";

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
 * arrives over relayed TCP while being reachable at a noise-relay designator —
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

/** The verb a member's exported inbox answers: `dm(text, reply?)`
 *
 * There is no sender argument; the inbox is the sender (see `offerInbox`). The
 * call travels on the caller's own direct connection to the member, never through
 * the room.
 *
 * `reply` is an optional capability the sender hosts on this same direct
 * connection: a `dm(text)` inbox the member answers over the arriving connection
 * (`currentSession()`), so the two talk both ways without the member ever dialing
 * the sender. That matters when the sender is a browser that cannot be dialed. A
 * sender that wants no replies omits it. */
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
