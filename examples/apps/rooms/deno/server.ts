// The rooms chat server, written on pancake actors in native Deno.
//
// It hosts one shared chat room and accepts any number of OCapN clients — in any
// language, over either transport. Each client subscribes with a nickname and a
// capability to its own inbox; the room keeps every subscriber's inbox capability
// and, when anyone posts, calls each one back with `notify`. The clients never
// poll: the room pushes to them because it holds a live capability to each.
//
// The server iterates accepted `Connection`s; `publish`
// makes the room fetchable by name; the room behavior is a plain function of
// `(verb, args)`; a subscriber's inbox arrives as a `Ref` the room sends to. No
// peer, no vat, no manual flush, no hand-rolled serve loop — the capability
// model is the whole program.
//
// Transport is chosen by the `ROOMS_TRANSPORT` env var (or `--transport=iroh`):
// the default `tcp` listens on `127.0.0.1:<port>`; `iroh` binds an encrypted-QUIC
// endpoint and announces an `ocapn://<nodeid>.iroh?direct-addresses=…` URI.
// Either way the announce line is `ROOMS-SERVER-LISTENING <locator>`, which the
// demo harness and web bridge read to point clients at the right place.
//
// Run it:  deno run --allow-ffi --allow-net --allow-read server.ts 9099
//          ROOMS_TRANSPORT=iroh deno run -A --unstable-ffi server.ts

import {
  type AppValue,
  Connection,
  type IrohServer,
  listen,
  listenIroh,
  Reachability,
  Ref,
  type Server,
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

function findByConn(conn: Connection): Member | null {
  return members.find((m) => m.conn === conn) ?? null;
}

function claimKey(nick: string): string {
  return nick.toLowerCase();
}

function claimedByAnother(conn: Connection, nick: string): boolean {
  const key = claimKey(nick);
  return members.some((m) => m.conn !== conn && claimKey(m.nick) === key);
}

function remove(conn: Connection): Member[] {
  const removed: Member[] = [];
  for (let i = members.length - 1; i >= 0; i -= 1) {
    if (members[i].conn === conn) {
      removed.unshift(members[i]);
      members.splice(i, 1);
    }
  }
  return removed;
}

function leave(conn: Connection): void {
  for (const member of remove(conn)) {
    broadcast("room", `${member.nick} left (${members.length} here)`);
  }
}

/** Push `from: text` to every subscriber by calling the inbox capability it gave
 * us. `tell` is the fire-and-forget eventual-send: a notify wants no reply, so it
 * costs one deliver with no answer round-trip. A member whose socket has died is
 * dropped from the roster. */
function broadcast(from: string, text: string): void {
  for (const m of [...members]) {
    m.conn.tell(m.inbox, NOTIFY, [from, text]).catch(() => leave(m.conn));
  }
}

/** The room behavior for one connection. The room grants at most one live
 * membership to the connection, so `post` needs no "from" argument — the
 * capability the post arrives on is the authority to speak. */
function roomBehavior(conn: Connection) {
  return (verb: string, args: AppValue[]): AppValue => {
    if (verb === SUBSCRIBE) {
      const nick = typeof args[0] === "string" ? args[0] : "anon";
      const inbox = args[1];
      if (!(inbox instanceof Ref)) {
        throw new Error("subscribe needs an inbox capability");
      }
      if (claimedByAnother(conn, nick)) {
        throw new Error(`name "${nick}" is already claimed`);
      }
      if (findByConn(conn)) leave(conn);
      members.push({ nick, inbox, conn });
      broadcast("room", `${nick} joined (${members.length} here)`);
      // The welcome names everyone present: join announcements only reach
      // members already in the room, so this list is how a late joiner learns
      // who arrived before it.
      return `welcome ${nick} — ${members.length} in the room: ${
        members.map((m) => m.nick).join(", ")
      }`;
    }
    if (verb === POST) {
      const member = findByConn(conn);
      if (member === null) {
        throw new Error("post needs a claimed room membership");
      }
      broadcast(member.nick, typeof args[0] === "string" ? args[0] : "");
      return null;
    }
    throw new Error(`room has no method ${verb}`);
  };
}

function transportArg(): "tcp" | "iroh" {
  const flag = Deno.args.find((a) => a.startsWith("--transport="));
  // ROOMS_TRANSPORT is a convenience for manual runs; only read it when env
  // access is granted so the default (TCP) permission set never trips.
  const envAllowed = Deno.permissions.querySync({ name: "env", variable: "ROOMS_TRANSPORT" }).state === "granted";
  const choice = (flag ? flag.slice("--transport=".length) : (envAllowed ? Deno.env.get("ROOMS_TRANSPORT") : undefined)) ?? "tcp";
  if (choice !== "tcp" && choice !== "iroh") {
    console.error(`server.ts: unknown transport "${choice}" (expected tcp or iroh)`);
    Deno.exit(2);
  }
  return choice;
}

// Positional args are the port (TCP only); iroh has no port to pin.
const positional = Deno.args.filter((a) => !a.startsWith("--"));
const transport = transportArg();

// The server iterates accepted `Connection`s the same way on either transport;
// only the bind and the announced address differ.
let server: Server | IrohServer;
let announce: string;
if (transport === "iroh") {
  // The rooms URIs carry direct-addresses, so `.direct` is the explicit posture.
  const iroh = listenIroh(Reachability.Direct);
  server = iroh;
  // iroh has no host:port — announce the dialable ocapn:// URI directly.
  announce = iroh.uri;
} else {
  const tcp = listen("127.0.0.1", Number(positional[0] ?? "0"));
  server = tcp;
  // TCP announces the bare port (a dialer adds 127.0.0.1), unchanged.
  announce = String(tcp.port);
}

// The harness and the web bridge parse this line: a bare port is a TCP locator
// (127.0.0.1:<port>), an ocapn:// URI is an iroh locator.
console.log(`ROOMS-SERVER-LISTENING ${announce}`);

for await (const conn of server) {
  conn.publish(ROOM, roomBehavior(conn)); // fetchable by name
  conn.serve().then(
    () => leave(conn),
    () => leave(conn),
  );
}
