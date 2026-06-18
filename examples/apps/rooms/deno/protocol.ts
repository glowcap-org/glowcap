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
 * line; `post(text)` broadcasts to every subscriber; `leave()` drops this
 * membership (so a client can switch rooms on one connection) without closing
 * the connection. */
export const SUBSCRIBE = "subscribe";
export const POST = "post";
export const LEAVE = "leave";

/** Directory introduction methods (three-party handoff, gifter side).
 *
 * A member is a full peer: it listens on its own endpoint and exports a `dm`
 * object. `register(nick, locator, inboxCap)` tells the directory the member's
 * dialable locator; the directory dials it back, fetches its `dm`, holds the
 * reference, and pushes `notify("registered", nick)` to the inbox once it is
 * introducible. `introduce(nick)` returns that member's `dm` reference — which,
 * living on the directory↔member connection, the binding transparently turns
 * into a `desc:handoff-give`: the caller redeems it by dialing the member
 * *directly* and never routes its DMs through the directory. */
export const REGISTER = "register";
export const INTRODUCE = "introduce";

/** The verb a member's exported `dm` object answers: `dm(text)` delivers one
 * direct message. The whole point of the introduction is that this call travels
 * on the caller's own direct connection to the member, never through the room. */
export const DM = "dm";

/** The one callback verb, on whatever inbox a client hands over. A room calls
 * `notify(from, text)` with each line; the directory calls `notify(event, name,
 * count)` on a watcher, where `event` is `"opened"`, `"closed"`, or `"count"`. */
export const NOTIFY = "notify";
