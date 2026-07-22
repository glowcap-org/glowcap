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
 * A member publishes a giftable `dm` on the registering session and listens for
 * redeem on that Host. `register(nick, locator, inboxCap)` tells the directory
 * to `fetch("dm")` on that session, stamp `locator` as the gift exporter
 * location, and `notify("registered", nick)` once ready. A second `register`
 * for the same nick replaces the prior intro. `introduce(nick)` returns that
 * `dm` reference as a `desc:handoff-give`: the caller redeems by dialing the
 * member *directly*. */
export const REGISTER = "register";
export const INTRODUCE = "introduce";

/** The verb a member's exported `dm` object answers: `dm(from, text, reply?)`
 * delivers one direct message and names its sender. The whole point of the
 * introduction is that this call travels on the caller's own direct connection
 * to the member, never through the room. `from` is the sender's display nick;
 * the authority to reach this inbox at all is the redeemed capability, not the
 * label.
 *
 * `reply` is an optional capability the sender hosts on this same direct
 * connection: a `dm(from, text)` inbox the member answers over the arriving
 * connection (`currentSession()`), so the two talk both ways without the member
 * ever dialing the sender — which matters when the sender is a browser that
 * cannot be dialed. A sender that wants no replies omits it; a member that does
 * not reply ignores it. */
export const DM = "dm";

/** The one callback verb, on whatever inbox a client hands over.
 *
 * A room calls `notify(from, text)` with each posted line. The directory calls
 * `notify(event, name, count)` on a watcher for every change to its live state:
 * a room `"opened"` / `"closed"` / `"count"` (where `name` is the room and
 * `count` its members), and a member becoming `"registered"` / `"unregistered"`
 * for direct messages (where `name` is the member's nick and `count` is 1 or 0).
 * A member's own register inbox also hears `notify("registered", nick)` once
 * register has fetched `dm`, the signal that its nick is introducible.
 *
 * A room also pushes an ephemeral typing signal on this same inbox as
 * `notify("room", "", "typing", nick, on)`: `nick` is the member who started or
 * stopped typing and `on` is a boolean. It carries no line text and is never
 * stored, so a client that does not care simply skips any `notify` whose third
 * argument is `"typing"`. */
export const NOTIFY = "notify";
