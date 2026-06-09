// The rooms chat server, written on pancake actors in native Deno.
//
// It hosts one shared chat room and accepts any number of OCapN clients over
// TCP — in any language. Each client subscribes with a nickname and a capability
// to its own inbox; the room keeps every subscriber's inbox capability and, when
// anyone posts, calls each one back with `notify`. The clients never poll: the
// room pushes to them because it holds a live capability to each.
//
// Read how short this is. `listen` yields a `Connection` per client; `publish`
// makes the room fetchable by name; the room behavior is a plain function of
// `(verb, args)`; a subscriber's inbox arrives as a `Ref` the room sends to. No
// peer, no vat, no manual flush, no hand-rolled serve loop — the capability
// model is the whole program.
//
// Run it with a port:  deno run --allow-ffi --allow-net --allow-read server.ts 9099
// With port 0 it binds an ephemeral port and prints it, which the demo harness
// reads to point clients at the right place.

import {
  type AppValue,
  Connection,
  listen,
  Ref,
} from "../../../../bindings/deno/pancake.ts";
import { NOTIFY, POST, ROOM, SUBSCRIBE } from "./protocol.ts";

/** One subscriber: the nickname it chose and the capability to call it back on,
 * plus the connection that capability lives on (a far ref is sent over the
 * connection that holds it). */
interface Member {
  nick: string;
  inbox: Ref;
  conn: Connection;
}

const members: Member[] = [];

function remove(conn: Connection): void {
  const i = members.findIndex((m) => m.conn === conn);
  if (i >= 0) members.splice(i, 1);
}

/** Push `from: text` to every subscriber by calling the inbox capability it gave
 * us. `tell` is the fire-and-forget eventual-send: a notify wants no reply, so it
 * costs one deliver with no answer round-trip. A member whose socket has died is
 * dropped from the roster. */
function broadcast(from: string, text: string): void {
  for (const m of [...members]) {
    m.conn.tell(m.inbox, NOTIFY, [from, text]).catch(() => remove(m.conn));
  }
}

/** The room behavior for one connection. It closes over the one nickname this
 * connection speaks for, so `post` needs no "from" argument — the capability the
 * post arrives on is the identity. */
function roomBehavior(conn: Connection) {
  let nick = "anon";
  return (verb: string, args: AppValue[]): AppValue => {
    if (verb === SUBSCRIBE) {
      nick = typeof args[0] === "string" ? args[0] : "anon";
      const inbox = args[1];
      if (!(inbox instanceof Ref)) throw new Error("subscribe needs an inbox capability");
      members.push({ nick, inbox, conn });
      broadcast("room", `${nick} joined (${members.length} here)`);
      return `welcome ${nick} — ${members.length} in the room`;
    }
    if (verb === POST) {
      broadcast(nick, typeof args[0] === "string" ? args[0] : "");
      return null;
    }
    throw new Error(`room has no method ${verb}`);
  };
}

const port = Number(Deno.args[0] ?? "0");
const server = listen("127.0.0.1", port);
// The harness parses this line to learn the ephemeral port.
console.log(`ROOMS-SERVER-LISTENING ${server.port}`);

for await (const conn of server) {
  conn.publish(ROOM, roomBehavior(conn)); // fetchable by name
  conn.serve().catch(() => remove(conn));
}
