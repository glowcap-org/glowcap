// The wire contract shared by the rooms server and every rooms client, in every
// language. It is deliberately tiny: a capability name and the method verbs the
// room and an inbox answer to. There is no schema negotiation and no RPC
// framework — just object-capability messages over OCapN.
//
// A room is the server's published capability. A client fetches it by name and
// eventual-sends it `subscribe` and `post`. When subscribing, the client hands
// the room a capability to its own `inbox` actor; the room keeps that capability
// and calls the client back with `notify` whenever anyone posts. That callback —
// the server holding a live capability to the client and invoking it — is the
// whole point of the demo.

/** The name the server publishes the room under and clients fetch it by. */
export const ROOM = "room";

/** Room methods a client sends. `subscribe(nick, inboxCap)` returns a welcome
 * line; `post(text)` broadcasts to every subscriber and returns an ack. */
export const SUBSCRIBE = "subscribe";
export const POST = "post";

/** The method the room calls back on a subscriber's inbox: `notify(from, text)`. */
export const NOTIFY = "notify";
